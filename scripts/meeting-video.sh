#!/bin/bash
# meeting-video.sh — continuous screen video via auto-restarting screencapture segments.
#
# `screencapture -v` gives full Retina clarity (best for re-reading URLs/UI) and finalizes each
# file when it stops. It occasionally stops on its own (e.g. collision with still-capture used by
# the OCR loop). Instead of fighting that, we record in segments and auto-restart — the segments
# are concatenated into one video at meeting end. Writes to the given (external) directory.
#
# Usage: meeting-video.sh <output-dir>
#   Stop cleanly with: pkill -f meeting-video.sh && kill -INT $(pgrep -f 'screencapture -v')
set -uo pipefail

OUTDIR="${1:?usage: meeting-video.sh <output-dir>}"
mkdir -p "$OUTDIR"

# resume numbering if segments already exist
n="$(ls "$OUTDIR"/seg_*.mov 2>/dev/null | sed -E 's/.*seg_0*([0-9]+)\.mov/\1/' | sort -n | tail -1)"
n="$(( ${n:-0} + 1 ))"

log() { echo "[$(date +%H:%M:%S)] $*"; }
log "screen video (segmented) -> $OUTDIR (starting at seg_$(printf '%03d' "$n"))"

while true; do
  seg="$(printf '%s/seg_%03d.mov' "$OUTDIR" "$n")"
  log "recording $seg"
  screencapture -v "$seg"     # blocks until it stops; finalizes the .mov
  sz="$(du -h "$seg" 2>/dev/null | cut -f1)"
  log "segment ended: $(basename "$seg") ($sz)"
  n=$((n+1))
  sleep 1
done
