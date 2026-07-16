# Design: Both-sides meeting capture + start/stop lifecycle

**Status: DRAFT — presented to Soumya 2026-07-15, PAUSED awaiting approval.**
On resume: re-present the design below and ask "does this look right, or should anything change before I write the spec?" After approval → spec self-review → user review gate → superpowers:writing-plans → implementation.

## Why (context)

2026-07-15: a 35-min Google Meet recording captured almost nothing — AirPods were the
output device, so remote audio played into the AirPods and never reached any mic
(avfoundation `:0` = AirPods mic = wearer's side only). The transcript was ~1.2 KB of
sound-effect tags, and `finalize_notes.py` (llama3.2:3b) confabulated entirely fake
notes from it. Constraint from Soumya: during meetings the Mac is *usually* connected
to earpods or other output devices — so system-audio loopback capture is mandatory.

## Decisions locked (via Q&A)

1. **System-audio capture = Core Audio process tap** (driver-free Swift CLI), NOT
   BlackHole. Zero routing changes, works with any output device, no admin install.
2. **Own voice included**: record system-default mic, live-mix with tap into one WAV.
3. **Auto-finish on stop**: stop = halt recorders + transcribe tail + generate notes
   (with thin-transcript hallucination guard).

## Design (as presented)

### 1. New component — `omni-audiotap` (Swift CLI, ~150 lines, `vendor/audiotap/`)
Uses macOS's Core Audio process-tap API (driver-free system-audio capture, macOS 14.2+)
to grab the global output mix — whatever is playing, wherever it's routed (AirPods,
speakers, any bluetooth). Streams 16-bit PCM to stdout. Compiled once with `swiftc`,
no dependencies, no admin rights. First run triggers a one-time "System Audio
Recording" permission prompt from macOS.

### 2. Single mixed recording pipeline
```
omni-audiotap (remote audio) ──┐
                               ├── ffmpeg amix → mic_TS.wav (16 kHz mono)
default mic (your voice) ──────┘
```
One growing WAV, exactly what `meeting-notes.sh` already watches — the
transcript/notes/OCR layers need zero changes. The mic input uses the system default
device, so it auto-follows whatever mic the meeting app is using.

### 3. `meeting-ctl.sh start [--video <dir>]` — with pre-flight
Checks before recording a single byte: disk free (abort under 2 GB, warn under 10),
prints which output/input devices are being captured (so the silent AirPods trap is
impossible), whisper-server up (starts the native Metal build if not), then launches:
mixed audio pipeline → state file → transcript loop (`NOTES_LLM=0`) → OCR loop.
Video stays off unless `--video /Volumes/...` is passed.

### 4. `meeting-ctl.sh stop` — auto-finish
Gracefully stops recorders, transcribes the untranscribed tail, then runs
`finalize_notes.py` **only if the transcript has enough real speech** (guard: skip +
warn below a minimum — the hallucination fix). Prints the artifact folder. Also fixes
the existing bug where stop's pkill pattern (`whisper-server -m`) never matches the
actual `--model` invocation.

### 5. Degradation
Tap binary missing or permission denied → falls back to mic-only with a loud red
warning at start (never silently one-sided again). Mic unavailable → tap-only, same
warning style.

### 6. Test plan
60-second live test: AirPods in, YouTube playing, Soumya speaks a sentence — verify
both the video's audio and the sentence appear in the transcript.

## Environment notes (as of 2026-07-15)
- Internal disk was 100% full; cleared caches → ~5.5 GB free. Re-check at resume.
- whisper-server: native arm64+Metal build at `vendor/whisper.cpp/build/bin/`,
  models `ggml-small.en.bin` + `ggml-base.en.bin` present.
- ffmpeg at `~/development/bin/ffmpeg` (avfoundation OK).
- The 2026-07-15 meeting artifacts live in `data/meetings/mic_2026-07-15_12-04-37.*`
  — notes.md carries a DO-NOT-TRUST banner; links.md (14 OCR'd URLs) is the salvage.
