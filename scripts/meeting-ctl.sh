#!/bin/bash
# meeting-ctl.sh — control + finalize a live meeting capture (audio, video, transcript, notes, OCR links).
#
#   meeting-ctl.sh status              # what's running + file sizes + latest notes/links
#   meeting-ctl.sh whisper start       # load the MULTILINGUAL model for meetings (port 18388)
#   meeting-ctl.sh whisper stop        # unload it (frees ~1.6 GB)
#   meeting-ctl.sh stop                # gracefully stop ALL recorders (finalizes audio + video)
#   meeting-ctl.sh finalize            # stop (if needed) + consolidate everything into the external folder
#
# Why a SECOND whisper server: port 18386 serves the live voice assistant and is
# tuned for latency (small.en, 0.98s/call, 91 MB). It is English-only, so it drops
# Hindi entirely. Meetings need large-v3-turbo, which costs 9.50s/call and 1642 MB
# on an M1 - fine at the 150s notes cadence, unusable for voice commands. Rather
# than compromise either, meetings get their own server on 18388, loaded only for
# the duration of the meeting so the 1.6 GB is not resident the rest of the time.
#
# Measured 2026-08-21 on M1/16GB, 30s of Hindi-English webinar audio:
#   small.en  --language en     6.3s ->  33 chars transcribed
#   turbo     --language auto  10.9s -> 481 chars transcribed
#
# Reads paths from the state file written at capture start: data/meetings/.active-meeting
set -uo pipefail

PROJ="$HOME/Documents/tinker/projects/omnipilot"
STATE="$PROJ/data/meetings/.active-meeting"
[ -f "$STATE" ] && . "$STATE"
: "${WAV:=}"; : "${BASE:=}"; : "${VIDEO_DIR:=}"; : "${VIDEO:=}"
FFPROBE="$(command -v ffprobe || echo "$HOME/anaconda3/bin/ffprobe")"

MEET_WHISPER_PORT="${MEET_WHISPER_PORT:-18388}"
MEET_WHISPER_MODEL="${MEET_WHISPER_MODEL:-$PROJ/models/ggml-large-v3-turbo.bin}"
WHISPER_BIN="$PROJ/vendor/whisper.cpp/build/bin/whisper-server"
[ -x "$WHISPER_BIN" ] || WHISPER_BIN="$(command -v whisper-server)"

whisper_up() { [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$1/" 2>/dev/null)" = 200 ]; }

whisper_start() {
  if whisper_up "$MEET_WHISPER_PORT"; then
    echo "meeting whisper already up on :$MEET_WHISPER_PORT"; return 0
  fi
  if [ ! -f "$MEET_WHISPER_MODEL" ]; then
    echo "FATAL: multilingual model missing: $MEET_WHISPER_MODEL"
    echo "  curl -L -o \"$MEET_WHISPER_MODEL\" \\"
    echo "    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
    return 1
  fi
  [ -x "$WHISPER_BIN" ] || { echo "FATAL: no whisper-server binary"; return 1; }
  echo "Loading $(basename "$MEET_WHISPER_MODEL") on :$MEET_WHISPER_PORT (~1.6 GB, multilingual)..."
  "$WHISPER_BIN" --model "$MEET_WHISPER_MODEL" --host 127.0.0.1 --port "$MEET_WHISPER_PORT" \
      --threads 4 --language auto --no-timestamps &>/dev/null &
  for _ in $(seq 1 90); do whisper_up "$MEET_WHISPER_PORT" && { echo "  up."; return 0; }; sleep 1; done
  echo "  TIMEOUT: server did not come up in 90s"; return 1
}

whisper_stop() {
  pkill -f "port $MEET_WHISPER_PORT" 2>/dev/null && echo "meeting whisper stopped (freed ~1.6 GB)" \
    || echo "meeting whisper not running"
}

hsize() { du -h "$1" 2>/dev/null | cut -f1; }

status() {
  echo "== Meeting capture status =="
  echo "audio recorder : $(pgrep -f 'ffmpeg.* -f avfoundation -i :0' >/dev/null && echo RUNNING || echo stopped)   $(hsize "$WAV") $WAV"
  echo "video recorder : $(pgrep -f 'h264_videotoolbox' >/dev/null && echo RUNNING || echo stopped)   $(hsize "$VIDEO") $VIDEO"
  echo "voice whisper  : $(whisper_up 18386 && echo 'UP :18386 (small.en, latency)' || echo down)"
  echo "meeting whisper: $(whisper_up "$MEET_WHISPER_PORT" && echo "UP :$MEET_WHISPER_PORT (multilingual)" || echo 'down  <-- Hindi will be lost')"
  echo "notes loop     : $(pgrep -f 'meeting-notes.sh' >/dev/null && echo RUNNING || echo stopped)"
  echo "ocr loop       : $(pgrep -f 'meeting-screen.sh' >/dev/null && echo RUNNING || echo stopped)"
  echo "audio duration : $("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$WAV" 2>/dev/null)s"
  echo "latest notes   : $(grep -m1 updated "${BASE}.notes.md" 2>/dev/null)"
  echo "links captured : $(grep -c '^- ' "${BASE}.links.md" 2>/dev/null) urls"
}

stop() {
  echo "Stopping recorders gracefully..."
  # SIGINT the two ffmpeg recorders so they finalize their containers cleanly
  pkill -INT -f 'ffmpeg.* -f avfoundation -i :0' 2>/dev/null   # audio
  pkill -INT -f 'h264_videotoolbox' 2>/dev/null                # video
  # loops + server
  pkill -f 'meeting-notes.sh'  2>/dev/null
  pkill -f 'meeting-screen.sh' 2>/dev/null
  pkill -f 'meeting-video.sh'  2>/dev/null
  sleep 3
  # Only unload the MEETING server. The one on 18386 serves the live voice
  # assistant and must survive. (The old pattern 'whisper-server -m' matched
  # nothing at all - run.sh uses --model - so stop never killed anything and
  # left a server running for 23 days.)
  whisper_stop
  echo "Stopped."
}

finalize() {
  local DEST="${1:-$VIDEO_DIR}"
  [ -z "$DEST" ] && { echo "No destination known"; exit 1; }
  mkdir -p "$DEST"
  # ensure recorders are stopped so files are complete
  pgrep -f 'ffmpeg.* -f avfoundation -i :0' >/dev/null && stop
  echo "Consolidating meeting artifacts into: $DEST"
  # move the internal-side artifacts (audio + text) alongside the video already on the external disk
  for f in "$WAV" "${BASE}.transcript.md" "${BASE}.notes.md" "${BASE}.links.md" "${BASE}.screen-text.txt"; do
    [ -f "$f" ] && mv -f "$f" "$DEST/" && echo "  moved $(basename "$f")"
  done
  echo "Done. Folder contents:"
  ls -la "$DEST"
}

case "${1:-status}" in
  status)   status ;;
  stop)     stop ;;
  finalize) finalize "${2:-}" ;;
  whisper)
    case "${2:-}" in
      start) whisper_start ;;
      stop)  whisper_stop ;;
      *) echo "usage: meeting-ctl.sh whisper [start|stop]"; exit 1 ;;
    esac ;;
  *) echo "usage: meeting-ctl.sh [status|stop|finalize [dest]|whisper start|whisper stop]"; exit 1 ;;
esac
