#!/bin/bash
# meeting-screen.sh — periodic screenshot + OCR to capture on-screen links & tutorial text.
#
# Whisper can only hear speech; the real URLs, tool names and UI labels live on screen
# (e.g. links pasted in Zoom chat). This grabs a screenshot every INTERVAL seconds, OCRs it
# with tesseract, harvests URLs (deduped) into <base>.links.md, and keeps unique on-screen
# lines in <base>.screen-text.txt. PNGs are deleted right after OCR. All local.
#
# Usage: meeting-screen.sh <base-path-no-ext> [interval_seconds]
set -uo pipefail

BASE="${1:?usage: meeting-screen.sh <base-path-no-ext> [interval_seconds]}"
INTERVAL="${2:-25}"

LINKS="${BASE}.links.md"
SCREENTEXT="${BASE}.screen-text.txt"
SHOTDIR="$(dirname "$BASE")/.shots"
mkdir -p "$SHOTDIR"

[ -f "$LINKS" ]      || printf '# Links & Resources (captured from screen via OCR)\n\n' > "$LINKS"
[ -f "$SCREENTEXT" ] || : > "$SCREENTEXT"

log() { echo "[$(date +%H:%M:%S)] $*"; }
log "screen OCR started (interval ${INTERVAL}s)"
log "links:       $LINKS"
log "screen-text: $SCREENTEXT"

while true; do
  shot="$SHOTDIR/shot.png"
  if screencapture -x "$shot" 2>/dev/null && [ -f "$shot" ]; then
    txt="$(tesseract "$shot" stdout 2>/dev/null)"
    rm -f "$shot"

    # --- harvest URLs (repair common OCR errors, strip trailing junk) ---
    printf '%s\n' "$txt" \
      | sed -E 's/[nN]ttps/https/g; s/[hH][tT][tT][pP][sS]?[[:space:]]*:[[:space:]]*\/\//https:\/\//g' \
      | grep -oiE '(https?://[a-z0-9./?=&_%+#~-]+|[a-z0-9-]+\.(com|google|ai|io|org|net|co|in|dev|app)(/[a-z0-9./?=&_%+#~-]*)?)' \
      | sed -E 's#[).,;:"'"'"']*$##; s#/+$#/#' \
      | grep -viE '^https?://$' \
      | sort -u \
      | while read -r u; do
          [ -z "$u" ] && continue
          if ! grep -qiF "$u" "$LINKS"; then
            printf -- '- %s  _(first seen %s)_\n' "$u" "$(date +%H:%M)" >> "$LINKS"
            log "new link: $u"
          fi
        done

    # --- keep unique, meaningful on-screen lines (>=3 words or contains a dot-domain) ---
    printf '%s\n' "$txt" \
      | sed 's/[[:space:]]\{2,\}/ /g; s/^ //; s/ $//' \
      | grep -E '([a-zA-Z][a-zA-Z]+ ){2,}[a-zA-Z]|[a-z0-9-]+\.[a-z]{2,}' \
      | grep -vE '^\s*$' >> "${SCREENTEXT}.new" 2>/dev/null
    if [ -f "${SCREENTEXT}.new" ]; then
      cat "$SCREENTEXT" "${SCREENTEXT}.new" | awk '!seen[$0]++' > "${SCREENTEXT}.tmp" 2>/dev/null \
        && mv "${SCREENTEXT}.tmp" "$SCREENTEXT"
      rm -f "${SCREENTEXT}.new"
    fi
  fi
  sleep "$INTERVAL"
done
