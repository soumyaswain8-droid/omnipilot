#!/usr/bin/env python3
"""Map-reduce final meeting notes from a transcript + OCR links (all local via Ollama).

Usage:
    finalize_notes.py <base-path-no-ext> [--kind meeting|webinar|workshop|call] [--about "one line"]

Reads  <base>.transcript.md  and (optionally) <base>.links.md
Writes <base>.notes.md

Environment:
    NOTES_MODEL   Ollama model (default: qwen3:8b)
    MIN_SPEECH    Minimum real-speech characters before summarising (default: 2000)
"""
import argparse, json, os, re, sys, time, urllib.request

DEFAULT_MODEL = "qwen3:8b"
OLLAMA = "http://localhost:11434/api/generate"
CHUNK = 12000  # chars per map chunk (~3k tokens)

MODEL = os.environ.get("NOTES_MODEL", DEFAULT_MODEL)
MIN_SPEECH = int(os.environ.get("MIN_SPEECH", "2000"))

ap = argparse.ArgumentParser()
ap.add_argument("base", help="path prefix, no extension")
ap.add_argument("--kind", default="meeting",
                help="meeting | call | webinar | workshop — shapes the output structure")
ap.add_argument("--about", default="",
                help="optional one-line context, e.g. 'sales call with LiveXCapital'")
args = ap.parse_args()
BASE = args.base


def ollama(prompt, num_ctx=8192):
    body = json.dumps({"model": MODEL, "prompt": prompt, "stream": False,
                       "think": False, "options": {"temperature": 0.2, "num_ctx": num_ctx}}).encode()
    req = urllib.request.Request(OLLAMA, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=900) as r:
        resp = json.load(r).get("response", "")
    return re.sub(r"<think>.*?</think>", "", resp, flags=re.S).strip()


# --- load sources ---
try:
    transcript = open(f"{BASE}.transcript.md", encoding="utf-8").read()
except FileNotFoundError:
    sys.exit(f"no transcript at {BASE}.transcript.md")

transcript = re.sub(r"^\*\*\[[0-9:]*\]\*\*", "", transcript, flags=re.M)

try:
    links = open(f"{BASE}.links.md", encoding="utf-8").read()
except FileNotFoundError:
    links = ""


# --- HALLUCINATION GUARD -------------------------------------------------
# 2026-07-15: a 2h15m capture picked up almost no speech (AirPods were the
# output device, so remote audio never reached the mic). The transcript was
# ~1.2 KB of sound-effect tags, and the model confabulated a complete,
# confident, entirely fake set of notes from it. Never summarise a
# transcript that has no real speech in it.
def real_speech(text: str) -> str:
    t = re.sub(r"\([^()]{0,60}\)", " ", text)      # (speaking in foreign language), (water running)
    t = re.sub(r"\[[^\]]{0,60}\]", " ", t)         # [BLANK_AUDIO], [MUSIC]
    t = re.sub(r"^#.*$", " ", t, flags=re.M)       # markdown headers
    t = re.sub(r"[*_`>-]", " ", t)
    return re.sub(r"\s+", " ", t).strip()


speech = real_speech(transcript)
if len(speech) < MIN_SPEECH:
    warn = (
        f"# Notes NOT generated — transcript too thin\n\n"
        f"_Checked {time.strftime('%Y-%m-%d %H:%M')} by finalize_notes.py._\n\n"
        f"**The transcript contains only {len(speech)} characters of real speech "
        f"(minimum {MIN_SPEECH}).** Summarising this would produce invented content, "
        f"so no notes were written.\n\n"
        f"This almost always means audio was captured from the wrong device — e.g. "
        f"AirPods were the output device, so remote audio never reached the mic. "
        f"Check capture devices before the next session.\n\n"
        f"Raw transcript: `{BASE}.transcript.md` ({len(transcript)} chars total)\n"
    )
    if links.strip():
        warn += f"\nOCR-captured links are still real and are preserved in `{BASE}.links.md`.\n"
    open(f"{BASE}.notes.md", "w", encoding="utf-8").write(warn)
    print(f"REFUSED: only {len(speech)} chars of real speech (min {MIN_SPEECH}). "
          f"Wrote warning to {BASE}.notes.md")
    sys.exit(2)

