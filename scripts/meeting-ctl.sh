#!/bin/bash
# meeting-ctl.sh — control + finalize a live meeting capture (audio, video, transcript, notes, OCR links).
#
#   meeting-ctl.sh status              # what's running + file sizes + latest notes/links
#   meeting-ctl.sh stop                # gracefully stop ALL recorders (finalizes audio + video)
#   meeting-ctl.sh finalize            # stop (if needed) + consolidate everything into the external folder
#
# Reads paths from the state file written at capture start: data/meetings/.active-meeting
set -uo pipefail

PROJ="$HOME/Documents/tinker/projects/omnipilot"
STATE="$PROJ/data/meetings/.active-meeting"
[ -f "$STATE" ] && . "$STATE"
: "${WAV:=}"; : "${BASE:=}"; : "${VIDEO_DIR:=}"; : "${VIDEO:=}"
FFPROBE="$(command -v ffprobe || echo "$HOME/anaconda3/bin/ffprobe")"

hsize() { du -h "$1" 2>/dev/null | cut -f1; }

status() {
  echo "== Meeting capture status =="
  echo "audio recorder : $(pgrep -f 'ffmpeg.* -f avfoundation -i :0' >/dev/null && echo RUNNING || echo stopped)   $(hsize "$WAV") $WAV"
  echo "video recorder : $(pgrep -f 'h264_videotoolbox' >/dev/null && echo RUNNING || echo stopped)   $(hsize "$VIDEO") $VIDEO"
  echo "whisper-server : $([ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18386/ 2>/dev/null)" = 200 ] && echo UP || echo down)"
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
  pkill -f 'whisper-server -m' 2>/dev/null
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
  *) echo "usage: meeting-ctl.sh [status|stop|finalize [dest]]"; exit 1 ;;
esac
