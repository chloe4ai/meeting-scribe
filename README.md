# MeetingScribe

A macOS menu-bar app that notices when you're in a Zoom, Google Meet, Teams, Webex, or
Slack huddle call, records it, and writes a timestamped transcript to disk.

Everything runs locally. Audio never leaves the machine.

## How it works

**Detection.** A background poll checks two signals every five seconds: whether a meeting
window is on screen (native clients by bundle ID, browser calls by tab title) and whether
the default input device is actually hot. Both must hold for ~10 seconds before recording
starts, so a meeting link you merely opened won't trigger it. Recording stops after ~30
seconds without a meeting window, so a page reload doesn't cut the transcript in half.

**Capture.** Audio comes from ScreenCaptureKit, which taps the system mix and the
microphone directly — there is **no virtual audio driver to install** (no BlackHole, no
Loopback, no admin password).

**Speaker separation.** The system track and the mic track are captured and transcribed
separately, so the transcript distinguishes **You** from **Participants** without needing
a diarization model. It won't tell two participants apart — for that you'd want a cloud
service with real diarization.

**Transcription.** Apple's `SFSpeechRecognizer` in on-device mode. It stops on its own
after about a minute, so MeetingScribe rotates through short-lived recognition tasks: the
replacement request is opened before the outgoing one is closed, so nothing is lost at the
seam. Results are split into sentence-sized lines that carry their own timestamps.

**Titles.** Window titles are often useless — Google Meet gives you `Meet - abc-defg-hij`.
If you grant calendar access, the transcript is titled from the matching event instead and
records who was invited. The event is picked by a scoring heuristic that prefers one
already in progress, with attendees, and with a conference link attached. Access is
optional; without it everything falls back to the window title.

**Durability.** The transcript is rewritten to disk every 30 seconds while recording, so a
crash or forced quit mid-meeting leaves a usable file rather than nothing. Snapshots carry
a "recording in progress" banner that the final write clears.

## Output

Each meeting gets a folder in `~/Documents/MeetingScribe/`:

```
2026-08-13-1402-weekly-sync/
├── transcript.md       # readable, grouped by speaker
├── transcript.json     # per-line timestamps, for scripting
├── microphone.wav      # 16 kHz mono, ~7 MB/hour
└── system.wav
```

```markdown
# Q3 Roadmap Review

- **Platform:** Google Meet
- **Started:** Aug 13, 2026 at 2:02 PM
- **Duration:** 47m
- **Organizer:** Dana Reyes
- **Invited:** Dana Reyes, Sam Okafor

## Possible follow-ups

_Keyword matches, not a summary — check the timestamp for real context._

- `00:04:12` **You:** I'll send over the revised deck tomorrow morning.

## Transcript

**00:00:03 — You**

Let's start with the roadmap.

**00:00:12 — Participants**

Sounds good to me.
```

The follow-ups section is a keyword match over the transcript, not a summary — there is no
language model in this app, and pretending otherwise would produce confident nonsense.
Treat it as an index into the recording. It only appears when something matches.

Turn off "Keep audio files" in the menu if you only want the text.

## Install

Download `MeetingScribe.zip` from the [latest release](../../releases/latest), unzip, and
drag `MeetingScribe.app` to `/Applications`.

The build is ad-hoc signed rather than notarized, so the first launch needs:

```bash
xattr -dr com.apple.quarantine /Applications/MeetingScribe.app
```

Then open it. It lives in the menu bar with no Dock icon.

### Build from source

Requires macOS 15+ and Xcode 16+ (or Command Line Tools, though `swift test` needs full
Xcode for XCTest).

```bash
git clone https://github.com/chloe4ai/meeting-scribe.git
cd meeting-scribe && ./scripts/build-app.sh && open dist/MeetingScribe.app
```

## Permissions

macOS asks for three things on first run. All are required:

| Permission | Why | Required |
| --- | --- | --- |
| Screen Recording | ScreenCaptureKit's audio tap and window detection both live behind it | Yes |
| Microphone | Records your side of the call | Yes |
| Speech Recognition | On-device transcription | Yes |
| Calendars | Real meeting titles and attendee lists | Optional |

All four live under System Settings › Privacy & Security. The menu's **Privacy Settings…**
item opens the Screen Recording pane directly.

Screen Recording sounds heavier than it is: the video stream is configured at 2×2 pixels
and one frame per second, and the frames are discarded on arrival. It's the only route
macOS offers to system audio without a kernel-level driver.

If the menu reads "Screen Recording permission needed", grant it and relaunch — macOS
caches the denial for the lifetime of the process.

## Menu

- **Start / Stop Recording** — manual override. A manual recording is never stopped by the
  detector, so it keeps running even with no meeting window on screen.
- **Pause / Resume** — drops buffers while paused. Because the transcript clock counts
  frames written rather than wall time, the paused stretch is absent from the timeline
  instead of showing up as a long silence.
- **Recent Transcripts** — the last eight, opening straight to `transcript.md`.
- **Auto-record meetings** — the detector described above. Off means manual only.
- **Notify when recording starts** — a notification each time recording begins. See below.
- **Keep audio files** — off deletes the WAVs once the transcript is written.
- **Use calendar event titles** — prompts for calendar access the first time.
- **Launch at login** — registers via `SMAppService`. macOS only accepts login items from a
  stable location, so move the app to `/Applications` first.

The menu-bar icon shows a filled record symbol and a `REC` label the entire time it is
recording (`‖` when paused), whether or not notifications are enabled.

## Consent

Recording a call is not the same as being allowed to. California, Florida, Pennsylvania,
Washington, Illinois and several other states require **every** party to consent; most of
the EU is stricter still. "Notify when recording starts" only notifies *you* — it is not
consent from anyone else on the call. Tell people you're recording.

## Limitations

- macOS 15+ only (`SCStreamConfiguration.captureMicrophone` is 15.0).
- Doesn't separate individual participants — only you versus everyone else.
- Accuracy is Apple's on-device model: good on clear speech, weaker on heavy accents,
  crosstalk, and technical vocabulary. `TranscriptionBackend` is a protocol, so a
  whisper.cpp or cloud backend can be dropped in without touching the capture pipeline.
- Browser calls are detected by window title, so a browser that hides tab titles from
  ScreenCaptureKit won't be detected.
- Follow-ups are keyword matches, not a summary. Expect both misses and false positives.
- Up to 30 seconds of transcript can be lost in a hard crash, between autosaves. The WAVs
  on disk stay playable regardless.

## License

MIT
