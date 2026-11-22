# Seat harness for Claude Code

**A model that grades its own work stops too early or too late, and you pay for both.**
This harness takes the "am I done?" decision away from the model and gives it to code.

It turns one long Claude Code conversation into four seats with different models, a folder
that holds the plan and the evidence, and a Stop hook that will not let the run end until every
check in `GOAL.md` passes when the hook re-runs it.

```
            you ──/goal──▶ GOAL.md  (outcome + checks as commands)
                              │
                     /run ────┤
                              ▼
 ┌──────────── orchestrator (main session) ─────────────────────────┐
 │  scout (haiku)    reads the repo once → map.md                   │
 │  advisor (opus)   remaining checks → cards → route (code)        │
 │  builder ×3 (sonnet)  one card each, test first                  │
 │  verifier (opus, fresh context)  diff + card + GOAL → receipts   │
 └─────────────────────────────┬────────────────────────────────────┘
                               │ tries to stop
                               ▼
              Stop hook: harness.py gate  (re-runs every check)
            all pass + receipts ─▶ done, report.md with cost by seat
            otherwise ───────────▶ block, name the weakest check, next round
            round ≥ max_rounds ──▶ pause, hand over to you
```

## Four rules, each enforced in code

| Rule | Where it is enforced |
|---|---|
| **Done is an eval, not a feeling.** A goal is a list of commands with expectations. | `lint` refuses a GOAL.md whose checks are not commands; `gate` re-runs them on every stop. |
| **The maker never grades the work.** | Builders cannot write receipts. `receipt` runs the check itself and writes the file only on a pass. The verifier runs in a fresh context and sees the diff, never the build conversation. |
| **Route work to the cheapest seat that can do it.** | Each seat pins a model in `.claude/agents/*.md`. `gate` reads Claude Code's local transcripts and writes cost per seat next to what the same tokens would cost on one model. |
| **Confidence decides when a human steps in, and the confidence gets audited.** | `route` thresholds the advisor's confidence: ≥ 0.80 auto, 0.50–0.80 advisor writes a reason, < 0.50 goes to `questions.md`. `audit` checks calibration: first-try pass rate per confidence bucket. |

Anything that sends, deletes, pays or publishes goes to `approvals/` and waits; the project
settings also ask before Gmail sends, force pushes and `rm -rf`.

## Use it

```bash
/goal export meetings as Markdown with action items    # writes harness/GOAL.md with you
/run                                                   # runs until done or paused
/audit                                                 # weekly: rounds, failures, calibration, cost
```

Or drive the script directly:

```bash
python3 harness/bin/harness.py lint harness/GOAL.md
python3 harness/bin/harness.py start harness/GOAL.md
python3 harness/bin/harness.py checks -v              # run every check now
python3 harness/bin/harness.py status
python3 harness/bin/harness.py cost                   # cost by seat so far
```

## Files

| Path | What it is |
|---|---|
| `HARNESS.md` | The contract every seat follows (imported by the repo's `CLAUDE.md`) |
| `GOAL.template.md` | The shape of a finish line |
| `bin/harness.py` | The whole harness: lint, start, route, receipt, gate, cost, audit. Stdlib only. |
| `prices.json` | Per-model prices used for the cost report. Edit when prices change. |
| `runs/<id>/` | One folder per run: `GOAL.md`, `cards/`, `receipts/`, `approvals/`, `questions.md`, `seats.log`, `log.jsonl`, `report.md` |
| `current` | Symlink to the active run |
| `examples/` | A resume-tailoring GOAL whose checks are scripts, and a feature GOAL for this app |
| `tests/` | `python3 -m unittest discover -s harness/tests` |
| `../.claude/agents/` | The four seats |
| `../.claude/commands/` | `/goal`, `/run`, `/audit` |
| `../.claude/settings.json` | The Stop hook and the ask-first permissions |

## Why these choices

- **A deterministic gate instead of a judge model.** The original pattern this adapts uses a
  small classifier to answer "is it done?" with a probability. Here every check is already a
  command, so the gate can just run it. A probability is only needed where a command can't
  decide — and the right fix for that is usually rewriting the check.
- **Receipts written by the script, not the seat.** A receipt a model types is a claim. A receipt
  the script writes after running the command is evidence, and the gate still re-runs the
  command in case something broke after the receipt.
- **Model per seat by token shape.** Reading is mostly input tokens, so the scout gets the
  cheapest model. Building is mostly output tokens, so the builder gets a mid-priced model.
  Planning and verifying are few tokens but high stakes, so they get the strongest model.
- **Confidence is self-reported, so it is measured.** An LLM's stated confidence is not
  calibrated by default. The audit's bucket table shows whether 0.9 really means 9 in 10 cards
  pass first try; if not, raise the threshold or retrain the advisor's prompt.

## Limits

- Claude Code subagents cannot spawn subagents, so the main session is the orchestrator and
  the advisor plans but does not dispatch.
- Seat boundaries on writes are instructions plus tool lists, not a sandbox; the gate's
  re-run is what makes a wrong write visible.
- Cost comes from local transcripts and list prices; cached-token discounts follow
  `prices.json`, and other runs in the same project during the window are counted too.
