#!/bin/bash
# Launch OmniPilot with all services
set -e

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$PROJECT/build/OmniPilot.app"

echo "=== OmniPilot Launcher ==="

# 1. Ollama
if ! curl -s http://localhost:11434/api/tags &>/dev/null; then
    echo "[1/4] Starting Ollama..."
    ollama serve &>/dev/null &
    sleep 3
else
    echo "[1/4] Ollama: running"
fi

# 2. Whisper server (persistent — loads model once)
#
# Performance note: on Apple Silicon the FAST path is a NATIVE arm64 whisper.cpp with Metal
# (transcribes a few seconds of audio in <1s). If whisper-server is an x86_64 binary running
# under Rosetta (no Metal), transcription is ~10-16x slower. We warn about that below.
#
# Model choice trades accuracy vs latency. Override with: WHISPER_MODEL=/path/to/ggml-*.bin
#   tiny.en  (39MB)  fastest, lowest accuracy
#   base.en  (141MB) DEFAULT — best speed/accuracy balance, esp. important under Rosetta
#   small.en (465MB) more accurate, ~3x slower than base
#   medium.en(1.5GB) most accurate English-only, slow (parked as .park by default)
#   large-v3-turbo (1.6GB) DEFAULT when native build present — MULTILINGUAL.
#     The .en models cannot transcribe Hindi at all; turbo runs 14-18x realtime
#     with Metal at ~1-2%% WER above large-v3.
# Prefer the native arm64 + Metal build (vendor/whisper.cpp) — ~14x faster than the Rosetta
# x86_64 Homebrew binary on Apple Silicon (small.en: ~1s vs ~16s). Falls back to PATH whisper-server.
# Language: "auto" lets a multilingual model detect Hindi/English code-switching.
# Forcing "en" with a multilingual model silently discards non-English speech —
# that plus the English-only small.en model caused the 20-25%% Hindi loss
# measured on the 2026-08-09 capture. Override with WHISPER_LANG=en.
WHISPER_LANG="${WHISPER_LANG:-auto}"
NATIVE_WHISPER="$PROJECT/vendor/whisper.cpp/build/bin/whisper-server"
if [ -x "$NATIVE_WHISPER" ]; then WHISPER_BIN="$NATIVE_WHISPER"; else WHISPER_BIN="$(command -v whisper-server)"; fi

pick_whisper_model() {
    if [ -n "$WHISPER_MODEL" ] && [ -f "$WHISPER_MODEL" ]; then echo "$WHISPER_MODEL"; return; fi
    # With the native+Metal build, small.en (~1s) is the accuracy/speed sweet spot. Without it
    # (Rosetta), prefer base.en for speed. Order the preference accordingly.
    local order
    if [ -x "$NATIVE_WHISPER" ]; then order="large-v3-turbo small.en base.en medium.en tiny.en"; else order="base.en small.en tiny.en"; fi
    for m in $order; do
        [ -f "$PROJECT/models/ggml-$m.bin" ] && { echo "$PROJECT/models/ggml-$m.bin"; return; }
    done
}

start_whisper() {
    local model; model="$(pick_whisper_model)"
    if [ -z "$model" ]; then echo "[2/5] Whisper: no model found in $PROJECT/models/"; return; fi
    # Warn only if we're stuck on the slow Rosetta path (no native build present).
    if [ ! -x "$NATIVE_WHISPER" ] && sysctl -n machdep.cpu.brand_string 2>/dev/null | grep -q "Apple" \
       && file "$WHISPER_BIN" 2>/dev/null | grep -q "x86_64"; then
        echo "    WARNING: whisper-server is x86_64 (Rosetta) on Apple Silicon — transcription will be slow."
        echo "             Build the native arm64+Metal version for ~14x speedup. See docs/whisper-speed.md"
    fi
    echo "[2/5] Starting Whisper server ($(basename "$model"), $([ -x "$NATIVE_WHISPER" ] && echo 'native arm64+Metal' || echo 'system'))..."
    "$WHISPER_BIN" --model "$model" --host 127.0.0.1 --port 18386 --threads 4 \
        --language "$WHISPER_LANG" --no-timestamps &>/dev/null &
    # Native build JIT-compiles Metal shaders on first run (~20s), so allow up to 40s.
    for _ in $(seq 1 40); do curl -s -o /dev/null --max-time 2 http://localhost:18386/ && break; sleep 1; done
}

# Recycle guard: treat the server as healthy only if it answers a health ping within 3s.
# A server that holds the port but can't respond promptly is overloaded/hung (the "17-day stale,
# pegged at 380% CPU" case) — kill and restart it fresh rather than leaving it degraded.
if curl -s -o /dev/null --max-time 3 http://localhost:18386/ 2>/dev/null; then
    echo "[2/5] Whisper server: running (responsive)"
elif lsof -i :18386 &>/dev/null; then
    echo "[2/5] Whisper server: up but UNRESPONSIVE — recycling..."
    pkill -9 -f whisper-server 2>/dev/null; sleep 1
    start_whisper
else
    start_whisper
fi

# 3. Silero VAD service
if ! lsof -i :18384 &>/dev/null; then
    echo "[3/5] Starting Silero VAD service..."
    python3 "$PROJECT/src/services/vad_service.py" &>/dev/null &
    sleep 1
else
    echo "[3/5] VAD service: running"
fi

# 3. Embedding service
if ! curl -s http://localhost:18385/health &>/dev/null; then
    echo "[4/5] Starting Embedding service..."
    python3 "$PROJECT/src/services/embedding_service.py" &>/dev/null &
    sleep 2
else
    echo "[4/5] Embedding service: running"
fi

# 4. WhatsApp watcher (optional — only if folder exists)
WA_DIR="$HOME/Documents/OmniPilot/WhatsApp"
if [ -d "$WA_DIR" ] && ! pgrep -f "whatsapp_watcher.py" &>/dev/null; then
    echo "[5/5] Starting WhatsApp watcher ($WA_DIR)..."
    python3 "$PROJECT/src/services/whatsapp_watcher.py" &>/dev/null &
else
    if [ -d "$WA_DIR" ]; then
        echo "[5/5] WhatsApp watcher: running"
    else
        echo "[5/5] WhatsApp watcher: skipped (create $WA_DIR to enable)"
    fi
fi

# 5. Launch app
echo ""
echo "Launching OmniPilot..."
open "$APP"

echo ""
echo "OmniPilot is running!"
echo "  Left-click brain icon  = Open popover"
echo "  Right-click brain icon = Menu (listen toggle / quit)"
echo "  Cmd+Shift+O            = Open from anywhere"
echo ""
echo "Services:"
echo "  Ollama        : http://localhost:11434"
echo "  Silero VAD    : tcp://localhost:18384"
echo "  Embeddings    : http://localhost:18385"
echo "  WhatsApp      : $WA_DIR"