print(f"real speech: {len(speech)} chars — proceeding", flush=True)


# --- chunk ---
chunks = [transcript[i:i + CHUNK] for i in range(0, len(transcript), CHUNK)]
n = len(chunks)
print(f"transcript {len(transcript)} chars -> {n} chunks (model={MODEL})", flush=True)

subject = args.about or f"a {args.kind}"

# --- MAP ---
summaries = []
for idx, c in enumerate(chunks, 1):
    p = (f"This is part {idx} of {n} of an auto-transcribed recording of {subject}. "
         f"The transcription is imperfect — fix obvious mishears, but NEVER invent content "
         f"that is not in the text.\n\n"
         f"Extract concisely as bullets: what was discussed or demonstrated, decisions made, "
         f"questions asked and answers given, commitments or action items, and any names, "
         f"figures, URLs or products mentioned.\n\n"
         f"If a number or figure is spoken, quote it but mark it [audio] — spoken numbers are "
         f"frequently mistranscribed. Bullets only, no preamble.\n\n"
         f"TRANSCRIPT PART {idx}:\n{c}")
    s = ollama(p)
    summaries.append(f"### Segment {idx}\n{s}")
    print(f"  mapped chunk {idx}/{n} ({len(s)} chars)", flush=True)

joined = "\n\n".join(summaries)

# --- REDUCE ---
reduce_p = (
    f"You are compiling the FINAL notes for {subject}. Below are ordered segment summaries "
    f"from the audio transcript, plus exact text and URLs captured from the screen via OCR.\n\n"
    f"CRITICAL RULES:\n"
    f"1. Do NOT invent anything. If something was not discussed, omit that section.\n"
    f"2. OCR text is RELIABLE (read directly off screen). Audio figures are UNRELIABLE.\n"
    f"   Mark every number as **[OCR]** or **[audio]** so the reader knows what to trust.\n"
    f"3. Prefer an OCR figure over a spoken one whenever both exist.\n"
    f"4. If this is a sales pitch, separate what was CLAIMED from what was VERIFIED.\n\n"
    f"Produce clean, re-readable Markdown with this structure:\n\n"
    f"# Notes — <short descriptive title>\n\n"
    f"## TL;DR\n(3-5 sentences: what this was, and what matters)\n\n"
    f"## What was discussed\n(the substance, organised by topic — not chronologically)\n\n"
    f"## Decisions and commitments\n(who said they would do what; omit if none)\n\n"
    f"## Questions raised and answers given\n(omit if none)\n\n"
    f"## Figures and claims\n(a table: figure | source [OCR]/[audio] | context — omit if none)\n\n"
    f"## Links captured\n(dedupe and tidy the OCR URLs)\n\n"
    f"## Action items\n- [ ] ...\n\n"
    f"## Capture quality\n(note anything limiting trust: audio dropout, language switching, "
    f"mangled numbers)\n\n"
    f"SEGMENT SUMMARIES:\n{joined}\n\nOCR-CAPTURED TEXT AND URLS:\n{links}")

print("reducing...", flush=True)
final = ollama(reduce_p, num_ctx=16384)

out = (f"{final}\n\n---\n\n"
       f"_Local capture via OmniPilot. Notes generated {time.strftime('%Y-%m-%d %H:%M')} "
       f"by `{MODEL}` from {len(speech)} chars of transcribed speech"
       f"{' + screen OCR' if links.strip() else ''}._\n")
open(f"{BASE}.notes.md", "w", encoding="utf-8").write(out)
print(f"\nWROTE {BASE}.notes.md ({len(out)} chars)")
