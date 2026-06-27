#!/bin/bash
# OmniPilot Whisper Server — persistent transcription service
# Loads the model ONCE and serves via HTTP on port 18386
# This is 10-50x faster than calling whisper-cli per chunk

MODEL="${1:-$(dirname "$0")/../../models/ggml-small.en.bin}"
PORT=18386
HOST=127.0.0.1

if [ ! -f "$MODEL" ]; then
    echo "[Whisper] Model not found: $MODEL"
    exit 1
fi

echo "[Whisper] Starting server with model: $(basename "$MODEL")"
echo "[Whisper] Listening on $HOST:$PORT"

exec whisper-server \
    --model "$MODEL" \
    --host "$HOST" \
    --port "$PORT" \
    --threads 4 \
    --language en \
    --no-timestamps \
    2>&1
