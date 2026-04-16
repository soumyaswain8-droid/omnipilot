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

# 2. Silero VAD service
if ! lsof -i :18384 &>/dev/null; then
    echo "[2/4] Starting Silero VAD service..."
    python3 "$PROJECT/src/services/vad_service.py" &>/dev/null &
    sleep 1
else
    echo "[2/4] VAD service: running"
fi

# 3. Embedding service
if ! curl -s http://localhost:18385/health &>/dev/null; then
    echo "[3/4] Starting Embedding service..."
    python3 "$PROJECT/src/services/embedding_service.py" &>/dev/null &
    sleep 2
else
    echo "[3/4] Embedding service: running"
fi

# 4. WhatsApp watcher (optional — only if folder exists)
WA_DIR="$HOME/Documents/OmniPilot/WhatsApp"
if [ -d "$WA_DIR" ] && ! pgrep -f "whatsapp_watcher.py" &>/dev/null; then
    echo "[4/4] Starting WhatsApp watcher ($WA_DIR)..."
    python3 "$PROJECT/src/services/whatsapp_watcher.py" &>/dev/null &
else
    if [ -d "$WA_DIR" ]; then
        echo "[4/4] WhatsApp watcher: running"
    else
        echo "[4/4] WhatsApp watcher: skipped (create $WA_DIR to enable)"
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
