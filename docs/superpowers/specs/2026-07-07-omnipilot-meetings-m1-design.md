# OmniPilot Meetings — M1 (Backbone) Design

_Date: 2026-07-07 · Pillar M, Increment 1 · Status: approved design, pre-implementation_

## Goal

Turn the proven meeting-capture pipeline (built ad-hoc on 2026-07-05) into a first-class feature of the
OmniPilot macOS menu-bar app: **detect a meeting → record mic audio → transcribe → summarize → publish
notes + transcript + audio to a shared folder** so teammates can revisit and share. Local-first capture,
central shared archive (hybrid).

This is the **backbone vertical slice**. It must work end-to-end inside the app, reusing the existing
`AudioCapture`, `WhisperBridge`, and `OllamaClient`. Everything else (system-audio tap, calendar,
OCR links, web archive) is deferred and layers onto this.

## Scope

### In scope (M1)
- Meeting lifecycle: start (auto via detection OR manual) → record → stop (auto OR manual) → process → publish.
- **Mic-only** audio capture, continuous (not VAD-gated), for the meeting's full duration.
- Rolling transcription during the meeting + a final pass at end (via `whisper-server`).
- **Map-reduce** summarization → structured notes (TL;DR, key points, action items) via Ollama.
- Publish `notes.md`, `notes.pdf` (best-effort), `transcript.md`, `audio.m4a` to a user-configured shared folder.
- Menu-bar UI: status line, manual Start/Stop, recent-meetings list (opens the folder), Settings (archive path).
- Detection trigger: **mic-in-use** signal + known meeting apps (Zoom/Teams/Webex) via `NSWorkspace`.

### Out of scope (deferred — see Roadmap Follow-ons)
- System-audio process tap / headphone support (M2).
- Calendar integration, scheduled arming, attendee/title metadata (M3).
- OCR on-screen link capture (M4).
- Static web archive + transcript search (M5).
- Screen/video recording (explicitly dropped for now).
- Speaker diarization (ties to Phase 1 Increment 2).

## Architecture

New Swift components under `Sources/Meetings/`, orchestrated by a `MeetingCoordinator`. Reuse existing
audio/LLM plumbing. The always-on personal-assistant `Pipeline` is **paused** while a meeting is active
(single mic engine; see Concurrency).

```
MeetingDetector ──start/stop──▶ MeetingCoordinator
                                    │
                    ┌───────────────┼─────────────────┐
                    ▼               ▼                 ▼
            MeetingRecorder   MeetingTranscriber  MeetingSummarizer
             (AudioCapture)    (WhisperBridge)     (OllamaClient)
                    └───────────────┴─────────────────┘
                                    ▼
                            ArchivePublisher ──▶ shared folder
                                    ▼
                            MeetingsMenu (SwiftUI status + controls)
```

### Components

**MeetingDetector** — emits `.meetingStarted(source:)` / `.meetingEnded`.
- Primary signal: **mic-in-use** — a CoreAudio property listener on `kAudioDevicePropertyDeviceIsRunningSomewhere`
  for the default input device.
  - **Start**: rising edge (mic goes active) held >5 s ⇒ meeting started. Debounced to ignore Siri/voice-memo blips.
  - **End = call disconnected**: the meeting app **releases the mic** (falling edge) held > `endDebounceSeconds`
    (default 15 s) ⇒ the call ended / you left. This is the real end-of-call signal.
    - **Mute does not release the device** — the meeting app keeps capturing while muted — so muting never
      false-stops the recording. Only an actual disconnect (or the meeting app quitting) releases the mic.
    - The debounce rides out transient device blips (brief driver hiccups, device switches).
- Also ends on `NSWorkspace.didTerminateApplicationNotification` for a known meeting app (belt-and-suspenders
  for "call over → app quit").
- Enrichment: `NSWorkspace.didLaunchApplicationNotification` for bundle IDs `us.zoom.xos`,
  `com.microsoft.teams2`, `com.cisco.webexmeetingsapp` raises start confidence / labels the source.
- Manual override always available (menu Start/Stop) and takes precedence.
- Interface: `protocol MeetingDetecting { var events: AsyncStream<MeetingEvent> { get }; func start(); func stop() }`

**MeetingRecorder** — owns a continuous recording session.
- Uses `AudioCapture` mic stream; accumulates `[Float]` (16 kHz mono) to a growing buffer AND writes an
  `audio.m4a` (AVAudioFile, AAC) for the archive.
- Exposes `func windowSince(_ offset: Int) -> [Float]` so the transcriber can pull only new audio.
- `start(url:)`, `stop() -> URL` (finalized m4a). Crash-safety: flush the AVAudioFile periodically.

**MeetingTranscriber** — rolling transcription.
- Every ~90 s, pulls the new audio window from the recorder and calls `WhisperBridge.transcribe(audioSamples:)`.
- Appends timestamped entries to an in-memory transcript + `transcript.md`. Applies `Pipeline.isHallucination`
  filtering. Final `flush()` transcribes the tail after `stop`.
- Ground truth: transcript is stored raw (no LLM "correction").

**MeetingSummarizer** — map-reduce over the full transcript (ported from the 2026-07-05 `finalize_notes.py`).
- MAP: chunk transcript (~12k chars) → per-chunk bullet summary via `OllamaClient.generate`.
- REDUCE: combine chunk summaries → structured notes (TL;DR, Key Points, Action Items).
- Model: fastest available small model (`OllamaClient.selectBestAvailableModel`, e.g. `llama3.2:3b`).
  Runs once at meeting end (GPU free). Deterministic mishear-normalization is a simple pre-pass.

