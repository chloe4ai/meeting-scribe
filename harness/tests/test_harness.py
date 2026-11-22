"""End-to-end tests for harness/bin/harness.py and the resume checks.

Run from the repo root:  python3 -m unittest discover -s harness/tests -v
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "harness" / "bin" / "harness.py"
CHECKS = REPO / "harness" / "examples" / "resume-tailor" / "checks"

GOAL = """# GOAL: Make done.txt

## Outcome
A file named done.txt exists in the repo root.

## Checks
- id: C1
  desc: done.txt exists
  cmd: test -f done.txt
  expect: exit 0
- id: C2
  desc: python prints PASS
  cmd: python3 -c "print('PASS')"
  expect: stdout contains PASS

## Stop rules
- max_rounds: {rounds}
"""


class HarnessTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        (self.root / "harness" / "bin").mkdir(parents=True)
        shutil.copy(SCRIPT, self.root / "harness" / "bin" / "harness.py")
        shutil.copy(REPO / "harness" / "prices.json", self.root / "harness" / "prices.json")
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        self.transcripts = self.root / "transcripts"
        self.transcripts.mkdir()
        self.env = {**os.environ, "HARNESS_ROOT": str(self.root),
                    "HARNESS_TRANSCRIPTS_DIR": str(self.transcripts)}
        self.env.pop("CLAUDE_PROJECT_DIR", None)

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def h(self, *args, stdin=""):
        return subprocess.run([sys.executable, str(self.root / "harness" / "bin" / "harness.py"), *args],
                              cwd=self.root, env=self.env, input=stdin, capture_output=True, text=True)

    def write_goal(self, rounds=6, text=None):
        p = self.root / "harness" / "GOAL.md"
        p.write_text(text or GOAL.format(rounds=rounds))
        return str(p)

    def run_json(self):
        return json.loads((self.root / "harness" / "current" / "run.json").read_text())

    def card(self, cid, seat, conf):
        p = self.root / "harness" / "current" / "cards" / f"{cid}-x.md"
        p.write_text(f"---\nid: {cid}\nseat: {seat}\nconfidence: {conf}\nchecks: [C1]\n"
                     f"files: [done.txt]\nstatus: todo\nattempts: 0\n---\nGoal: create done.txt\n")
        return p

    # ------------------------------------------------------------ GOAL parsing

    def test_lint_rejects_goal_without_checks(self):
        g = self.write_goal(text="# GOAL: vague\n\n## Outcome\nMake it good.\n\n## Checks\n")
        r = self.h("lint", g)
        self.assertEqual(r.returncode, 1)
        self.assertIn("no checks", r.stdout)

    def test_lint_rejects_judgment_check(self):
        g = self.write_goal(text="# GOAL: x\n\n## Outcome\ny\n\n## Checks\n- id: C1\n  desc: reads well\n")
        r = self.h("lint", g)
        self.assertEqual(r.returncode, 1)
        self.assertIn("missing cmd", r.stdout)

    def test_start_refuses_unlintable_goal(self):
        g = self.write_goal(text="# GOAL: x\n\n## Checks\n")
        self.assertEqual(self.h("start", g).returncode, 1)
        self.assertFalse((self.root / "harness" / "current").exists())

    # ------------------------------------------------------------ the gate

    def test_gate_is_silent_without_a_run(self):
        r = self.h("gate", stdin="{}")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.strip(), "")

    def test_full_run_blocks_until_receipts_then_finishes(self):
        self.assertEqual(self.h("start", self.write_goal()).returncode, 0)

        # Round 1: C1 failing, no receipts -> the stop is blocked.
        out = json.loads(self.h("gate", stdin="{}").stdout)
        self.assertEqual(out["decision"], "block")
        self.assertIn("Weakest check: C1", out["reason"])
        self.assertEqual(self.run_json()["round"], 1)

        # A failing check cannot get a receipt.
        r = self.h("receipt", "C1")
        self.assertEqual(r.returncode, 1)
        self.assertFalse((self.root / "harness" / "current" / "receipts" / "C1.md").exists())

        # Passing but un-receipted checks still block.
        (self.root / "done.txt").write_text("ok")
        out = json.loads(self.h("gate", stdin="{}").stdout)
        self.assertEqual(out["decision"], "block")
        self.assertIn("no receipt", out["reason"])

        # Verifier issues receipts; the next stop is allowed and the run is done.
        self.assertEqual(self.h("receipt", "C1", "--card", "001").returncode, 0)
        self.assertEqual(self.h("receipt", "C2").returncode, 0)
        receipt = (self.root / "harness" / "current" / "receipts" / "C1.md").read_text()
        self.assertIn("command: `test -f done.txt`", receipt)
        self.assertIn("card: 001", receipt)
        out = json.loads(self.h("gate", stdin="{}").stdout)
        self.assertNotIn("decision", out)
        self.assertIn("done", out["systemMessage"])
        self.assertEqual(self.run_json()["state"], "done")
        self.assertTrue((self.root / "harness" / "current" / "report.md").exists())

        # A finished run no longer holds the stop.
        self.assertEqual(self.h("gate", stdin="{}").stdout.strip(), "")

    def test_gate_re_runs_checks_so_a_stale_receipt_does_not_count(self):
        self.h("start", self.write_goal())
        (self.root / "done.txt").write_text("ok")
        self.h("receipt", "C1")
        self.h("receipt", "C2")
        (self.root / "done.txt").unlink()  # someone broke it after the receipt
        out = json.loads(self.h("gate", stdin="{}").stdout)
        self.assertEqual(out["decision"], "block")
        self.assertIn("C1", out["reason"])

    def test_gate_pauses_at_max_rounds(self):
        self.h("start", self.write_goal(rounds=2))
        self.assertEqual(json.loads(self.h("gate", stdin="{}").stdout)["decision"], "block")
        out = json.loads(self.h("gate", stdin="{}").stdout)
        self.assertIn("paused", out["systemMessage"])
        self.assertEqual(self.run_json()["state"], "paused")
        self.assertEqual(self.h("gate", stdin="{}").stdout.strip(), "")

    def test_pause_lets_the_agent_stop_to_ask_the_human(self):
        self.h("start", self.write_goal())
        self.h("pause", "need the job description")
        self.assertEqual(self.h("gate", stdin="{}").stdout.strip(), "")
        self.h("resume")
        self.assertEqual(json.loads(self.h("gate", stdin="{}").stdout)["decision"], "block")

    def test_start_refuses_to_clobber_an_active_run(self):
        self.h("start", self.write_goal())
        self.assertEqual(self.h("start", self.write_goal()).returncode, 1)
        self.assertEqual(self.h("start", self.write_goal(), "--force").returncode, 0)

    # ------------------------------------------------------------ routing

    def test_route_thresholds(self):
        self.h("start", self.write_goal())
        self.card("001", "builder", 0.9)
        self.card("002", "builder", 0.6)
        self.card("003", "scout", 0.3)
        self.assertEqual(self.h("route", "001").returncode, 0)
        r2 = self.h("route", "002")
        self.assertEqual(r2.returncode, 3)
        self.assertIn("ADVISOR DECIDES", r2.stdout)
        r3 = self.h("route", "003")
        self.assertEqual(r3.returncode, 3)
        q = (self.root / "harness" / "current" / "questions.md").read_text()
        self.assertIn("card 003", q)
        # advisor must write a reason before a low-confidence card can proceed
        self.assertEqual(self.h("card", "002", "--status", "todo").returncode, 2)
        p = next((self.root / "harness" / "current" / "cards").glob("002-*.md"))
        p.write_text(p.read_text().replace("status:", "route_reason: builder, scope is one file\nstatus:", 1))
        self.assertEqual(self.h("card", "002", "--status", "todo").returncode, 0)
        log = (self.root / "harness" / "current" / "seats.log").read_text()
        self.assertEqual(len(log.strip().splitlines()), 3)

    def test_route_rejects_unknown_seat(self):
        self.h("start", self.write_goal())
        self.card("001", "manager", 0.95)
        self.assertEqual(self.h("route", "001").returncode, 2)

    def test_first_try_is_recorded_for_calibration(self):
        self.h("start", self.write_goal())
        self.card("001", "builder", 0.9)
        self.card("002", "builder", 0.9)
        self.h("card", "001", "--status", "passed")
        self.h("card", "002", "--status", "failed", "--note", "test red")
        self.h("card", "002", "--status", "passed")
        cards = self.root / "harness" / "current" / "cards"
        self.assertIn("first_try: yes", next(cards.glob("001-*")).read_text())
        c2 = next(cards.glob("002-*")).read_text()
        self.assertIn("first_try: no", c2)
        self.assertIn("test red", c2)
        audit = self.h("audit").stdout
        self.assertIn("| 0.9-1.0 | 2 | 50% |", audit)

    # ------------------------------------------------------------ cost

    def test_cost_by_seat_from_transcripts(self):
        self.h("start", self.write_goal())
        t = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        main = {"type": "assistant", "timestamp": t, "requestId": "r1",
                "message": {"id": "m1", "model": "claude-opus-5-5",
                            "usage": {"input_tokens": 1_000_000, "output_tokens": 100_000,
                                      "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}}}
        sess = self.transcripts / "s1"
        (sess / "subagents").mkdir(parents=True)
        (self.transcripts / "s1.jsonl").write_text(json.dumps(main) + "\n" + json.dumps(main) + "\n")
        sub = dict(main, requestId="r2", message=dict(main["message"], id="m2", model="claude-haiku-5-5"))
        (sess / "subagents" / "agent-a.jsonl").write_text(json.dumps(sub) + "\n")
        (sess / "subagents" / "agent-a.meta.json").write_text(json.dumps({"agentType": "scout"}))
        (self.root / "done.txt").write_text("ok")
        self.h("receipt", "C1")
        self.h("receipt", "C2")
        self.h("gate", stdin="{}")
        cost = self.run_json()["cost"]
        # orchestrator: 1M in * $4 + 0.1M out * $20 = $6.00 (duplicate line counted once)
        self.assertAlmostEqual(cost["seats"]["orchestrator"]["cost"], 6.0, places=4)
        # scout on haiku: 1M * $0.10 + 0.1M * $0.50 = $0.15; at opus prices it would be $6.00
        self.assertAlmostEqual(cost["seats"]["scout"]["cost"], 0.15, places=4)
        self.assertAlmostEqual(cost["all_baseline"], 12.0, places=4)
        self.assertIn("| scout |", (self.root / "harness" / "current" / "report.md").read_text())


class ResumeCheckTest(unittest.TestCase):
    def setUp(self):
        try:
            import docx  # noqa: F401
        except ImportError:
            self.skipTest("python-docx not installed")
        self.dir = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def make_docx(self, bullets, table=False):
        import docx
        d = docx.Document()
        d.add_paragraph("PROFESSIONAL EXPERIENCE")
        for b in bullets:
            d.add_paragraph(b, style="List Bullet")
        if table:
            d.add_table(rows=1, cols=2)
        p = self.dir / "r.docx"
        d.save(p)
        return p

    def check(self, name, *args):
        return subprocess.run([sys.executable, str(CHECKS / name), *args],
                              capture_output=True, text=True)

    def test_keywords_with_alternates(self):
        doc = self.make_docx(["Led the Applicant Tracking System rollout with SQL and A/B tests."])
        kw = self.dir / "kw.txt"
        kw.write_text("SQL\nApplicant Tracking System | ATS\nA/B tests\n# comment\n")
        r = self.check("check_keywords.py", "--keywords", str(kw), "--doc", str(doc))
        self.assertEqual(r.returncode, 0, r.stdout)
        kw.write_text("SQL\nKubernetes\n")
        r = self.check("check_keywords.py", "--keywords", str(kw), "--doc", str(doc))
        self.assertEqual(r.returncode, 1)
        self.assertIn("missing: Kubernetes", r.stdout)

    def test_keyword_match_is_whole_word(self):
        doc = self.make_docx(["Managed ads and campaigns."])
        kw = self.dir / "kw.txt"
        kw.write_text("ad\n")
        self.assertEqual(self.check("check_keywords.py", "--keywords", str(kw), "--doc", str(doc)).returncode, 1)

    def test_bullet_band(self):
        good = "x" * 200
        doc = self.make_docx([good, good])
        self.assertEqual(self.check("check_bullets.py", "--doc", str(doc)).returncode, 0)
        doc = self.make_docx([good, "too short"])
        r = self.check("check_bullets.py", "--doc", str(doc))
        self.assertEqual(r.returncode, 1)
        self.assertIn("bullet 2: 9 chars", r.stdout)

    def test_layout_flags_catch_tables(self):
        sys.path.insert(0, str(CHECKS))
        from textio import docx_layout_flags
        self.assertEqual(docx_layout_flags(self.make_docx(["a"], table=True))["tables"], 1)
        self.assertEqual(docx_layout_flags(self.make_docx(["a"]))["tables"], 0)


if __name__ == "__main__":
    unittest.main()
