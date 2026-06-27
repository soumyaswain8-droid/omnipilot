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
#   medium.en(1.5GB) most accurate, slow (parked as .park by default)
pick_whisper_model() {
    if [ -n "$WHISPER_MODEL" ] && [ -f "$WHISPER_MODEL" ]; then echo "$WHISPER_MODEL"; return; fi
    for m in base.en small.en medium.en tiny.en; do
        [ -f "$PROJECT/models/ggml-$m.bin" ] && { echo "$PROJECT/models/ggml-$m.bin"; return; }
    done
}

start_whisper() {
    local model; model="$(pick_whisper_model)"
    if [ -z "$model" ]; then echo "[2/5] Whisper: no model found in $PROJECT/models/"; return; fi
    # Warn if running emulated x86_64 on Apple Silicon (the usual cause of slow transcription).
    if sysctl -n machdep.cpu.brand_string 2>/dev/null | grep -q "Apple" \
       && file "$(command -v whisper-server)" 2>/dev/null | grep -q "x86_64"; then
        echo "    WARNING: whisper-server is x86_64 (Rosetta) on Apple Silicon — transcription will be slow."
        echo "             For a ~10x speedup install native arm64 whisper.cpp (Metal). See docs/whisper-speed.md"
    fi
    echo "[2/5] Starting Whisper server ($(basename "$model"))..."
    whisper-server --model "$model" --host 127.0.0.1 --port 18386 --threads 4 \
        --language en --no-timestamps &>/dev/null &
    # Wait for model load (up to ~30s) instead of a blind sleep.
    for _ in $(seq 1 30); do curl -s -o /dev/null --max-time 2 http://localhost:18386/ && break; sleep 1; done
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
