#!/bin/bash
# Launch OmniPilot
# Usage: ./scripts/run.sh

set -e

APP="$(dirname "$0")/../build/OmniPilot.app"
OLLAMA_URL="http://localhost:11434/api/tags"

# 1. Ensure Ollama is running
if ! curl -s "$OLLAMA_URL" &>/dev/null; then
    echo "Starting Ollama..."
    ollama serve &>/dev/null &
    sleep 2
fi

# 2. Verify model is available
if ! ollama list 2>/dev/null | grep -q "llama3.2"; then
    echo "Pulling llama3.2:3b model (first time only)..."
    ollama pull llama3.2:3b
fi

# 3. Launch OmniPilot
echo "Launching OmniPilot..."
echo "  - Brain icon will appear in your menu bar"
echo "  - Press Cmd+Shift+O to query memories"
echo "  - Right-click the icon for options"
echo ""
open "$APP"
