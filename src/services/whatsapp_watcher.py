#!/usr/bin/env python3
"""
OmniPilot WhatsApp Voice Note Watcher
Watches a folder for new audio files (voice notes exported from WhatsApp),
transcribes them with Whisper, and stores in OmniPilot memory.

Usage:
  python3 whatsapp_watcher.py [watch_folder]

Default watch folder: ~/Documents/OmniPilot/WhatsApp/
Drop .opus, .ogg, .m4a, .mp3, .wav files into the folder to process them.
"""

import os
import sys
import time
import json
import sqlite3
import subprocess
import signal
from pathlib import Path
from datetime import datetime

WATCH_DIR = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/Documents/OmniPilot/WhatsApp")
WHISPER_CLI = "/usr/local/bin/whisper-cli"
MODEL_PATH = os.path.expanduser("~/Documents/tinker/projects/omnipilot/models/ggml-small.en.bin")
DB_PATH = os.path.expanduser("~/Library/Application Support/OmniPilot/memory.sqlite")
PROCESSED_DIR = os.path.join(WATCH_DIR, "processed")
EMBED_URL = "http://127.0.0.1:18385"

AUDIO_EXTENSIONS = {'.opus', '.ogg', '.m4a', '.mp3', '.wav', '.aac', '.wma'}


def setup():
    """Create directories if needed."""
    os.makedirs(WATCH_DIR, exist_ok=True)
    os.makedirs(PROCESSED_DIR, exist_ok=True)
    print(f"[WhatsApp] Watching: {WATCH_DIR}")
    print(f"[WhatsApp] Processed files moved to: {PROCESSED_DIR}")


def convert_to_wav(input_path: str) -> str:
    """Convert any audio to 16kHz mono WAV using ffmpeg."""
    output_path = input_path + ".wav"

    # Try ffmpeg first, fall back to afconvert (macOS built-in)
    try:
        subprocess.run([
            "ffmpeg", "-y", "-i", input_path,
            "-ar", "16000", "-ac", "1", "-f", "wav", output_path
        ], capture_output=True, timeout=30)
        if os.path.exists(output_path):
            return output_path
    except FileNotFoundError:
        pass

    # macOS fallback
    try:
        subprocess.run([
            "afconvert", "-f", "WAVE", "-d", "LEI16@16000",
            "-c", "1", input_path, output_path
        ], capture_output=True, timeout=30)
        if os.path.exists(output_path):
            return output_path
    except FileNotFoundError:
        pass

    print(f"[WhatsApp] Cannot convert {input_path} — install ffmpeg: brew install ffmpeg")
    return None


def transcribe(wav_path: str) -> str:
    """Transcribe WAV file using whisper-cli."""
    result = subprocess.run([
        WHISPER_CLI, "-m", MODEL_PATH,
        "-f", wav_path, "--no-timestamps", "-l", "en"
    ], capture_output=True, text=True, timeout=120)

    # Extract transcription from stdout
    text = result.stdout.strip()
    # Remove whisper timing info lines
    lines = [l.strip() for l in text.split('\n') if l.strip() and not l.startswith('whisper_')]
    return ' '.join(lines)


def store_memory(text: str, source_file: str):
    """Store transcription in OmniPilot memory DB."""
    try:
        conn = sqlite3.connect(DB_PATH)
        cursor = conn.execute(
            """INSERT INTO memories (content, timestamp, source, type, participants, topics, importance_score)
               VALUES (?, ?, 'whatsapp', 'voice_note', NULL, NULL, 0.7)""",
            (text, datetime.now().isoformat())
        )
        memory_id = cursor.lastrowid

        # Update FTS index
        conn.execute(
            """INSERT INTO memories_fts(rowid, content, summary, participants, topics)
               VALUES (?, ?, NULL, '', '')""",
            (memory_id, text)
        )
        conn.commit()

        # Try to generate embedding via embedding service
        try:
            import urllib.request
            req = urllib.request.Request(
                f"{EMBED_URL}/embed_and_store",
                data=json.dumps({
                    'text': text,
                    'memory_id': memory_id,
                    'db_path': DB_PATH
                }).encode(),
                headers={'Content-Type': 'application/json'}
            )
            urllib.request.urlopen(req, timeout=5)
        except Exception:
            pass  # Embedding service may not be running

        conn.close()
        print(f"[WhatsApp] Stored memory #{memory_id}: {text[:60]}...")
        return memory_id
    except Exception as e:
        print(f"[WhatsApp] DB error: {e}")
        return None


def process_file(filepath: str):
    """Process a single audio file."""
    filename = os.path.basename(filepath)
    print(f"\n[WhatsApp] Processing: {filename}")

    # Convert to WAV if needed
    if filepath.endswith('.wav'):
        wav_path = filepath
        cleanup_wav = False
    else:
        wav_path = convert_to_wav(filepath)
        cleanup_wav = True
        if not wav_path:
            return

    # Transcribe
    text = transcribe(wav_path)

    # Cleanup temp WAV
    if cleanup_wav and wav_path and os.path.exists(wav_path):
        os.remove(wav_path)

    if not text or len(text.strip()) < 3:
        print(f"[WhatsApp] Empty transcription, skipping")
        return

    # Store in memory
    store_memory(text, filename)

    # Move processed file
    dest = os.path.join(PROCESSED_DIR, filename)
    os.rename(filepath, dest)
    print(f"[WhatsApp] Done. Moved to processed/")


def watch_loop():
    """Poll watch directory for new files."""
    seen = set()

    while True:
        try:
            for f in os.listdir(WATCH_DIR):
                filepath = os.path.join(WATCH_DIR, f)
                if not os.path.isfile(filepath):
                    continue

                ext = os.path.splitext(f)[1].lower()
                if ext not in AUDIO_EXTENSIONS:
                    continue

                if filepath in seen:
                    continue

                # Wait for file to finish writing
                size1 = os.path.getsize(filepath)
                time.sleep(1)
                if os.path.exists(filepath) and os.path.getsize(filepath) == size1:
                    seen.add(filepath)
                    process_file(filepath)

            time.sleep(2)

        except KeyboardInterrupt:
            break
        except Exception as e:
            print(f"[WhatsApp] Error: {e}")
            time.sleep(5)


def main():
    setup()
    signal.signal(signal.SIGINT, lambda s, f: sys.exit(0))
    signal.signal(signal.SIGTERM, lambda s, f: sys.exit(0))

    if not os.path.exists(WHISPER_CLI):
        print(f"[WhatsApp] whisper-cli not found at {WHISPER_CLI}")
        sys.exit(1)

    if not os.path.exists(MODEL_PATH):
        print(f"[WhatsApp] Whisper model not found at {MODEL_PATH}")
        sys.exit(1)

    print(f"[WhatsApp] Ready. Drop voice notes into: {WATCH_DIR}")
    watch_loop()


if __name__ == '__main__':
    main()
