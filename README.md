# MeetingScribe

**The hard part of recording a meeting is not the transcription — it is everyone else on the call.**

A macOS menu-bar app that notices when you are in a Zoom, Google Meet, Teams, Webex or Slack huddle call, records it, and writes a timestamped transcript to disk. Everything runs on the machine — no server, no account, no virtual audio driver, no audio leaving the laptop.

---

## The product argument

**1. On-device, because the alternative makes a decision on other people's behalf.**
A cloud recorder buys real diarization and better accuracy on hard audio, and pays for it by putting colleagues' voices on a third party's servers — a choice you make for them, usually without telling them. MeetingScribe takes the worse model on purpose: ScreenCaptureKit taps the system mix and microphone directly (**no BlackHole, no Loopback, no admin password**) and transcription is `SFSpeechRecognizer` in on-device mode. Screen Recording sounds heavier than it is — the video stream runs at **2×2 pixels, 1 fps** and every frame is discarded on arrival. It is the only route macOS offers to system audio without a kernel driver.

**2. Consent is a product surface, not a disclaimer.**
California, Florida, Pennsylvania, Washington, Illinois and several other states require **every** party to consent; most of the EU is stricter. So the app refuses to let you confuse two things: **"Notify when recording starts" notifies *you*, and is not consent from anyone else on the call.** The recording state is also not hideable — the menu-bar icon carries a filled record symbol and a `REC` label the whole time it runs (`‖` when paused), notifications on or off. Tell people you are recording; software cannot do that part for you.

**3. Auto-detect with asymmetric hysteresis, and a manual override the detector can never cancel.**
A poll checks two signals every **5 seconds**: a meeting window on screen (native clients by bundle ID, browser calls by tab title), and the default input device actually hot. Both must hold for **two consecutive polls (~10 s)** to start; it takes **six consecutive misses (~30 s)** to stop. The asymmetry is the design: a false start records a meeting link you merely opened, while a false stop cuts a transcript in half on a page reload. Detection is localized — a Zoom client in Chinese titles its window 会议.

**4. Two tracks instead of diarization — an honest ceiling, stated.**
System track and mic track are captured and transcribed separately, so the transcript separates **You** from **Participants** with no model at all. It will not tell two participants apart, and naming that beats shipping a speaker label that is wrong a third of the time.

**5. The follow-ups section is a keyword index, and is labelled as one.**
There is no language model in this app, and pretending otherwise would produce confident nonsense. `ActionItems` matches about thirty commitment cues ("I'll", "can you", "by Friday") on lines of **5–60 words**, capped at **12** — shorter lines are fragments, longer ones are the recogniser missing a sentence boundary. Every line keeps its timestamp and the heading reads *Possible follow-ups*: an index, not a summary.

---

## Output

Each meeting gets a folder in `~/Documents/MeetingScribe/`: `transcript.md`, `transcript.json` (per-line timestamps), `transcript.vtt`, and `microphone.m4a` / `system.m4a` at 16 kHz mono.

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

That title comes from your calendar, because window titles are useless — Google Meet gives you `Meet - abc-defg-hij`. Access is optional; the event is picked by a heuristic preferring one already in progress, with attendees and a conference link.

Recording goes to WAV because raw PCM survives a crash; the transcript is rewritten every **30 seconds**, and startup repairs the WAV header a killed process left claiming zero bytes. On a clean end the tracks transcode to M4A — **230 MB/hour down to about 15**.

## Install

Download `MeetingScribe.zip` from the [latest release](../../releases/latest), unzip, drag the app to `/Applications`. It is ad-hoc signed rather than notarized, so first launch needs `xattr -dr com.apple.quarantine /Applications/MeetingScribe.app`. From source (macOS 15+, Xcode 16+):

```bash
git clone https://github.com/chloe4ai/meeting-scribe.git
cd meeting-scribe && ./scripts/build-app.sh && open dist/MeetingScribe.app
```

**Permissions** (System Settings › Privacy & Security; the menu's *Privacy Settings…* opens the pane): Screen Recording, Microphone, Speech Recognition required, Calendars optional.

> **Re-grant Screen Recording and Microphone after every update.** macOS ties grants to a code signature, so each ad-hoc signed build is a new app to TCC and starts silently unpermissioned. The symptom is a recording that produces an empty transcript — which is what the self-test catches:

```bash
open -a /Applications/MeetingScribe.app --args --self-test
```

It checks every permission, then pushes a synthesised phrase through the real resampler and recogniser (`~/Library/Logs/MeetingScribe-selftest.txt`). Use `open`, not the binary — a shell-started binary attributes privacy requests to the terminal, which has no speech usage description, and macOS kills it.

The menu holds start/stop, pause/resume, the last eight transcripts, ⌘F search, transcription language, and toggles for auto-record, compression, notifications, audio retention, calendar titles and launch-at-login.

## Known limits

- **macOS 15+ only** (`SCStreamConfiguration.captureMicrophone` is 15.0).
- **Accuracy is Apple's on-device model** — weaker on accents, crosstalk and jargon. There is no WER number here because I have not run one. `TranscriptionBackend` is a protocol, so a whisper.cpp or cloud backend drops in without touching capture.
- **One language per recording.** `Locale.current` is the wrong default for anyone bilingual — a Mac set to English transcribes a Mandarin call into confident nonsense — so it is an explicit choice. A call that switches mid-way still transcribes only one side well.
- **Browser calls are detected by window title**, so a browser hiding tab titles from ScreenCaptureKit is invisible; search is substring, not stemming.
- **Up to 30 seconds of transcript** can be lost in a hard crash between autosaves (the audio is recoverable), and a fixed **~26 ms** tail stays in the resampler at the end of each recording — 99.5% of input retained, not a per-buffer drop.

## What I'd build next

- **A WER harness** over held-out call audio, per language and acoustic condition, so "swap in whisper.cpp" becomes a measured decision rather than an assumed upgrade.
- **Precision and recall on follow-ups.** Hand-label commitments in a dozen transcripts and score the cue list against them; that number decides whether the section belongs above the transcript.
- **A consent prompt at record time**, plus a count of how often it is dismissed — a compliance affordance nobody uses is not one.

## License

MIT
