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
  echo "audio recorder : $(pgrep -f 'ffmpeg.* -f avfoundation -i :' >/dev/null && echo RUNNING || echo stopped)   $(hsize "$WAV") $WAV"
  echo "video recorder : $(pgrep -f 'h264_videotoolbox' >/dev/null && echo RUNNING || echo stopped)   $(hsize "$VIDEO") $VIDEO"
  echo "voice whisper  : $(whisper_up 18386 && echo 'UP :18386 (small.en, latency)' || echo down)"
  echo "meeting whisper: $(whisper_up "$MEET_WHISPER_PORT" && echo "UP :$MEET_WHISPER_PORT (multilingual)" || echo 'down  <-- Hindi will be lost')"
  echo "notes loop     : $(pgrep -f 'meeting-notes.sh' >/dev/null && echo RUNNING || echo stopped)"
  echo "ocr loop       : $(pgrep -f 'meeting-screen.sh' >/dev/null && echo RUNNING || echo stopped)"
  echo "audio duration : $("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$WAV" 2>/dev/null)s"
  echo "latest notes   : $(grep -m1 updated "${BASE}.notes.md" 2>/dev/null)"
  echo "links captured : $(grep -c '^- ' "${BASE}.links.md" 2>/dev/null) urls"
}

# Escalating kill. ffmpeg holding an avfoundation device routinely ignores BOTH
# SIGINT and SIGTERM - it blocks in a device read that never returns, so the signal
# handler never runs. The old version fired one SIGINT, slept 3s and printed
# "Stopped." unconditionally, which was simply false: recorders survived every stop
# and the caller had no way to know. Escalate, then VERIFY, then report honestly.
kill_tree() {
  local pat="$1" label="$2" sig
  pgrep -f "$pat" >/dev/null 2>&1 || return 0
  for sig in INT INT TERM KILL; do
    pkill -"$sig" -f "$pat" 2>/dev/null
    sleep 2
    if ! pgrep -f "$pat" >/dev/null 2>&1; then
      if [ "$sig" = KILL ]; then echo "  $label: stopped (SIGKILL - container may need repair)"
      else echo "  $label: stopped (SIG$sig)"; fi
      return 0
    fi
  done
  echo "  $label: STILL RUNNING after SIGKILL - pids: $(pgrep -f "$pat" | tr '\n' ' ')"
  return 1
}

# A container closed by SIGKILL keeps a zero/short RIFF length field, so ffprobe
# reports N/A and players show 0s. Remux copies the stream into a correct header.
repair_wav() {
  local w="$1" d ff
  [ -f "$w" ] || return 0
  d="$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$w" 2>/dev/null | cut -d. -f1)"
  case "$d" in ''|*[!0-9]*)
    ff="$(command -v ffmpeg || echo "$HOME/anaconda3/bin/ffmpeg")"
    echo "  repairing truncated header: $(basename "$w")"
    "$ff" -nostdin -v error -i "$w" -c copy -y "${w}.fixed" 2>/dev/null \
      && mv -f "${w}.fixed" "$w" \
      && echo "    -> $("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$w" | cut -d. -f1)s"
    ;;
  esac
}

stop() {
  local rc=0
  echo "Stopping recorders..."
  # Match ANY device index, not just :0 - the old ':0' pattern missed every recorder
  # started on another device (AirPods often enumerate ahead of the built-in mic,
  # shifting the internal mic to :1).
  kill_tree 'ffmpeg.* -f avfoundation -i :' 'audio recorder' || rc=1
  kill_tree 'h264_videotoolbox'              'video recorder' || rc=1
  kill_tree 'meeting-notes.sh'               'notes loop'     || rc=1
  kill_tree 'meeting-screen.sh'              'ocr loop'       || rc=1
  kill_tree 'meeting-video.sh'               'video loop'     || rc=1

  [ -n "$WAV" ] && repair_wav "$WAV"

  # Only unload the MEETING server. The one on 18386 serves the live voice
  # assistant and must survive.
  whisper_stop

  if [ "$rc" = 0 ]; then echo "Stopped."; else echo "STOP INCOMPLETE - see above."; fi
  return "$rc"
}

finalize() {
  local DEST="${1:-$VIDEO_DIR}"
  [ -z "$DEST" ] && { echo "No destination known"; exit 1; }
  mkdir -p "$DEST"
  # ensure recorders are stopped so files are complete
  pgrep -f 'ffmpeg.* -f avfoundation -i :' >/dev/null && stop
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
