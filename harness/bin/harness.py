#!/usr/bin/env python3
"""Seat harness for Claude Code: a folder acts as the manager.

One file of plain Python (stdlib only) that the seats and the Stop hook call.
Truth lives in code, not in chat:

  - GOAL.md lists checks: a command plus an expectation. "Done" means every
    check passes when this script re-runs it AND has a receipt.
  - Receipts are written by `receipt`, which runs the check itself. A seat
    cannot type one into existence.
  - Routing confidence is thresholded in code: >= 0.80 goes to the seat,
    0.50-0.80 goes to the advisor with a written reason, < 0.50 goes to you.
  - The Stop hook (`gate`) refuses to let a run end until it is done, pauses
    after max_rounds, and records cost per seat from the local transcripts.

Commands: lint, start, status, checks, gate, route, card, receipt, pause,
resume, cost, audit. Run with -h for details.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

AUTO_ROUTE = 0.80        # confidence at or above: card goes straight to its seat
ADVISOR_ROUTE = 0.50     # between this and AUTO_ROUTE: advisor decides, writes why
DEFAULT_MAX_ROUNDS = 6
CHECK_TIMEOUT = 900      # seconds per check command
SEATS = ("advisor", "scout", "builder", "verifier")
CARD_STATES = ("todo", "in_progress", "built", "passed", "failed",
               "needs_advisor", "needs_human", "dropped")


# ---------------------------------------------------------------- paths

def project_root() -> Path:
    env = os.environ.get("HARNESS_ROOT") or os.environ.get("CLAUDE_PROJECT_DIR")
    if env:
        return Path(env).resolve()
    here = Path(__file__).resolve()
    return here.parent.parent.parent  # harness/bin/harness.py -> repo root


def harness_dir() -> Path:
    return project_root() / "harness"


def current_dir() -> Path:
    return harness_dir() / "current"


def now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def iso(t: dt.datetime | None = None) -> str:
    return (t or now()).isoformat(timespec="seconds")


# ---------------------------------------------------------------- GOAL.md

CHECK_KEYS = ("id", "desc", "cmd", "expect", "timeout")


def parse_goal(text: str) -> dict:
    """Parse GOAL.md. Checks live under '## Checks' as YAML-ish list items:

        - id: C1
          desc: Unit tests pass
          cmd: swift test
          expect: exit 0
    """
    goal = {"title": "", "outcome": "", "checks": [], "max_rounds": DEFAULT_MAX_ROUNDS}
    m = re.search(r"^#\s+(?:GOAL:\s*)?(.+)$", text, re.M)
    if m:
        goal["title"] = m.group(1).strip()
    sections = _sections(text)
    goal["outcome"] = sections.get("outcome", "").strip()
    current = None
    for raw in sections.get("checks", "").splitlines():
        line = raw.rstrip()
        if not line.strip() or line.strip().startswith("<!--"):
            continue
        item = re.match(r"^\s*-\s+(\w+):\s*(.*)$", line)
        cont = re.match(r"^\s+(\w+):\s*(.*)$", line)
        if item and item.group(1) == "id":
            current = {"id": item.group(2).strip()}
            goal["checks"].append(current)
        elif cont and current is not None and cont.group(1) in CHECK_KEYS:
            current[cont.group(1)] = cont.group(2).strip()
    m = re.search(r"max_rounds:\s*(\d+)", text)
    if m:
        goal["max_rounds"] = int(m.group(1))
    return goal


def _sections(text: str) -> dict:
    out, name, buf = {}, None, []
    for line in text.splitlines():
        h = re.match(r"^##\s+(.+?)\s*$", line)
        if h:
            if name:
                out[name] = "\n".join(buf)
            name, buf = h.group(1).strip().lower(), []
        elif name:
            buf.append(line)
    if name:
        out[name] = "\n".join(buf)
    return out


def lint_goal(goal: dict) -> list[str]:
    problems = []
    if not goal["outcome"]:
        problems.append("missing '## Outcome' (one sentence a stranger can verify)")
    if not goal["checks"]:
        problems.append("no checks under '## Checks' -- no checks, no finish line")
    seen = set()
    for c in goal["checks"]:
        cid = c.get("id", "?")
        if cid in seen:
            problems.append(f"{cid}: duplicate id")
        seen.add(cid)
        if not re.fullmatch(r"[A-Za-z0-9_-]+", cid):
            problems.append(f"{cid}: id must be letters, digits, - or _")
        if not c.get("cmd"):
            problems.append(f"{cid}: missing cmd (a check is a command, not a judgment)")
        if not c.get("expect"):
            problems.append(f"{cid}: missing expect (e.g. 'exit 0' or 'stdout contains PASS')")
        elif not _parse_expect(c["expect"]):
            problems.append(f"{cid}: expect must be 'exit N', 'stdout contains TEXT' or 'stdout matches REGEX'")
    return problems


def _parse_expect(expect: str):
    m = re.fullmatch(r"exit\s+(\d+)", expect.strip())
    if m:
        return ("exit", int(m.group(1)))
    m = re.fullmatch(r"stdout\s+contains\s+(.+)", expect.strip())
    if m:
        return ("contains", m.group(1).strip().strip('"'))
    m = re.fullmatch(r"stdout\s+matches\s+(.+)", expect.strip())
    if m:
        return ("matches", m.group(1).strip().strip('"'))
    return None


# ---------------------------------------------------------------- checks

def run_check(check: dict) -> dict:
    timeout = int(check.get("timeout") or CHECK_TIMEOUT)
    started = now()
    try:
        p = subprocess.run(check["cmd"], shell=True, cwd=project_root(),
                           capture_output=True, text=True, timeout=timeout)
        code, out = p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired as e:
        code, out = 124, f"TIMEOUT after {timeout}s\n{e.stdout or ''}"
    kind, want = _parse_expect(check.get("expect", "exit 0")) or ("exit", 0)
    if kind == "exit":
        ok = code == want
    elif kind == "contains":
        ok = code == 0 and want in out
    else:
        ok = code == 0 and re.search(want, out, re.M) is not None
    return {"id": check["id"], "passed": ok, "exit": code, "output": out,
            "seconds": round((now() - started).total_seconds(), 1)}


def tail(text: str, lines: int = 15) -> str:
    return "\n".join(text.rstrip().splitlines()[-lines:])


# ---------------------------------------------------------------- run state

def load_run() -> dict | None:
    f = current_dir() / "run.json"
    if not f.exists():
        return None
    return json.loads(f.read_text())


def save_run(run: dict) -> None:
    (current_dir() / "run.json").write_text(json.dumps(run, indent=2) + "\n")


def load_goal_for_run() -> dict:
    return parse_goal((current_dir() / "GOAL.md").read_text())


def append_log(event: dict) -> None:
    with (current_dir() / "log.jsonl").open("a") as f:
        f.write(json.dumps({"time": iso(), **event}) + "\n")


def git_head() -> str:
    try:
        sha = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=project_root(),
                             capture_output=True, text=True).stdout.strip()
        dirty = subprocess.run(["git", "status", "--porcelain"], cwd=project_root(),
                               capture_output=True, text=True).stdout.strip()
        return (sha or "no-git") + ("+dirty" if dirty else "")
    except OSError:
        return "no-git"


# ---------------------------------------------------------------- cards

def parse_card(path: Path) -> dict:
    text = path.read_text()
    meta, body = {}, text
    m = re.match(r"^---\n(.*?)\n---\n?(.*)$", text, re.S)
    if m:
        body = m.group(2)
        for line in m.group(1).splitlines():
            kv = re.match(r"^(\w+):\s*(.*)$", line)
            if kv:
                k, v = kv.group(1), kv.group(2).strip()
                if v.startswith("[") and v.endswith("]"):
                    v = [x.strip().strip("'\"") for x in v[1:-1].split(",") if x.strip()]
                meta[k] = v
    meta["_path"], meta["_body"] = path, body
    return meta


def write_card(card: dict) -> None:
    keys = [k for k in card if not k.startswith("_")]
    lines = ["---"]
    for k in keys:
        v = card[k]
        if isinstance(v, list):
            v = "[" + ", ".join(v) + "]"
        lines.append(f"{k}: {v}")
    lines.append("---")
    card["_path"].write_text("\n".join(lines) + "\n" + card["_body"].lstrip("\n"))


def find_card(card_id: str) -> Path:
    cards = current_dir() / "cards"
    for p in sorted(cards.glob("*.md")):
        c = parse_card(p)
        if str(c.get("id")) == card_id or p.stem == card_id or p.stem.startswith(card_id + "-"):
            return p
    sys.exit(f"card {card_id} not found in {cards}")


def all_cards(run_dir: Path) -> list[dict]:
    return [parse_card(p) for p in sorted((run_dir / "cards").glob("*.md"))]


# ---------------------------------------------------------------- commands

def cmd_lint(args) -> int:
    goal = parse_goal(Path(args.goal).read_text())
    problems = lint_goal(goal)
    if problems:
        print("GOAL.md is not runnable yet:")
        for p in problems:
            print(f"  - {p}")
        return 1
    print(f"OK: '{goal['title']}' -- {len(goal['checks'])} checks, max_rounds {goal['max_rounds']}")
    return 0


def cmd_start(args) -> int:
    src = Path(args.goal)
    goal = parse_goal(src.read_text())
    problems = lint_goal(goal)
    if problems:
        print("Refusing to start; fix GOAL.md first:")
        for p in problems:
            print(f"  - {p}")
        return 1
    run = load_run()
    if run and run.get("state") in ("running", "paused") and not args.force:
        print(f"Run {run['id']} is still {run['state']}. Finish it, or pass --force to replace it.")
        return 1
    slug = re.sub(r"[^a-z0-9]+", "-", goal["title"].lower()).strip("-")[:40] or "run"
    run_id = now().strftime("%Y%m%d-%H%M%S") + "-" + slug
    run_dir = harness_dir() / "runs" / run_id
    for sub in ("cards", "receipts", "approvals"):
        (run_dir / sub).mkdir(parents=True, exist_ok=True)
    shutil.copy(src, run_dir / "GOAL.md")
    (run_dir / "questions.md").write_text("# Questions for the human\n\n")
    link = current_dir()
    if link.is_symlink() or link.exists():
        link.unlink()
    link.symlink_to(Path("runs") / run_id)
    save_run({"id": run_id, "title": goal["title"], "state": "running", "round": 0,
              "max_rounds": goal["max_rounds"], "started": iso(), "goal_source": str(src)})
    append_log({"event": "start"})
    print(f"Started run {run_id}")
    print(f"  folder: harness/current -> harness/runs/{run_id}")
    print(f"  checks: {', '.join(c['id'] for c in goal['checks'])}")
    return 0


def evaluate(write_log: bool = True) -> list[dict]:
    goal = load_goal_for_run()
    receipts = current_dir() / "receipts"
    results = []
    for c in goal["checks"]:
        r = run_check(c)
        r["desc"] = c.get("desc", "")
        r["receipt"] = (receipts / f"{c['id']}.md").exists()
        results.append(r)
    if write_log:
        append_log({"event": "evaluate",
                    "checks": {r["id"]: {"passed": r["passed"], "receipt": r["receipt"]} for r in results}})
    return results


def cmd_checks(args) -> int:
    if not load_run():
        print("No active run. Start one with: harness.py start harness/GOAL.md")
        return 1
    results = evaluate(write_log=False)
    for r in results:
        mark = "PASS" if r["passed"] else "FAIL"
        rec = "receipt" if r["receipt"] else "no receipt"
        print(f"{mark}  {r['id']:<6} {rec:<10} {r['desc']}")
        if not r["passed"] and args.verbose:
            print("      " + tail(r["output"]).replace("\n", "\n      "))
    done = all(r["passed"] and r["receipt"] for r in results)
    print(f"\n{sum(r['passed'] and r['receipt'] for r in results)}/{len(results)} checks done")
    return 0 if done else 1


def cmd_status(args) -> int:
    run = load_run()
    if not run:
        print("No active run.")
        return 0
    print(f"Run {run['id']}  [{run['state']}]  round {run['round']}/{run['max_rounds']}")
    print(f"Goal: {run['title']}")
    cards = all_cards(current_dir())
    if cards:
        by = {}
        for c in cards:
            by.setdefault(c.get("status", "todo"), []).append(str(c.get("id")))
        print("Cards: " + "; ".join(f"{k}: {', '.join(v)}" for k, v in sorted(by.items())))
    receipts = sorted(p.stem for p in (current_dir() / "receipts").glob("*.md"))
    print(f"Receipts: {', '.join(receipts) or 'none'}")
    if run.get("pause_reason"):
        print(f"Paused because: {run['pause_reason']}")
    return 0


def cmd_receipt(args) -> int:
    """Verifier calls this. The script runs the check; only a pass writes a receipt."""
    goal = load_goal_for_run()
    check = next((c for c in goal["checks"] if c["id"] == args.check), None)
    if not check:
        print(f"No check {args.check} in GOAL.md")
        return 2
    r = run_check(check)
    if not r["passed"]:
        print(f"FAIL {check['id']} -- no receipt written.\n{tail(r['output'], 25)}")
        append_log({"event": "receipt_refused", "check": check["id"], "card": args.card})
        return 1
    receipt = current_dir() / "receipts" / f"{check['id']}.md"
    receipt.write_text(
        f"# Receipt {check['id']}: {check.get('desc', '')}\n\n"
        f"- command: `{check['cmd']}`\n- expect: {check['expect']}\n- exit: {r['exit']}\n"
        f"- commit: {git_head()}\n- time: {iso()}\n- card: {args.card or '-'}\n"
        f"- seconds: {r['seconds']}\n\n## Output (last 40 lines)\n\n```\n{tail(r['output'], 40)}\n```\n")
    append_log({"event": "receipt", "check": check["id"], "card": args.card})
    print(f"PASS {check['id']} -- receipt written: harness/current/receipts/{check['id']}.md")
    return 0


def cmd_route(args) -> int:
    """Threshold routing in code. The advisor supplies seat + confidence on the card."""
    path = find_card(args.card)
    card = parse_card(path)
    seat = card.get("seat", "")
    try:
        conf = float(card.get("confidence", "0"))
    except ValueError:
        conf = 0.0
    if seat not in SEATS:
        print(f"card {card.get('id')}: seat must be one of {', '.join(SEATS)}")
        return 2
    if conf >= AUTO_ROUTE:
        card["status"] = "todo"
        decision = f"ROUTE -> {seat} (confidence {conf:.2f} >= {AUTO_ROUTE})"
    elif conf >= ADVISOR_ROUTE:
        card["status"] = "needs_advisor"
        decision = (f"ADVISOR DECIDES (confidence {conf:.2f} < {AUTO_ROUTE}): add "
                    f"'route_reason:' to the card, then run: harness.py card {card.get('id')} --status todo")
    else:
        card["status"] = "needs_human"
        decision = f"HUMAN (confidence {conf:.2f} < {ADVISOR_ROUTE}): question added to questions.md"
        with (current_dir() / "questions.md").open("a") as f:
            f.write(f"- [ ] card {card.get('id')} ({seat}, confidence {conf:.2f}): "
                    f"{card['_body'].strip().splitlines()[0] if card['_body'].strip() else 'see card'}\n")
    card["routed"] = iso()
    write_card(card)
    append_log({"event": "route", "card": str(card.get("id")), "seat": seat,
                "confidence": conf, "status": card["status"]})
    with (current_dir() / "seats.log").open("a") as f:
        f.write(f"{iso()}\tcard {card.get('id')}\t{seat}\t{conf:.2f}\t{card['status']}\n")
    print(decision)
    return 0 if card["status"] == "todo" else 3


def cmd_card(args) -> int:
    path = find_card(args.card)
    card = parse_card(path)
    if args.status:
        if args.status not in CARD_STATES:
            print(f"status must be one of {', '.join(CARD_STATES)}")
            return 2
        if args.status == "todo" and card.get("status") == "needs_advisor" and not card.get("route_reason"):
            print("Card was below the auto-route threshold: add 'route_reason:' to it first.")
            return 2
        if args.status == "failed":
            card["attempts"] = str(int(card.get("attempts", "0") or 0) + 1)
        if args.status == "passed" and "first_try" not in card:
            card["first_try"] = "yes" if int(card.get("attempts", "0") or 0) == 0 else "no"
        card["status"] = args.status
    if args.note:
        card["_body"] = card["_body"].rstrip() + f"\n\n- {iso()} {args.note}\n"
    write_card(card)
    append_log({"event": "card", "card": str(card.get("id")), "status": card.get("status"), "note": args.note})
    print(f"card {card.get('id')}: {card.get('status')}")
    return 0


def cmd_pause(args) -> int:
    run = load_run()
    if not run:
        print("No active run.")
        return 1
    run["state"], run["pause_reason"] = "paused", args.reason
    save_run(run)
    append_log({"event": "pause", "reason": args.reason})
    print(f"Paused: {args.reason}")
    return 0


def cmd_resume(args) -> int:
    run = load_run()
    if not run:
        print("No active run.")
        return 1
    run["state"] = "running"
    run.pop("pause_reason", None)
    if args.reset_rounds:
        run["round"] = 0
    save_run(run)
    append_log({"event": "resume"})
    print(f"Resumed run {run['id']} at round {run['round']}/{run['max_rounds']}")
    return 0


def cmd_gate(args) -> int:
    """Stop hook. Exit 0 with no output lets Claude stop; a 'block' decision keeps it working."""
    try:
        sys.stdin.read()
    except Exception:
        pass
    run = load_run()
    if not run or run.get("state") != "running":
        return 0
    results = evaluate()
    run["round"] += 1  # every gate evaluation closes a round
    done = [r for r in results if r["passed"] and r["receipt"]]
    if len(done) == len(results):
        run["state"], run["finished"] = "done", iso()
        run["cost"] = cost_report(run)
        save_run(run)
        append_log({"event": "done", "round": run["round"]})
        write_report(run, results)
        print(json.dumps({"systemMessage": f"Harness: all {len(results)} checks pass with receipts. "
                                           f"Run {run['id']} done in {run['round']} rounds. "
                                           f"Report: harness/current/report.md"}))
        return 0
    if run["round"] >= run["max_rounds"]:
        run["state"] = "paused"
        run["pause_reason"] = f"hit max_rounds ({run['max_rounds']}) with {len(done)}/{len(results)} checks done"
        save_run(run)
        append_log({"event": "pause", "reason": run["pause_reason"]})
        write_report(run, results)
        print(json.dumps({"systemMessage": f"Harness paused: {run['pause_reason']}. Over to you."}))
        return 0
    save_run(run)
    weakest = _weakest(results)
    lines = [f"Harness round {run['round']}/{run['max_rounds']}: {len(done)}/{len(results)} checks done. Not finished."]
    for r in results:
        if not (r["passed"] and r["receipt"]):
            why = "failing" if not r["passed"] else "passes but has no receipt (verifier must run `harness.py receipt`)"
            lines.append(f"- {r['id']} ({r['desc']}): {why}")
    lines.append(f"Weakest check: {weakest['id']}. Last output:\n{tail(weakest['output'], 8)}")
    lines.append("Next: advisor re-plans for the weakest check -> route cards -> builder -> verifier. "
                 "If you are blocked on the human, run `python3 harness/bin/harness.py pause \"<why>\"` and stop.")
    print(json.dumps({"decision": "block", "reason": "\n".join(lines)}))
    return 0


def _weakest(results: list[dict]) -> dict:
    fails = {}
    log = current_dir() / "log.jsonl"
    if log.exists():
        for line in log.read_text().splitlines():
            ev = json.loads(line)
            for cid, st in ev.get("checks", {}).items():
                if not st["passed"]:
                    fails[cid] = fails.get(cid, 0) + 1
    pending = [r for r in results if not (r["passed"] and r["receipt"])]
    return sorted(pending, key=lambda r: (r["passed"], -fails.get(r["id"], 0)))[0]


def write_report(run: dict, results: list[dict]) -> None:
    cost = run.get("cost") or cost_report(run)
    lines = [f"# Run report: {run['title']}", "",
             f"- run: {run['id']}", f"- state: {run['state']}", f"- rounds: {run['round']}/{run['max_rounds']}",
             f"- started: {run['started']}", f"- finished: {run.get('finished', '-')}", "", "## Checks", ""]
    for r in results:
        lines.append(f"- {'PASS' if r['passed'] else 'FAIL'} {r['id']} "
                     f"{'(receipt)' if r['receipt'] else '(no receipt)'} -- {r['desc']}")
    lines += ["", "## Cost by seat", "", _cost_table(cost)]
    (current_dir() / "report.md").write_text("\n".join(lines) + "\n")


# ---------------------------------------------------------------- cost

def load_prices() -> dict:
    return json.loads((harness_dir() / "prices.json").read_text())


def _price_for(model: str, prices: dict) -> dict | None:
    table = prices["models"]
    if model in table:
        return table[model]
    for fam in ("opus", "sonnet", "haiku", "fable"):
        if fam in (model or ""):
            key = prices.get("family_fallback", {}).get(fam)
            if key and key in table:
                return table[key]
    return None


def _usage_cost(u: dict, p: dict, prices: dict) -> float:
    mult = prices.get("cache_write_multiplier", {"5m": 1.25, "1h": 2.0})
    cc = u.get("cache_creation") or {}
    w5 = cc.get("ephemeral_5m_input_tokens", 0)
    w1h = cc.get("ephemeral_1h_input_tokens", 0)
    if not cc:
        w5 = u.get("cache_creation_input_tokens", 0)
    return (u.get("input_tokens", 0) * p["input"]
            + u.get("output_tokens", 0) * p["output"]
            + u.get("cache_read_input_tokens", 0) * p["cache_read"]
            + w5 * p["input"] * mult["5m"] + w1h * p["input"] * mult["1h"]) / 1_000_000


def transcripts_dir() -> Path:
    env = os.environ.get("HARNESS_TRANSCRIPTS_DIR")
    if env:
        return Path(env)
    munged = re.sub(r"[^A-Za-z0-9]", "-", str(project_root()))
    return Path.home() / ".claude" / "projects" / munged


def cost_report(run: dict) -> dict:
    """Sum token usage since the run started, per seat, from Claude Code's local transcripts.

    Main-session usage is the 'orchestrator'. Subagent files carry their agent type in
    <agent>.meta.json. 'all_baseline' prices every token at the baseline model to show
    what one-model-for-everything would have cost.
    """
    prices = load_prices()
    base = prices["models"][prices["baseline_model"]]
    since = dt.datetime.fromisoformat(run["started"])
    # run.json times are truncated to the second; pad the end so the final second counts
    until = (dt.datetime.fromisoformat(run["finished"]) + dt.timedelta(seconds=1)
             if run.get("finished") else None)
    seats, seen, unpriced = {}, set(), 0
    root = transcripts_dir()
    if not root.exists():
        return {"seats": {}, "total": 0.0, "all_baseline": 0.0, "note": f"no transcripts at {root}"}
    for f in root.rglob("*.jsonl"):
        seat = "orchestrator"
        meta = f.with_suffix(".meta.json")
        if meta.exists():
            try:
                seat = json.loads(meta.read_text()).get("agentType", "subagent")
            except json.JSONDecodeError:
                seat = "subagent"
        for line in f.open(errors="ignore"):
            try:
                o = json.loads(line)
            except json.JSONDecodeError:
                continue
            msg = o.get("message")
            if not isinstance(msg, dict) or not msg.get("usage"):
                continue
            ts = o.get("timestamp")
            if ts:
                t = dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))
                if t < since or (until and t > until):
                    continue
            key = msg.get("id") or o.get("requestId") or o.get("uuid")
            if key in seen:
                continue
            seen.add(key)
            u, model = msg["usage"], msg.get("model", "")
            p = _price_for(model, prices)
            s = seats.setdefault(seat, {"models": set(), "input": 0, "output": 0, "cache_read": 0,
                                        "cache_write": 0, "cost": 0.0, "baseline": 0.0})
            s["models"].add(model)
            s["input"] += u.get("input_tokens", 0)
            s["output"] += u.get("output_tokens", 0)
            s["cache_read"] += u.get("cache_read_input_tokens", 0)
            s["cache_write"] += u.get("cache_creation_input_tokens", 0)
            if p is None:
                unpriced += 1
                continue
            s["cost"] += _usage_cost(u, p, prices)
            s["baseline"] += _usage_cost(u, base, prices)
    for s in seats.values():
        s["models"] = sorted(s["models"])
        s["cost"], s["baseline"] = round(s["cost"], 4), round(s["baseline"], 4)
    total = round(sum(s["cost"] for s in seats.values()), 4)
    baseline = round(sum(s["baseline"] for s in seats.values()), 4)
    return {"seats": seats, "total": total, "all_baseline": baseline,
            "baseline_model": prices["baseline_model"], "unpriced_messages": unpriced}


def _cost_table(cost: dict) -> str:
    if not cost.get("seats"):
        return cost.get("note", "no usage found")
    rows = ["| seat | model | input | output | cache read | cache write | cost | if all baseline |",
            "|---|---|---:|---:|---:|---:|---:|---:|"]
    for seat, s in sorted(cost["seats"].items()):
        rows.append(f"| {seat} | {', '.join(s['models'])} | {s['input']:,} | {s['output']:,} | "
                    f"{s['cache_read']:,} | {s['cache_write']:,} | ${s['cost']:.4f} | ${s['baseline']:.4f} |")
    rows.append(f"| **total** | | | | | | **${cost['total']:.4f}** | **${cost['all_baseline']:.4f}** |")
    return "\n".join(rows) + f"\n\nBaseline = every token priced at {cost.get('baseline_model')}."


def cmd_cost(args) -> int:
    run = load_run()
    if not run:
        print("No active run.")
        return 1
    print(_cost_table(cost_report(run)))
    return 0


# ---------------------------------------------------------------- audit

def cmd_audit(args) -> int:
    runs_dir = harness_dir() / "runs"
    cutoff = now() - dt.timedelta(days=args.days)
    runs = []
    for d in sorted(runs_dir.glob("*/")):
        f = d / "run.json"
        if f.exists():
            r = json.loads(f.read_text())
            if dt.datetime.fromisoformat(r["started"]) >= cutoff:
                runs.append((d, r))
    if not runs:
        print(f"No runs in the last {args.days} days.")
        return 0
    print(f"# Harness audit -- last {args.days} days\n")
    states = {}
    for _, r in runs:
        states[r["state"]] = states.get(r["state"], 0) + 1
    done = [r for _, r in runs if r["state"] == "done"]
    print(f"- runs started: {len(runs)}  ({', '.join(f'{k} {v}' for k, v in sorted(states.items()))})")
    if done:
        print(f"- rounds to done (avg): {sum(r['round'] for r in done) / len(done):.1f}")
        spent = sum((r.get("cost") or {}).get("total", 0) for r in done)
        base = sum((r.get("cost") or {}).get("all_baseline", 0) for r in done)
        if base:
            print(f"- cost of done runs: ${spent:.2f} vs ${base:.2f} if every seat ran the baseline model "
                  f"({100 * (1 - spent / base):.0f}% saved)")
    fails, low_conf, cards = {}, [], []
    for d, r in runs:
        log = d / "log.jsonl"
        if log.exists():
            for line in log.read_text().splitlines():
                ev = json.loads(line)
                for cid, st in ev.get("checks", {}).items():
                    if not st["passed"]:
                        fails[(r["id"], cid)] = fails.get((r["id"], cid), 0) + 1
                if ev.get("event") == "route" and ev.get("confidence", 1) < AUTO_ROUTE:
                    low_conf.append((r["id"], ev["card"], ev["confidence"], ev["status"]))
        cards += all_cards(d)
    twice = [(rid, cid, n) for (rid, cid), n in fails.items() if n >= 2]
    print(f"- checks that failed 2+ rounds: {len(twice)}")
    for rid, cid, n in sorted(twice, key=lambda x: -x[2])[:10]:
        print(f"    {cid} in {rid}: {n} rounds")
    print(f"- cards routed below {AUTO_ROUTE}: {len(low_conf)}")
    print("\n## Is routing confidence calibrated?\n")
    print("First-try pass rate by the advisor's confidence. Calibrated means the rate tracks the bucket.\n")
    print("| confidence | cards | passed first try |\n|---|---:|---:|")
    buckets = [(0.0, 0.5), (0.5, 0.8), (0.8, 0.9), (0.9, 1.01)]
    for lo, hi in buckets:
        b = [c for c in cards if c.get("first_try") and lo <= float(c.get("confidence", 0) or 0) < hi]
        if b:
            rate = sum(c["first_try"] == "yes" for c in b) / len(b)
            print(f"| {lo:.1f}-{min(hi, 1.0):.1f} | {len(b)} | {100 * rate:.0f}% |")
        else:
            print(f"| {lo:.1f}-{min(hi, 1.0):.1f} | 0 | - |")
    return 0


# ---------------------------------------------------------------- main

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("lint", help="check that a GOAL.md is runnable")
    p.add_argument("goal")
    p.set_defaults(fn=cmd_lint)
    p = sub.add_parser("start", help="start a run from a GOAL.md")
    p.add_argument("goal")
    p.add_argument("--force", action="store_true")
    p.set_defaults(fn=cmd_start)
    p = sub.add_parser("status", help="show the active run")
    p.set_defaults(fn=cmd_status)
    p = sub.add_parser("checks", help="run every check now (no receipts written)")
    p.add_argument("-v", "--verbose", action="store_true")
    p.set_defaults(fn=cmd_checks)
    p = sub.add_parser("gate", help="Stop hook entry point")
    p.set_defaults(fn=cmd_gate)
    p = sub.add_parser("route", help="threshold-route a card by its confidence")
    p.add_argument("card")
    p.set_defaults(fn=cmd_route)
    p = sub.add_parser("card", help="update a card's status")
    p.add_argument("card")
    p.add_argument("--status")
    p.add_argument("--note")
    p.set_defaults(fn=cmd_card)
    p = sub.add_parser("receipt", help="verifier: run a check and write its receipt if it passes")
    p.add_argument("check")
    p.add_argument("--card")
    p.set_defaults(fn=cmd_receipt)
    p = sub.add_parser("pause", help="pause the run and hand over to the human")
    p.add_argument("reason")
    p.set_defaults(fn=cmd_pause)
    p = sub.add_parser("resume", help="resume a paused run")
    p.add_argument("--reset-rounds", action="store_true")
    p.set_defaults(fn=cmd_resume)
    p = sub.add_parser("cost", help="cost by seat for the active run so far")
    p.set_defaults(fn=cmd_cost)
    p = sub.add_parser("audit", help="weekly audit across runs")
    p.add_argument("--days", type=int, default=7)
    p.set_defaults(fn=cmd_audit)
    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