**ArchivePublisher** — writes the artifact set to `<archiveRoot>/<YYYY-MM-DD_HH-MM>_<title|Meeting>/`.
- Files: `notes.md`, `transcript.md`, `audio.m4a`, and `notes.pdf` (best-effort via `dp content render` if
  present on PATH; skip silently if not — never block).
- `archiveRoot` defaults to `~/OmniPilot Meetings`; user points it at a synced Drive/Dropbox/iCloud folder
  in Settings. That folder's own sync = team sharing (no server in M1).

**MeetingsMenu (SwiftUI)** — extends the existing menu-bar UI.
- Status: `Idle` / `Recording 12:34` / `Transcribing…` / `Summarizing…` / `Published ✓`.
- Manual Start/Stop meeting. Recent meetings list (last 10) → opens that meeting's folder in Finder.
- Settings: archive folder picker; detection on/off; "always keep manual control".

**MeetingCoordinator** — the state machine tying it together.
- States: `idle → recording → finalizing(transcribe tail → summarize → publish) → idle`.
- Subscribes to `MeetingDetector.events`; guards against double-start; owns the current `MeetingSession`.

## Data flow

1. Detector fires `.meetingStarted` (mic active >5 s, Zoom running) → Coordinator pauses assistant Pipeline,
   starts MeetingRecorder + MeetingTranscriber; menu shows `Recording`.
2. Every ~90 s: Transcriber appends a new transcript window.
3. Detector fires `.meetingEnded` — the meeting app **released the mic** (call disconnected/you left) held
   > `endDebounceSeconds`, OR the meeting app quit, OR user clicks Stop → Coordinator: finalize recorder →
   transcribe tail → run Summarizer → ArchivePublisher writes folder → resume assistant Pipeline → menu shows
   `Published ✓` with a notification linking the folder.

## Concurrency / interaction with existing Pipeline

`AudioCapture` drives a single `AVAudioEngine`. Meeting mode and the always-on assistant cannot both own it.
M1 rule: **while a meeting is active, the assistant `Pipeline` is stopped**, and MeetingRecorder owns the mic.
On meeting end, the assistant resumes. The Coordinator serializes this. (M2's system tap will let both coexist.)

## Configuration

Persisted via `UserDefaults` (or existing settings store):
- `meeting.archiveRoot: String` (folder path)
- `meeting.autoDetect: Bool` (default true)
- `meeting.minMeetingSeconds: Int` (default 60 — discard sub-minute false triggers, don't publish)
- `meeting.endDebounceSeconds: Int` (default 15 — mic must stay released this long before we treat the call
  as disconnected; rides out transient device blips)

## Error handling

- whisper-server down → Transcriber retries next cycle; `WhisperBridge` CLI fallback; if all fail, still
  archive the audio + a `transcript.md` stub noting transcription unavailable.
- Ollama down → publish transcript + audio; `notes.md` says "summary unavailable (Ollama offline)".
- Archive folder missing/unwritable → keep artifacts in the local default root, surface a menu warning.
- App quit / crash mid-meeting → periodic m4a + transcript.md flush means the audio + partial transcript
  survive; a stale session is detected on next launch and offered for finalize.
- Sub-`minMeetingSeconds` sessions are discarded (no publish, no notification).

## Testing

- **Unit**: MeetingSummarizer map/reduce chunking (deterministic given fixed model responses — inject a fake
  `OllamaClient`); ArchivePublisher path/naming; Detector debounce logic (feed synthetic mic-active edges);
  `isHallucination` reuse.
- **Integration**: feed a known 3-minute wav through Recorder→Transcriber→Summarizer→Publisher with a stub
  Ollama; assert the folder contains the four artifacts and notes has the required sections.
- **Manual/live**: start a real Zoom test call on speakers → confirm auto-start, live transcript growth,
  auto-stop, published folder. (Register the integration suite in `project_test_config` per the test rule.)

## Verification

- Launch app → join a Zoom call on speakers → menu shows `Recording` within ~5 s (no manual action).
- Speak for ~2 min, end call → within ~1 min menu shows `Published ✓`, a folder appears in the archive root
  with `notes.md` (TL;DR + key points + action items), `transcript.md`, `audio.m4a`.
- Manual Start/Stop works with detection off.
- Drop whisper-server → audio + stub still archived (graceful degradation).

## Risks

- **Mic contention** with the assistant Pipeline — mitigated by pause/resume; must be race-free (Coordinator serializes).
- **False triggers** (Siri, voice memos, music) — mitigated by mic-active debounce + `minMeetingSeconds` discard + app-list confidence.
- **End-detection edge case**: a few browsers keep the mic device warm briefly after a Meet call ends, delaying
  the release edge. Mitigated by `endDebounceSeconds` + app-terminate signal + manual Stop; native apps
  (Zoom/Teams/Webex) release promptly. Robust browser handling arrives with M3 (calendar end times).
- **Mic-only fidelity** — one-sided on headphones; accepted for M1, resolved by M2 (system tap). Menu copy should
  hint "on speakers for full capture until the audio upgrade ships".
- **Long-meeting summary cost** — map-reduce keeps each Ollama call small; runs once at end when GPU is free.

## Roadmap follow-ons (not this spec)
M2 system-audio tap · M3 calendar · M4 OCR links · M5 web archive. Each its own spec → plan → build.
