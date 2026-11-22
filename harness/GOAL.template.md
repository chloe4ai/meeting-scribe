# GOAL: <short title>

## Outcome
<One sentence a stranger could verify without asking you anything.>

## Checks
<!-- Each check is a command run from the repo root plus an expectation:
     exit N | stdout contains TEXT | stdout matches REGEX. Optional: timeout (seconds). -->
- id: C1
  desc: <what this proves>
  cmd: <shell command>
  expect: exit 0
- id: C2
  desc: <what this proves>
  cmd: <shell command>
  expect: stdout contains PASS

## Out of scope
- <files, systems or decisions nobody touches in this run>

## Stop rules
- Pause and ask me before anything that sends, deletes, pays or publishes.
- Pause and ask me if a check turns out to need my judgment.
- max_rounds: 6
