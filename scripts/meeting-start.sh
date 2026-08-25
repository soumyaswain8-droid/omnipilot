#!/bin/bash
# meeting-start.sh — start a live meeting capture (audio + rolling notes + screen OCR).
#
# The piece meeting-ctl.sh never had. Does the pre-flight the 2026-08-19 state
# report asked for, so the silent-AirPods trap cannot repeat unnoticed:
#   - waits for the requested audio device to actually exist in avfoundation
#   - records which device is being captured into the state file
#   - stamps a MIC-ONLY warning into notes.md when remote audio is not captured
#
# Usage: meeting-start.sh <label> [device-name-substring] [wait_seconds]
set -uo pipefail

PROJ="$HOME/Documents/tinker/projects/omnipilot"
DIR="$PROJ/data/meetings"
LABEL="${1:?usage: meeting-start.sh <label> [device-substring] [wait_seconds]}"
WANT="${2:-MacBook Pro Microphone}"
WAITS="${3:-120}"

export PATH="$HOME/anaconda3/bin:$PATH"
FFMPEG="$(command -v ffmpeg)"

dev_index() {
  "$FFMPEG" -f avfoundation -list_devices true -i "" 2>&1 \
    | awk '/AVFoundation audio devices/{a=1;next} a && /^\[AVFoundation/ {print}' \
    | sed -n "s/.*\[\([0-9][0-9]*\)\] \(.*\)/\1|\2/p" \
    | grep -i -- "|.*$1" | head -1 | cut -d'|' -f1
}

echo "Waiting up to ${WAITS}s for audio device matching: $WANT"
IDX=""
for _ in $(seq 1 "$WAITS"); do
  IDX="$(dev_index "$WANT")"
  [ -n "$IDX" ] && break
  sleep 1
done
[ -z "$IDX" ] && { echo "FATAL: no audio device matching '$WANT' appeared in ${WAITS}s."; exit 1; }

DEVNAME="$("$FFMPEG" -f avfoundation -list_devices true -i "" 2>&1 | sed -n "s/.*\[$IDX\] \(.*\)/\1/p" | tail -1)"
echo "Capturing audio device [$IDX] $DEVNAME"

TS="$(date +%Y-%m-%d_%H-%M-%S)"
BASE="$DIR/${LABEL}_${TS}"
WAV="${BASE}.wav"
OUT="${BASE}_out"
mkdir -p "$OUT"

cat > "$DIR/.active-meeting" <<STATE
WAV="$WAV"
BASE="$BASE"
VIDEO_DIR="$OUT"
VIDEO=""
AUDIO_DEVICE="[$IDX] $DEVNAME"
STARTED="$(date -Iseconds)"
STATE

# 16 kHz mono — what whisper.cpp wants, no resample step in the notes loop.
nohup "$FFMPEG" -nostdin -f avfoundation -i ":$IDX" -ac 1 -ar 16000 -y "$WAV" \
  >"${BASE}.ffmpeg.log" 2>&1 &
sleep 3
pgrep -f "avfoundation -i :$IDX" >/dev/null || { echo "FATAL: recorder died. Log:"; tail -20 "${BASE}.ffmpeg.log"; exit 1; }

nohup "$PROJ/scripts/meeting-notes.sh"  "$WAV"  150 >"${BASE}.notes-loop.log" 2>&1 &
nohup "$PROJ/scripts/meeting-screen.sh" "$BASE"  25 >"${BASE}.ocr-loop.log"   2>&1 &

echo "Recording  : $WAV"
echo "Notes      : ${BASE}.notes.md"
echo "Links (OCR): ${BASE}.links.md"
echo "Stop with  : $PROJ/scripts/meeting-ctl.sh stop"
