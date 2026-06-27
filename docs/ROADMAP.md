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
