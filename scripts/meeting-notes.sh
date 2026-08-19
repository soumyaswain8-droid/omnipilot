#!/bin/bash
# meeting-notes.sh — rolling transcription + notes for a live meeting recording.
#
# Watches a growing WAV, transcribes only the NEW window each cycle via the
# persistent whisper-server (/inference), appends to a running transcript, and
# regenerates structured notes with Ollama (qwen3:8b). Everything is local.
#
# Usage: meeting-notes.sh <recording.wav> [interval_seconds]
set -uo pipefail

WAV="${1:?usage: meeting-notes.sh <recording.wav> [interval_seconds]}"
INTERVAL="${2:-150}"
MIN_WINDOW=25                       # seconds of new audio before we transcribe

FFMPEG="$(command -v ffmpeg || echo "$HOME/development/bin/ffmpeg")"
FFPROBE="$(command -v ffprobe || echo "$HOME/anaconda3/bin/ffprobe")"
WHISPER_URL="http://127.0.0.1:18386/inference"
OLLAMA_URL="http://localhost:11434/api/generate"
OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.2:3b}"   # fast, no reasoning trace; qwen3:8b is too slow for a loop

BASE="${WAV%.wav}"
TRANSCRIPT="${BASE}.transcript.md"
NOTES="${BASE}.notes.md"
OFFSET_FILE="${BASE}.offset"
TMPDIR_M="$(dirname "$WAV")/.tmp"
mkdir -p "$TMPDIR_M"

offset="$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)"
[ -f "$TRANSCRIPT" ] || printf '# Meeting Transcript\n\n_Recording: `%s`_\n\n' "$(basename "$WAV")" > "$TRANSCRIPT"

log() { echo "[$(date +%H:%M:%S)] $*"; }

regen_notes() {
  # Feed the full running transcript to the local LLM -> structured notes.
  local transcript_text prompt payload links_text screen_text
  # Strip timestamps, then normalize known whisper mishears (deterministic, reliable) so the
  # small LLM sees correct product names. Raw transcript.md is left untouched as ground truth.
  transcript_text="$(sed -E \
      -e 's/^\*\*\[[0-9:]*\]\*\*//' \
      -e 's/[Nn][ ]?urbukh[ ]*alum/NotebookLM/g' \
      -e 's/[Nn][ ]?urbukkalem/NotebookLM/g' \
      "$TRANSCRIPT" | tr -d '\r')"

  # Screen OCR context (if the screen-capture job is running): exact URLs + on-screen text.
  links_text="$(grep -E '^- ' "${BASE}.links.md" 2>/dev/null | sed -E 's/  _\(first seen.*\)_//' | sort -u)"
  screen_text="$(tail -150 "${BASE}.screen-text.txt" 2>/dev/null)"
  prompt="You are a meeting notetaker. Below is the running transcript of a live meeting/session (auto-transcribed, so expect minor errors and mis-heard names — correct obvious ones from context). When a term is phonetically close to a well-known product or company, use the correct name (e.g. 'Nurbukkalem'/'Nurbukh alum' means 'NotebookLM'). Produce clean, re-readable notes in Markdown with these sections, omitting any that have no content:

## TL;DR
2-3 sentence summary of what this session is about.

## Key Points
Bulleted, grouped by topic.

## Tools / Resources Mentioned
Name — what it does — any link/how-to mentioned.

## Links & Resources
Exact URLs (use the ON-SCREEN LINKS list verbatim) and what each is for.

## Step-by-step / How-to
Numbered tutorial steps demonstrated, per tool (from the narration + on-screen actions).

## Decisions
## Action Items
- [ ] owner (if stated) — task

## Open Questions

Be concise and factual. Do not invent details not present in the sources below.

TRANSCRIPT:
$transcript_text

ON-SCREEN LINKS (exact, captured via OCR — use these verbatim in the Links section):
$links_text

ON-SCREEN TEXT SNIPPETS (OCR of the shared screen; noisy — use only to confirm tool names, exact URLs, and the UI steps shown):
$screen_text"

  payload="$(python3 -c 'import json,sys; print(json.dumps({"model":sys.argv[1],"prompt":sys.argv[2],"stream":False,"think":False,"options":{"temperature":0.2,"num_ctx":16384}}))' "$OLLAMA_MODEL" "$prompt")"

  local resp notes_body
  resp="$(curl -s "$OLLAMA_URL" -d "$payload" 2>/dev/null)"
  notes_body="$(printf '%s' "$resp" | python3 -c 'import json,sys,re
try:
    r=json.load(sys.stdin).get("response","")
except Exception:
    r=""
r=re.sub(r"<think>.*?</think>","",r,flags=re.S).strip()
print(r)' 2>/dev/null)"

  if [ -n "$notes_body" ]; then
    {
      printf '# Meeting Notes\n\n'
      printf '_Live notes — recording `%s` — updated %s_\n\n' "$(basename "$WAV")" "$(date '+%Y-%m-%d %H:%M:%S')"
      printf '%s\n' "$notes_body"
    } > "$NOTES"
    log "notes updated -> $NOTES"
  fi
}

log "rolling notes started (interval ${INTERVAL}s, min window ${MIN_WINDOW}s)"
log "transcript: $TRANSCRIPT"
log "notes:      $NOTES"

while true; do
  dur="$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$WAV" 2>/dev/null | cut -d. -f1)"
  dur="${dur:-0}"
  new=$(( dur - offset ))

  if [ "$new" -ge "$MIN_WINDOW" ]; then
    chunk="$TMPDIR_M/chunk_${offset}_${dur}.wav"
    if "$FFMPEG" -nostdin -hide_banner -loglevel error -ss "$offset" -i "$WAV" -ar 16000 -ac 1 -t "$new" -y "$chunk" 2>/dev/null; then
      text="$(curl -s "$WHISPER_URL" -F file=@"$chunk" -F response_format=text 2>/dev/null \
              | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')"
      rm -f "$chunk"
      if [ -n "$text" ] && [ "$text" != " " ]; then
        printf '**[%s]** %s\n\n' "$(printf '%02d:%02d' $((offset/60)) $((offset%60)))" "$text" >> "$TRANSCRIPT"
        offset="$dur"; echo "$offset" > "$OFFSET_FILE"
        log "transcribed window -> +${new}s (total ${dur}s)"
        # LLM notes are expensive (re-summarize whole transcript) and starve the GPU while
        # video encoding runs. Skip during capture (NOTES_LLM=0); generate once at meeting end.
        if [ "${NOTES_LLM:-1}" = "1" ]; then regen_notes; fi
      fi
    fi
  else
    log "waiting (only ${new}s new audio)"
  fi
  sleep "$INTERVAL"
done
