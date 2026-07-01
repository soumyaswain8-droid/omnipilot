# Research: Meeting Notetaker + Calendar Scheduling for OmniPilot

_Date: 2026-07-01 · Method: multi-source deep research, adversarial verification (23 claims confirmed / 2 refuted, 26 sources)_

## Question
How to build an AI meeting-notetaker + calendar scheduling into OmniPilot (macOS, Apple Silicon,
local-first; already has mic capture + whisper.cpp + Ollama + SQLite memory). User constraints:
cloud/meeting-bots acceptable; calendar must target BOTH Google Calendar API AND Apple EventKit.

## Bottom line
OmniPilot already owns the expensive parts (on-device transcription + LLM + memory). A notetaker
needs a new **capture** path and **calendar** glue. Recommended: two capture modes (local Core
Audio tap for meetings you attend; Recall.ai bot for the rest), local whisper for transcription,
Ollama (or cloud LLM) for speaker-attributed summaries, dual Google + EventKit calendar.

## 1. Audio capture on macOS

### Core Audio process taps (macOS 14.4+) — recommended local path [high confidence, 3-0]
Any app can capture the audio output of a specific process (Zoom/Meet/Teams) or the whole system
and use it as an aggregate-device input "just like a microphone." Swift API chain:
`kAudioHardwarePropertyTranslatePIDToProcessObject` (PID → AudioObjectID) → `CATapDescription`
(per-process, mono/stereo mixdown) → `AudioHardwareCreateProcessTap` → `AudioHardwareCreateAggregateDevice`.
- Requires **`NSAudioCaptureUsageDescription`** + a **distinct TCC system-audio permission** (separate
  from the mic permission OmniPilot already holds) — a new consent flow. [3-0]
- Deployment-target note: OmniPilot currently targets macOS 14.0; taps need **14.4+**.
- Refs: Apple "Capturing system audio with Core Audio taps"; `github.com/insidegui/AudioCap` (reference impl).

### Meeting bots — Recall.ai (recommended build-vs-buy) [high, 3-0]
Single unified API: one `POST /api/v1/bot` joins & records Zoom, Google Meet, MS Teams, Webex,
Slack Huddles, GoTo Meeting from the meeting link.
- **Pricing (2026):** $0.50 / recording-hour (bot API and desktop SDK; down from $0.70), no platform
  fee, no participant limit. Built-in transcription +$0.15/hr — **skip it, use local whisper.** Storage
  beyond ~7 days +$0.05/hr. [3-0]
- Vendor claims it replaces ~3-5 engineers / ~6 months of in-house bot work (marketing figure).
- Refs: recall.ai/product/meeting-bot-api; recall.ai/blog/new-recall-ai-pricing-for-2026.

### Native platform pipelines — not viable in 2026 [high, 3-0]
- **Google Meet Media API**: real-time A/V but Developer-Preview only, requires the Cloud project,
  OAuth principal, AND *all meeting participants* enrolled → impractical for consumer use.
- **Zoom RTMS**: live A/V/transcript over WebSockets, designed to replace bots — promising *future*
  native path, but Zoom-only.
- Reinforces Recall.ai as the pragmatic multi-platform choice today.

### Refuted / corrected
- Taps require **macOS 14.4** (NOT 14.2, and NOT "introduced in macOS 26.0"). [0-3 on the wrong version]

## 2. Summaries & action items [high, 3-0]
- **Dual output**: quick highlights (overview) + hierarchical minutes (detail) — both valuable
  (peer-reviewed ACM study, n=7).
- **Speaker attribution matters**: speaker-aware summarization is harder but measurably better
  (~10% response gen, ~20% factual consistency) → invest in diarization, don't feed a flat transcript.
- **Long transcripts**: retrieve-then-summarize (RAG-style) outperformed Longformer/HMNet; applicable
  to OmniPilot's Ollama stack. (Research is pre-modern-LLM era; strategy holds, gains may differ.)
- **Action items**: Ollama structured output (Pydantic-style schemas) → feed into OmniPilot's existing
  task/scheduler system.

## 3. Calendar integration

### Google Calendar API [high, 3-0]
- **Read upcoming events + join links**: `calendar.events.readonly` is enough (`events.list`/`events.get`
  return `conferenceData`/`hangoutLink`/`entryPoints`) → auto-detect meetings and arm recording.
- **Create/schedule**: `calendar.events` (or broader `calendar`) scope. Attach a Meet via
  `conferenceData.createRequest` (unique `requestId`) + `conferenceDataVersion=1`.

### Apple EventKit [high, 3-0]
- iOS17/Sonoma tiers: no-access / write-only / full-access.
- **Must request FULL access** (`requestFullAccessToEvents`) to READ events; write-only only creates.
- Gotcha: OS upgrades default previously-granted apps to write-only — handle the migration.

## Open questions (need follow-up before building)
1. **On-device speaker diarization** — whisper.cpp doesn't do it. Options: sherpa-onnx / pyannote
   (bridge) locally, or Recall's built-in diarization on the bot path. Accuracy/latency on M1 TBD.
   (Shared with Phase 1 Increment 2 — speaker enrollment.)
2. **Mic + system-audio mixing** — concrete Swift approach to sync/mix mic + tapped system audio for
   diarized transcription (single aggregate device vs two time-aligned streams).
3. **ScreenCaptureKit (13+) vs Core Audio taps (14.4+)** — not adjudicated; tradeoff on macOS support
   floor and TCC category (screen-recording vs audio-capture).
4. **Competitor/pricing landscape** (Granola/Otter/Fireflies/Fathom/tl;dv/Read.ai/Gemini/Zoom AI
   Companion/MS Copilot/Magic Minutes) — did NOT survive verification; needs a dedicated pass.

## Recommended build & phasing for OmniPilot
- **M1 — Local meeting capture + summary**: Core Audio tap (target 14.4) mixing meeting audio + mic →
  existing whisper → Ollama dual-output summary + action items → memory + tasks. Reuses ~everything.
- **M2 — Calendar glue**: Google (`readonly` detect + arm; `events` schedule) + EventKit (full access
  read). Auto-detect upcoming meeting → arm capture; voice "schedule…" → create event.
- **M3 — Bot path**: Recall.ai for unattended/remote meetings; pull audio → local whisper.
- **Diarization**: shared with Phase 1 Increment 2 (speaker enrollment).
