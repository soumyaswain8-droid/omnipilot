# Spec: Phase 1 / Increment 1 — Reliable Noise Gate (Approach A)

_Date: 2026-07-03 · Phase 1 (Signal Quality), Increment 1 · Approach A (fix the existing Silero path)_

## Problem
OmniPilot records non-speech noise (fans, keyboard, ambient) because it silently falls back to a
dumb energy gate. Two bugs in the Silero VAD path cause this:
1. **Frame-size mismatch** — `Pipeline` feeds 480-sample frames; Silero requires exactly **512**.
   `SimpleVAD` zero-pads 480→512, which corrupts Silero's *stateful* inference.
2. **5ms IPC timeout → energy fallback** — a per-frame TCP round-trip to `vad_service.py` routinely
   exceeds 5ms under load, so the code falls back to `rms > threshold`, which cannot tell a fan from a voice.

## Goal
Non-speech noise is reliably rejected via the neural Silero VAD; energy detection is used ONLY when
the Silero service is genuinely unavailable.

## Changes (3 files)
1. **`Pipeline.swift`** — carry sub-512 remainder across 1-second chunk boundaries and feed VAD exact
   **512-sample contiguous frames** (16000 = 31×512 + 128 remainder → carry the 128). Run chunk
   processing on a **dedicated serial queue**, not the real-time audio callback thread (this is why
   the 5ms timeout existed — blocking the tap thread for ~31 round-trips/sec dropped audio).
2. **`SimpleVAD.swift`** — accept exactly 512-sample frames (no padding); raise the Silero IPC timeout
   5ms → **40ms**; fall back to energy ONLY when the connection is down (track connection state), not
   on per-frame lag; reset Silero state on (re)connect; `os_log` the active path (silero/energy) and
   per-segment classification for observability.
3. **Verification hook** — reuse the existing `os_log` VAD/RMS trace.

## Out of scope (later Phase 1 increments)
- Intent-parser precision (command vs statement); dedup — post-transcription, not capture.
- TV removal — needs Increment 2 (speaker enrollment).

## Verification
- **Live integration test (primary):** play fan/keyboard noise near the mic → expect **no** new memory
  and VAD trace showing `silero` active + speech NOT triggered; then speak a sentence → expect one
  memory and a `Transcribed` log. Confirms neural VAD is actually in use (not energy fallback).
- **Regression:** normal speech (RMS ~0.02) still captured end-to-end.

## Risks
- Serial-queue backpressure if VAD + whisper exceed 1s/chunk — mitigated: whisper already runs in a
  detached `Task`; the VAD loop is ~31 fast round-trips (<100ms/chunk).

## Resolution & deeper root cause (found during implementation)
The Swift-side bugs (framing, timeout) were real but NOT the whole story. `vad_service.py` itself was
broken, so **Silero had never functioned** — the app was always on the energy gate:
1. **v4/v5 API mismatch** — the service called Silero with the v4 signature (`h`,`c` states) but the
   model is v5 (single `state` tensor). Every inference threw, was swallowed by `try/except`, and
   returned `0.0` → "non-speech" for everything.
2. **Missing 64-sample context** — Silero v5 requires `[64 prev-samples] + [512 new] = 576` per call;
   bare 512-frames yield ~0 probability even for loud speech.
3. **Shared LSTM state** across connections — corruptible; now per-connection.

Fixes (`vad_service.py`): v5 API, 64-sample context carry, per-connection `VADState`.
Component proof: tone 0% / white-noise 0% / **speech 98%** speech-frames (was 0% for all — broken).
Also fixed a ~1.5s startup flap to the energy gate (redundant `reconnectSilero`).

## Honest verification note
Component-level discrimination is decisively proven (numbers above; validated against the reference
`silero-vad` package on the identical model file). Live acoustic-loopback testing (playing synthetic
tone/noise through speakers into the mic) is confounded by room coloration, real ambient activity, and
Whisper hallucinating sentences from noise — so it is not a clean VAD test. Real-world benefit (reject
fan/keyboard/ambient while a person speaks) rests on the now-functioning neural VAD. Residual: Whisper
still hallucinates on borderline audio (mitigated by the hallucination filter; fuller fix = Increment 2
speaker enrollment).
