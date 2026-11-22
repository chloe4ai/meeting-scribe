---
description: Write a harness GOAL.md with me — a finish line made of runnable checks
argument-hint: <what you want built or produced>
---

Help me write `harness/GOAL.md` for: $ARGUMENTS

Ask me at most 5 questions first, one message, numbered. Then write the file in this shape
(copy `harness/GOAL.template.md` for the exact format):

- `## Outcome` — one sentence a stranger could verify.
- `## Checks` — numbered C1, C2, …; each is a shell command run from the repo root plus an
  expectation (`exit 0`, `stdout contains TEXT`, or `stdout matches REGEX`). Every check must be
  provable by a receipt. If a check needs my judgment, rewrite it until it doesn't — for example
  turn "the resume reads well" into a keyword-coverage script with a threshold.
- `## Out of scope` — what nobody touches.
- `## Stop rules` — when to pause and ask me, and `max_rounds:` (default 6).

If a check needs a small script that doesn't exist yet, write it under `harness/checks/` and say so.

Finish by running `python3 harness/bin/harness.py lint harness/GOAL.md` and fix anything it
reports. Do not start the run.
