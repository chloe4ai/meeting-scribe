---
description: Weekly harness audit — runs, stop rounds, failing checks, routing calibration, cost per seat
argument-hint: [days, default 7]
---

Run `python3 harness/bin/harness.py audit --days N`, where N is `$ARGUMENTS` (7 if empty), and read the reports in
`harness/runs/*/report.md` from that window.

Report to me, in under 20 lines:
- runs started vs. finished by the Stop hook, and average rounds to done
- cost of finished runs vs. the same tokens on one model for everything
- checks that failed two or more rounds
- cards routed below 0.80 confidence, and whether the advisor's confidence is calibrated
  (first-try pass rate should rise with the confidence bucket)
- any seat that worked outside its card's files (compare card `files:` with the receipts' commits)

Then suggest exactly one GOAL.md check to rewrite and one seat to adjust (model or instructions),
with the evidence. Change nothing without my yes.
