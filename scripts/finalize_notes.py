#!/usr/bin/env python3
"""Map-reduce final meeting notes from a long transcript + OCR links (all local via Ollama)."""
import json, re, sys, urllib.request

BASE = sys.argv[1] if len(sys.argv) > 1 else "data/meetings/mic_2026-07-05_11-16-28"
MODEL = "llama3.2:3b"
OLLAMA = "http://localhost:11434/api/generate"
CHUNK = 12000   # chars per map chunk (~3k tokens)

def ollama(prompt, num_ctx=8192):
    body = json.dumps({"model": MODEL, "prompt": prompt, "stream": False,
                       "think": False, "options": {"temperature": 0.2, "num_ctx": num_ctx}}).encode()
    req = urllib.request.Request(OLLAMA, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as r:
        resp = json.load(r).get("response", "")
    return re.sub(r"<think>.*?</think>", "", resp, flags=re.S).strip()

# --- load sources ---
transcript = open(f"{BASE}.transcript.md", encoding="utf-8").read()
transcript = re.sub(r"^\*\*\[[0-9:]*\]\*\*", "", transcript, flags=re.M)
transcript = re.sub(r"[Nn] ?urbukh ?alum|[Nn] ?urbukkalem", "NotebookLM", transcript)
try:    links = open(f"{BASE}.links.md", encoding="utf-8").read()
except FileNotFoundError: links = ""

# --- chunk ---
chunks, i = [], 0
while i < len(transcript):
    chunks.append(transcript[i:i+CHUNK]); i += CHUNK
n = len(chunks)
print(f"transcript {len(transcript)} chars -> {n} chunks", flush=True)

# --- MAP ---
summaries = []
for idx, c in enumerate(chunks, 1):
    p = (f"This is part {idx} of {n} of a live AI-tools workshop transcript (auto-transcribed; fix "
         f"obvious mishears, e.g. 'Nurbukkalem'=NotebookLM). Extract concisely as bullets: which "
         f"tools/websites are demoed here, what is shown/done, any step-by-step instructions, and any "
         f"URLs or prompts mentioned. Bullets only, no preamble.\n\nTRANSCRIPT PART {idx}:\n{c}")
    s = ollama(p)
    summaries.append(f"### Segment {idx}\n{s}")
    print(f"  mapped chunk {idx}/{n} ({len(s)} chars)", flush=True)

joined = "\n\n".join(summaries)

# --- REDUCE ---
reduce_p = (
    "You are compiling the FINAL notes for a 2+ hour live AI-tools workshop (by Be10X). Below are "
    "ordered segment summaries plus a list of exact URLs captured from screen via OCR. Produce clean, "
    "re-readable Markdown notes. Structure:\n\n"
    "# AI Tools Workshop — Notes\n\n"
    "## TL;DR (3-4 sentences)\n\n"
    "## Tools Covered\n"
    "For EACH tool demoed: `### <Tool name>` then — what it does; exact link (from the OCR list); and a "
    "numbered 'How-to' of the steps shown in the workshop.\n\n"
    "## Key Takeaways\n\n"
    "## All Links & Resources\n(dedupe and tidy the OCR URLs into a clean list)\n\n"
    "## Action Items\n- [ ] ...\n\n"
    "Be specific and use the exact URLs. Merge duplicate tool mentions across segments. Do not invent.\n\n"
    f"SEGMENT SUMMARIES:\n{joined}\n\nOCR URLS:\n{links}")
print("reducing...", flush=True)
final = ollama(reduce_p, num_ctx=16384)

out = (f"# AI Tools Workshop — Final Notes\n\n"
       f"_Local capture via OmniPilot — 2h15m audio + 2h screen video. Generated {__import__('time').strftime('%Y-%m-%d %H:%M')}._\n\n"
       f"{final}\n")
open(f"{BASE}.notes.md", "w", encoding="utf-8").write(out)
print(f"\nWROTE {BASE}.notes.md ({len(out)} chars)")
