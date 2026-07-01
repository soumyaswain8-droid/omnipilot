# OmniPilot Roadmap

Local-first, voice-first personal AI memory assistant. This roadmap is sequenced by
**dependency**: data quality → value → capability → reach. Each phase rests on the one before
it — better recall over a memory full of TV transcripts only surfaces garbage faster, and
firing real-world actions off a trigger-happy intent parser is risky.

_Last updated: 2026-06-27_

## Current state (baseline)
The core voice pipeline is working and verified end-to-end:
- Capture → transcribe (native arm64 + Metal whisper, ~1.1s) → store → semantic recall → voice commands → tasks.
- Recently fixed: dead audio capture (AVAudioEngine 0 Hz format bug), lossy embeddings
  (48 backfilled + self-heal sweep), dead Cmd+Shift+O hotkey, and ~14x whisper speedup.
- Known rough edges feeding Phase 1: over-captures ambient/TV audio; intent parser is
  trigger-happy (tags statements as commands).

---

## Phase 1 — Signal Quality *(foundation — in progress)*
Make it capture **you**, correctly classified. Everything downstream inherits this quality.
- **Speaker enrollment / diarization** — distinguish your voice from others/TV (reuse the
  existing embedding-service infra for voice fingerprints).
- **VAD tuning** — Silero VAD gating to reject media/ambient audio.
- **Intent precision** — command vs statement classification; kill misfires like
  "the espresso machine arrived" → task.
- **Dedup** — collapse near-identical / repeated transcriptions.

Outcome: a clean, trustworthy memory stream.

## Phase 2 — Useful Recall *(make the data pay off)*
- Hybrid FTS5 + vector reranking (RRF) for sharper answers.
- A genuinely good daily/weekly digest (themes, people, action items) — upgrade the 6 PM summary.
- Proactive surfacing — "you said you'd call the dentist."

## Phase 3 — Actions / Integrations *(voice → real action)*
- WhatsApp send (the watcher already exists — close the loop).
- Calendar / Reminders via EventKit.
- Email drafts, with a confirm-before-fire safety gate.

_Depends on Phase 1: real side-effects demand reliable intent classification first._

## Pillar M — Meetings *(new; notetaker + scheduling)*
Turn OmniPilot into a meeting notetaker + scheduler. Shares DNA with Phase 1 (capture/diarization)
and Phase 3 (calendar/actions). Full research + citations: `docs/research/2026-07-01-meeting-notetaker.md`.
- **M1 — Local meeting capture + summary**: macOS Core Audio process tap (14.4+) mixing meeting-app
  audio + mic → existing whisper → Ollama dual-output summary (highlights + minutes) + action items.
- **M2 — Calendar glue**: Google Calendar (`events.readonly` to auto-detect meetings & join links and
  arm capture; `events` to schedule) + Apple EventKit (full access to read). Voice "schedule…" → event.
- **M3 — Bot path**: Recall.ai ($0.50/recording-hr) for unattended/remote meetings → pull audio to
  local whisper (skip their transcription).
- **Depends on:** Phase 1 capture foundation + Increment 2 speaker enrollment (diarization is shared);
  Phase 3 calendar/actions. Natural slot: after Phase 1 Signal Quality.

## Phase 4 — Mobile Reach *(biggest scope, last)*
- Flutter app + on-device whisper.
- LAN sync of `memory.sqlite` (local-first, no cloud).

_Done last so we port a proven product, not a moving target._

---

## Quick hygiene wins (fold in opportunistically)
- `scripts/build-whisper.sh` — reproducible native arm64 + Metal whisper build
  (currently a manual process under the gitignored `vendor/`; see `docs/whisper-speed.md`).

## Process
Each phase gets its own spec under `docs/superpowers/specs/` before implementation, then an
implementation plan. The roadmap bullets stay high-level until a phase's turn comes.
