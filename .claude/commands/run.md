---
description: Start a harness run — advisor, scout, builders, verifier — until every GOAL check has a receipt
argument-hint: [path to GOAL.md, default harness/GOAL.md]
---

Run the harness on the GOAL file given here: `$ARGUMENTS` (use `harness/GOAL.md` if that is empty). You are the orchestrator: you dispatch seats,
you do not do their work yourself. Read `harness/HARNESS.md` first.

1. `python3 harness/bin/harness.py start <that GOAL file>`. If it refuses, show me why and stop.
2. Spawn the **scout** subagent: "Map the repo for harness/current/GOAL.md."
3. Each round:
   a. Spawn the **advisor**: "Plan round N. Weakest check: <from the Stop hook, or 'none yet'>."
   b. For every card with `status: todo` and `seat: builder`, spawn one **builder** per card
      ("Card <id>"), in parallel, at most 3 at a time. Cards with `seat: scout` go to the scout.
   c. Spawn the **verifier**: "Verify round N."
   d. Stop. The Stop hook re-runs every check. If the run is not done it blocks the stop and
      tells you the weakest check; start the next round from (a).
4. Cards in `needs_human` and files in `harness/current/approvals/` are mine. If nothing else can
   move, run `python3 harness/bin/harness.py pause "<what you need from me>"` and stop.
5. When the hook reports done, show me `harness/current/report.md` (checks, rounds, cost by seat
   vs. one model for everything) in under 15 lines.

Never write receipts yourself, never edit GOAL.md during the run, never send, delete, pay or
publish anything — those go to approvals.
