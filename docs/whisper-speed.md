# Whisper Transcription Speed (Apple Silicon)

## TL;DR
On this machine (Apple M1), `whisper-server` is an **x86_64 binary running under Rosetta 2
with no Metal GPU acceleration**. That makes transcription ~10–16x slower than it should be
(~16s for a 4s clip on `small.en`, vs <1s native). The app is otherwise fully functional —
this is purely latency.

## Diagnosis (2026-06-27)
```
$ uname -m                         # x86_64   <- shell is running under Rosetta
$ sysctl -n machdep.cpu.brand_string
Apple M1                            # ...on Apple Silicon hardware
$ file $(which whisper-server)
/usr/local/bin/whisper-server: Mach-O 64-bit executable x86_64   # Intel build
$ otool -L $(which whisper-server) | grep -i metal
(nothing)                          # no Metal -> CPU-only, emulated
```
Root cause: the entire Homebrew install is the **Intel** one at `/usr/local` (there is no
`/opt/homebrew`), so every CLI tool — including `whisper-cpp` — is x86_64 and runs under Rosetta.

## Measured latency (4s clip, machine under load)
| Model    | Size  | Latency (Rosetta) | Notes |
|----------|-------|-------------------|-------|
| base.en  | 141MB | ~5–7s             | DEFAULT — best balance |
| small.en | 465MB | ~16s              | previous default |
| medium.en| 1.5GB | very slow         | parked as `.bin.park` |

Native arm64 + Metal would put `small.en` well under 1s.

## Fix options (fastest → easiest)

### 1. Native arm64 whisper.cpp (the real fix — ~10x faster)
Install the Apple-Silicon Homebrew and the native `whisper-cpp`:
```bash
# Install ARM Homebrew (lives at /opt/homebrew, separate from the Intel one)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/opt/homebrew/bin/brew shellenv)"        # put this in ~/.zprofile
/opt/homebrew/bin/brew install whisper-cpp        # builds arm64 with Metal
```
Then ensure `/opt/homebrew/bin` precedes `/usr/local/bin` in `PATH` so `run.sh` picks the
native `whisper-server`. Verify: `file $(which whisper-server)` should say `arm64`.

### 2. Stay on Rosetta, use a smaller model (immediate, already applied)
`run.sh` now defaults to `base.en` (~3x faster than `small.en`) and accepts an override:
```bash
WHISPER_MODEL=$PWD/models/ggml-tiny.en.bin ./scripts/run.sh   # fastest, lower accuracy
```

### 3. Build whisper.cpp from source as arm64 with Metal
```bash
git clone https://github.com/ggerganov/whisper.cpp && cd whisper.cpp
cmake -B build -DGGML_METAL=ON -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build build -j --config Release
# use build/bin/whisper-server in run.sh
```

## run.sh recycle guard
`run.sh` now treats whisper as healthy only if it answers a health ping within 3s. A server
that holds the port but can't respond (overloaded / stale) is killed and restarted fresh,
instead of being left degraded.
