# Harness contract

Applies only while a run is active (`python3 harness/bin/harness.py status` says `running`).
Outside a run, work normally.

1. Work only from files in `harness/current/` and the repo, never from chat memory.
   `GOAL.md` is the finish line, `map.md` is the scout's map, `cards/` is the plan.
2. One seat per subagent: advisor plans, scout reads, builder builds, verifier checks.
   A seat reads its own definition in `.claude/agents/` and stays inside it.
3. Every card is routed before work starts: `harness.py route <card>`.
   Confidence >= 0.80 goes to the seat; 0.50-0.80 the advisor decides and writes
   `route_reason:`; below 0.50 goes to `questions.md` for the human.
4. Builders never mark anything done and never edit `GOAL.md` or `receipts/`.
   Only the verifier makes receipts, and only through `harness.py receipt <check>`,
   which runs the check itself.
5. Anything that sends, deletes, pays or publishes goes to `harness/current/approvals/`
   as a file describing the action, and waits for the human.
6. Unsure? Write the question to `harness/current/questions.md` and take the next card.
   Blocked on the human with nothing else to do? `harness.py pause "<why>"`, then stop.
7. The Stop hook decides when the run is over. It re-runs every check and blocks the
   stop until all pass with receipts, or pauses the run at `max_rounds`.
