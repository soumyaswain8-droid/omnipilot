# OmniPilot - Personal AI Assistant

## Project Overview
Voice-first, local-first personal AI companion. Omi alternative integrated with Sidewall product portfolio (BizBot, AdPilot, QuickBillPro, TradePilot, DevPilot, SetlIn, DesignPilot).

## Tech Stack
- **macOS App**: Swift, SwiftUI, CoreAudio, AVAudioEngine
- **STT**: whisper.cpp with CoreML backend (small.en model)
- **LLM**: Ollama + Qwen3 8B Q4 (local, localhost:11434)
- **VAD**: Silero VAD (ONNX, 0.4% CPU)
- **Memory DB**: SQLite + sqlite-vec (384-dim vectors) + FTS5
- **Embeddings**: all-MiniLM-L6-v2 (ONNX, 384-dim)
- **Mobile (Phase 3)**: Flutter + whisper_flutter_new
- **Sync**: Local HTTP API over LAN (no cloud)

## Project Structure
```
src/
  macos/          # Swift menu bar app (Phase 1)
  shared/         # Shared logic (memory, search, LLM client)
  flutter/        # Mobile app (Phase 3)
docs/
  research/       # Market research, MindPilot plan, competitor analysis
  charts/         # Matplotlib/diagram PNGs
scripts/          # Setup scripts, utilities
config/           # App configuration templates
```

## Key Design Decisions
- **Local-first**: All processing on-device. No data leaves Mac/phone
- **SQLite single file**: Memory DB is one file, trivially syncable
- **Whisper small.en**: Best accuracy/speed tradeoff (466MB, 200ms/chunk on M1)
- **Qwen3 8B Q4**: Fastest quality LLM in 5GB RAM
- **Hybrid search**: FTS5 keyword + sqlite-vec cosine similarity + RRF fusion

## DevPilot Integration
- Project ID: `omnipilot`
- Sprint 1: `OMNI-S1` (Desktop Companion MVP)
- Tasks: `OMNI-001` through `OMNI-011`

## Build Commands
```bash
# Setup (first time)
./scripts/setup.sh

# Build macOS app
cd src/macos && swift build

# Run Ollama
ollama serve  # then: ollama run qwen3:8b
```

## Privacy Promise
Zero cloud dependency. Audio, transcripts, and memories never leave the device. Pluggable AI provider for optional cloud upgrade.
