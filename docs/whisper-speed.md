# Whisper Transcription Speed (Apple Silicon)

## STATUS: RESOLVED (2026-06-27)
Built a native arm64 + Metal `whisper-server` into `vendor/whisper.cpp/`. `run.sh` now prefers
it automatically. Measured result on the same 4s clip:

| Build | Model | Latency |
|-------|-------|---------|
| x86_64 Rosetta, CPU-only (old) | small.en | ~16s |
| **native arm64 + Metal (now)** | **small.en** | **~1.1s** (≈14x faster) |

`vendor/` is gitignored (build artifacts). To rebuild on another machine, follow
"Fix option 3" below — the key flag is **`-DGGML_NATIVE=OFF`** (see Gotcha).

### Exact commands that worked
```bash
cd vendor   # under the omnipilot project
# 1. native arm64 cmake (no Homebrew) — Kitware universal tarball includes arm64
curl -sL https://github.com/Kitware/CMake/releases/download/v4.3.3/cmake-4.3.3-macos-universal.tar.gz | tar xz
CMAKE="$PWD/cmake-4.3.3-macos-universal/CMake.app/Contents/bin/cmake"
# 2. build whisper.cpp arm64 + Metal
git clone --depth 1 https://github.com/ggerganov/whisper.cpp.git
cd whisper.cpp
"$CMAKE" -B build -DCMAKE_OSX_ARCHITECTURES=arm64 -DGGML_METAL=ON \
         -DGGML_NATIVE=OFF -DWHISPER_BUILD_SERVER=ON -DCMAKE_BUILD_TYPE=Release
"$CMAKE" --build build -j --config Release --target whisper-server
# -> vendor/whisper.cpp/build/bin/whisper-server  (Mach-O arm64, Metal embedded)
```

### Gotcha
Because the shell runs under Rosetta, ggml's CMake detects an x86 host and adds `-mcpu=native`,
which clang rejects when targeting arm64 (`unsupported argument 'native' to option '-mcpu='`).
Setting `-DGGML_NATIVE=OFF` disables that host-CPU auto-tuning; the arm64 baseline + Metal GPU
is what delivers the speed anyway.

---

## Original diagnosis (kept for reference)

On this machine (Apple M1), the Homebrew `whisper-server` is an **x86_64 binary running under
Rosetta 2 with no Metal GPU acceleration** — ~10–16x slower than native. The app was otherwise
fully functional; this was purely latency.

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
