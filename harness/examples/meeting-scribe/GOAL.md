# GOAL: Export a meeting as Markdown with action items

## Outcome
`MeetingScribe --export <transcript.json>` writes a Markdown file with the title, date,
attendees, the transcript, and an "Action items" section, and the test suite covers it.

## Checks
- id: C1
  desc: The package builds
  cmd: swift build
  expect: exit 0
  timeout: 1200
- id: C2
  desc: Export tests exist and pass
  cmd: swift test --filter ExportTests
  expect: stdout matches Executed [1-9][0-9]* tests?, with 0 failures
  timeout: 1200
- id: C3
  desc: The full suite still passes
  cmd: swift test
  expect: exit 0
  timeout: 1800
- id: C4
  desc: Export output has every required section
  cmd: swift run MeetingScribe --export Tests/MeetingScribeTests/Fixtures/sample.json --stdout | grep -c -E '^## (Attendees|Transcript|Action items)$'
  expect: stdout contains 3

## Out of scope
- Audio capture, transcription, and the menu-bar UI.
- Releases, tags, and anything under .github/.

## Stop rules
- Pause and ask me before changing the transcript JSON format.
- max_rounds: 6
