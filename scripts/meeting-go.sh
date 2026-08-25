#!/bin/bash
# meeting-go.sh — one command to start a clean meeting capture when the meeting
# ACTUALLY starts. Stops any warm-up recorders, starts fresh, and verifies signal
# instead of assuming it.
#
#   meeting-go.sh <label> [device-substring]
#
# Records BOTH the call device and the MacBook mic when they differ. Bluetooth HFP
# is a mono single-consumer link: when a call app holds the AirPods mic, a second
# tap can return noise floor while every health check still reports "healthy".
# The MacBook mic costs nothing and is immune to that, so it runs as a control.
set -uo pipefail

PROJ="$HOME/Documents/tinker/projects/omnipilot"
DIR="$PROJ/data/meetings"
LABEL="${1:?usage: meeting-go.sh <label> [device-substring]}"
WANT="${2:-AirPods}"
export PATH="$HOME/anaconda3/bin:$PATH"
FFMPEG="$(command -v ffmpeg)"

idx_of() {
  "$FFMPEG" -f avfoundation -list_devices true -i "" 2>&1 \
    | awk '/AVFoundation audio devices/{a=1;next} a && /^\[AVFoundation/ {print}' \
    | sed -n "s/.*\[\([0-9][0-9]*\)\] \(.*\)/\1|\2/p" | grep -i -- "|.*$1" | head -1
}

echo "Stopping any warm-up recorders..."
pkill -INT -f 'avfoundation -i :' 2>/dev/null
pkill -f 'meeting-notes.sh' 2>/dev/null
pkill -f 'meeting-screen.sh' 2>/dev/null
sleep 2

PRI="$(idx_of "$WANT")"
[ -z "$PRI" ] && { echo "FATAL: no audio device matching '$WANT'"; exit 1; }
PI="${PRI%%|*}"; PN="${PRI#*|}"
MBP="$(idx_of 'MacBook Pro Microphone')"; MI="${MBP%%|*}"

TS="$(date +%Y-%m-%d_%H-%M-%S)"
BASE="$DIR/${LABEL}_${TS}"; WAV="$BASE.wav"; mkdir -p "${BASE}_out"

cat > "$DIR/.active-meeting" <<STATE
WAV="$WAV"
BASE="$BASE"
VIDEO_DIR="${BASE}_out"
VIDEO=""
AUDIO_DEVICE="[$PI] $PN"
STARTED="$(date -Iseconds)"
STATE

nohup "$FFMPEG" -nostdin -f avfoundation -i ":$PI" -ac 1 -ar 16000 -y "$WAV" >"$BASE.ffmpeg.log" 2>&1 &
echo "primary  : [$PI] $PN -> $(basename "$WAV")"
if [ -n "$MI" ] && [ "$MI" != "$PI" ]; then
  nohup "$FFMPEG" -nostdin -f avfoundation -i ":$MI" -ac 1 -ar 16000 -y "$BASE.macmic.wav" >"$BASE.macmic.log" 2>&1 &
  echo "control  : [$MI] MacBook Pro Microphone -> $(basename "$BASE.macmic.wav")"
fi

# NOTES_LLM=0 — build the transcript live, but never let the LLM summarise during
# capture. It reads screen OCR as context, and OCR grabs whatever is on display 0,
# including this terminal. Summarise at the end, from sources you have checked.
export MEETING_CAVEAT="${MEETING_CAVEAT:-}"
NOTES_LLM=0 nohup "$PROJ/scripts/meeting-notes.sh" "$WAV" 90 >"$BASE.notes-loop.log" 2>&1 &
nohup "$PROJ/scripts/meeting-screen.sh" "$BASE" 25 >"$BASE.ocr-loop.log" 2>&1 &

sleep 12
echo
echo "=== signal check (speak now to confirm) ==="
for f in "$WAV" "$BASE.macmic.wav"; do
  [ -f "$f" ] || continue
  python3 - "$f" <<'PY'
import sys,struct,math
p=sys.argv[1]
f=open(p,"rb"); f.seek(0,2); sz=f.tell(); f.seek(max(44,sz-160000)); d=f.read(); n=len(d)//2
if not n: print(f"{p.split('/')[-1]:45s} no samples yet"); sys.exit()
s=struct.unpack("<%dh"%n,d[:n*2]); rms=math.sqrt(sum(x*x for x in s)/n)
db=20*math.log10(rms/32768) if rms else -99
print(f"{p.split('/')[-1]:45s} {db:6.1f} dBFS  peak={max(abs(x) for x in s):5d}  {'SPEECH' if db>-42 else 'quiet'}")
PY
done
echo
echo "Stop with: $PROJ/scripts/meeting-ctl.sh stop"
