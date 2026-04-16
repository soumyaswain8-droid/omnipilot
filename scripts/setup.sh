#!/bin/bash
# OmniPilot Setup Script
# Installs all dependencies for the Desktop Companion MVP

set -e

echo "=== OmniPilot Setup ==="
echo ""

# 1. Ollama
echo "1. Checking Ollama..."
if command -v ollama &>/dev/null; then
    echo "   Ollama installed: $(ollama --version)"
else
    echo "   Installing Ollama..."
    brew install ollama
fi

# Start Ollama if not running
if ! curl -s http://localhost:11434/api/tags &>/dev/null; then
    echo "   Starting Ollama server..."
    ollama serve &>/dev/null &
    sleep 3
fi

# Pull model
echo "   Pulling Qwen3 8B model (may take a while on first run)..."
ollama pull qwen3:8b

# 2. Whisper.cpp
echo ""
echo "2. Checking whisper.cpp..."
if command -v whisper-cpp &>/dev/null; then
    echo "   whisper.cpp installed"
else
    echo "   Installing whisper.cpp..."
    brew install whisper-cpp
fi

# Download model
MODELS_DIR="$(dirname "$0")/../models"
mkdir -p "$MODELS_DIR"
if [ -f "$MODELS_DIR/ggml-small.en.bin" ]; then
    echo "   Whisper small.en model present"
else
    echo "   Downloading whisper small.en model (466MB)..."
    curl -L -o "$MODELS_DIR/ggml-small.en.bin" \
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin"
fi

# 3. Python dependencies (for embeddings + VAD)
echo ""
echo "3. Checking Python dependencies..."
pip3 install --quiet onnxruntime numpy 2>/dev/null || echo "   pip3 install failed — install manually"

# 4. Verify
echo ""
echo "=== Verification ==="
echo "Ollama: $(curl -s http://localhost:11434/api/tags | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("models",[])), "models loaded")' 2>/dev/null || echo 'not running')"
echo "Whisper: $(which whisper-cpp 2>/dev/null || echo 'not found')"
echo "Model: $(ls -lh "$MODELS_DIR/ggml-small.en.bin" 2>/dev/null | awk '{print $5}' || echo 'not found')"
echo ""
echo "=== Setup Complete ==="
