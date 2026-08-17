# Aide research digest — omnipilot

*Generated 2026-08-17 from Aide captures. 4 item(s); 3 grounded in decoded source content, 1 from the capture note alone.*

Each entry links back to the original capture. Full reports and any mindmaps live in `aide/data/items/<id>/`.

| # | Title | Captured as | Grounded | Saved |
|---|-------|-------------|:--------:|-------|
| 16 | Ash 'Personal Intelligence' — agentic positioning template | `general` | yes | 2026-06-11 |
| 19 | AI Agents Orchestration (LinkedIn post) | `general` | note-only | 2026-06-20 |
| 44 | Six portfolio sites with strong visual art direction | `omnipilot` | yes | 2026-07-02 |
| 162 | Build assistant avatars from a state sequence, not one reference image | `general` | yes | 2026-08-10 |

---

## 16 — Ash 'Personal Intelligence' — agentic positioning template

- **Source:** https://www.instagram.com/reel/DZZCDkeS5dZ/?igsh=MWlzZWRza2toZ21xYw==
- **Capture note:** (none)
- **Saved:** 2026-06-11_18-40  ·  **Kind:** learning  ·  **Tags:** agentic, positioning, personal-intelligence, memory, go-to-market  ·  **Confidence:** 0.74
- **Grounding:** decoded source content

## What It Is
Vellum's **Ash** is positioned as the "world's first Personal Intelligence" — an AI assistant that, per the pitch, sorts your email, preps meeting briefs, and handles Slack before you open your laptop. CEO **Akash Sharma** raised **$25M** from Y Combinator, HubSpot's **Dharmesh Shah**, Dropbox's **Arash Ferdowsi**, and Rebel Fund.

## The Core Thesis
Three claims define the wedge:
1. **One-click connection** to every app (the integration layer is the moat).
2. **Deep persistent memory** — context that compounds over time.
3. **Ownership** — "it belongs to YOU, not a tech giant." This is the trust/privacy positioning aimed squarely at incumbents (Google, Microsoft Copilot).

The rallying cry — *"the app era is ending"* — frames AI as an orchestration layer that subsumes individual SaaS tools rather than competing inside them.

## Reading Between the Lines
This is marketing-grade narrative (an IG reel via an aggregator account), so treat the capability claims as aspirational. The defensible insight is the **structure of the pitch**, not the product specifics: founder + named marquee investors + a sharp "post-app" frame + ownership/privacy hook. That combination is what makes it spread.

## Why It Matters
The "personal intelligence" category validates a pattern many founders are circling: an agent with memory that sits *above* apps and acts proactively. For anyone building assistant-style or agentic products, this is both a competitive signal and a positioning template.

**How to use:** Mine this as a positioning template rather than a product to copy. The 'proactive agent with deep memory, owned by you, that ends the app era' framing maps directly onto your agentic projects — TradePilot (an autonomous trading agent) and DevPilot/Sarathi (an orchestration layer over dev tools) can both borrow the 'intelligence layer above the apps' narrative and the ownership/privacy angle, which resonates with Indian SMB clients (EnquiryPilot, StockPilot) wary of big-tech lock-in. Concretely: adopt the 'before you open your laptop' proactive-briefing pattern as a feature spec (morning digest, auto-prepped context) and study the fundraise messaging structure — founder + named marquee backers + one sharp category-defining line — when crafting your own decks and landing pages.

---

## 19 — AI Agents Orchestration (LinkedIn post)

- **Source:** https://www.linkedin.com/posts/ai-agents-orchestration-share-7473693744446328832-kU7D/?utm_source=share&utm_medium=member_ios&rcm=ACoAABrnvqIBHTALXKXuGqUL5CMquHjFIP8YYMw
- **Capture note:** (none)
- **Saved:** 2026-06-20_12-22  ·  **Kind:** research_source  ·  **Tags:** ai-agents, orchestration, llm, multi-agent, linkedin  ·  **Confidence:** 0.55
- **Grounding:** **capture note only** — no transcript or scrape was recovered, so treat the analysis below as framing, not as a summary of the source

## What This Is
A saved LinkedIn post tagged **AI agents orchestration**. The scrape and transcript came back empty, so this report is reconstructed from the post's topic signal (the slug `ai-agents-orchestration-share`) rather than verified body text. Treat the specifics as the field's consensus on agent orchestration, not direct quotes from the author.

## The Core Idea
Agent *orchestration* is the layer that coordinates multiple specialized LLM agents toward a goal instead of relying on one monolithic prompt. The recurring themes in this genre of post:

- **Decomposition** — split a task into narrow, single-responsibility agents (research, plan, implement, verify) rather than one agent doing everything.
- **Control flow** — a deterministic orchestrator decides routing, parallelism, and retries; agents handle the fuzzy work. Deterministic glue beats model-driven glue for reliability.
- **Parallel fan-out + barrier** — run independent agents concurrently, then synthesize. Wall-clock drops to the slowest single chain, not the sum.
- **Verification** — adversarial check/judge agents catch plausible-but-wrong outputs before they ship.
- **Guardrails** — timeouts, tool limits, and decomposition gates prevent runaway token burn.

## Caveats
Because the body text wasn't retrievable, the author's specific framework, tools, or claims are unknown. Re-scrape or open the link to capture the actual argument, diagrams, or referenced stack before quoting it.

## Verdict
High-relevance topic, low source fidelity. Useful as a prompt to audit your own orchestration patterns; not citable as evidence until the content is recovered.

**How to use:** This maps directly onto your existing orchestration work: DevPilot/Sarathi's sprint orchestrator (deterministic DAG + parallel agents + verification agent) and the Aide capture pipeline are exactly the decompose-fan-out-verify pattern this post describes — use it as an external sanity-check on your timeout/decomposition guardrails (agent-safety rules) and as reference framing for a 'how we orchestrate agents' blog post or DevPilot positioning piece. For TradePilot's multi-agent dashboard, treat it as a checklist: single-responsibility role agents, a deterministic controller, and an adversarial judge before any trade signal is trusted. Before citing it publicly, re-scrape the URL to recover the actual body so claims are grounded, not inferred.

---

## 44 — Six portfolio sites with strong visual art direction

- **Source:** https://www.instagram.com/reel/DZ7SZnuIDhS/
- **Capture note:** landing page
- **Saved:** 2026-07-02_15-45  ·  **Kind:** research_source  ·  **Tags:** portfolio, landing-page, web-design, motion, typography  ·  **Confidence:** 0.75
- **Grounding:** decoded source content

## Summary
An Instagram reel by designer Aneta Kmiecik (@ux.aneta) curating six portfolio websites praised for having "a cool visual touch" — i.e., portfolios that go beyond template grids and use motion, typography, and art direction as differentiators.

## The Six Sites
- **moah.studio** — studio portfolio, likely motion-led with editorial layout
- **scottmilton.com** — individual designer portfolio
- **madrepunk.com** — creative studio with an expressive, punk-inflected identity
- **rabenrifaie.com** — personal portfolio, name-as-brand approach
- **kargo-studio.com** — design studio site
- **nrthview.com** — studio/agency portfolio

(The reel provides only the URLs; the sites themselves are the primary source material and should be visited for specifics.)

## Why This Matters
The common thread in curations like this: distinctive portfolios win on **art direction, motion design, and typographic confidence**, not on feature count. Recurring patterns in this genre of site include oversized display type, scroll-driven reveals, custom cursors, asymmetric grids, and a single strong color idea. These are exactly the moves that separate "credible studio" from "Squarespace default" in a visitor's first five seconds.

## Caveats
- This is a listicle-style engagement reel ("Comment ART for links"), so the curation is taste-driven, not vetted for performance, accessibility, or conversion.
- Visually maximal portfolios often trade off load time and mobile usability — worth auditing before borrowing techniques wholesale.
- Sites in this genre change or lapse frequently; verify each URL is live before referencing.

## Suggested Next Step
A 30-minute pass through all six sites, screenshotting 2–3 standout interactions each (hero treatment, project-card hover, page transition) would yield a reusable swipe file of concrete patterns rather than a dead bookmark.

**How to use:** This is a ready-made reference bank for the parked Sidewall landing redesign, which stalled precisely for lack of a reference URL and direction — pick one or two of these six sites as the concrete visual benchmark before retrying that build. The same swipe file feeds the client-facing demos (StockPilot saree pitch, Acreon CRM, BrainBout): borrowing one distinctive move per demo — a bold hero type treatment, a scroll reveal, a confident single-color system — makes each pitch feel custom rather than templated. Pair the screenshots with the installed ui-ux-pro-max and emil-design-eng skills as grounding references when briefing design work, and fold the strongest patterns into a reusable 'visual touch' checklist for all future landing pages and portfolio-style deliverables.

---

## 162 — Build assistant avatars from a state sequence, not one reference image

- **Source:** https://www.instagram.com/reel/Db1H_JTuh6O/?igsh=MTZnOWZkc29zZnBsbQ==
- **Capture note:** Sarathi can we do something like this
- **Saved:** 2026-08-10_23-29  ·  **Kind:** learning  ·  **Tags:** avatar, ai-assistant, prompt-technique, ui  ·  **Confidence:** 0.72
- **Grounding:** decoded source content

## What the item shows

Reznikov Engineering documents how they gave their agent "Apex" a visual identity — a humanoid "face" for an AI assistant. The value is in the *process failure* they admit to, not the output.

## The workflow, in order

1. **Generate a mockup with GPT** — one still image to anchor the look.
2. **Prompt-to-code in Claude Code with that single reference** — *this failed.* Results were "awful" (their own example is in the comments).
3. **Create reference pics for every stage of the humanoid** — a 6-image sequence, not one image.
4. **Add "liveness" incrementally** on top of that sequence — only then did it look good.
5. **Now adding full motion and responsiveness** — the avatar reacts, it isn't a loop.

## The transferable insight

A single reference image underspecifies an animated character. The model has no information about what the *in-between* states look like, so it invents them inconsistently. A **state sequence** — idle → attentive → thinking → speaking → responding → idle — turns an open-ended generative problem into interpolation between fixed anchors. That is why step 3 worked and step 2 didn't.

The same principle recurs elsewhere: give the model the keyframes, let it fill gaps. It is the visual equivalent of few-shot prompting.

## Cost and honesty notes

- This is a **buildinpublic** post; no code, no repo, no stack disclosed. Treat it as method, not implementation.
- "Liveness" here is almost certainly CSS/canvas/SVG layering over generated stills, not real-time video generation — cheap to reproduce.
- Motion + responsiveness is the hard part and is explicitly still *in progress*. Don't assume it's solved.

## Verdict

A character face is a differentiator for an assistant that already has a console and a voice. It is decoration for one that doesn't. Sequence-of-states is the reusable technique regardless.

**How to use:** Yes — Sarathi is the natural fit, since it already has a console UI (Ask tab on WS :9886) that currently gives back text with no sense of presence. Apply the method literally: define 5-6 discrete agent states that Sarathi already emits (idle, listening, thinking/researching, answering, error/gap-detected, done), generate one reference image per state rather than one image overall, then drive the swap from the WebSocket events the console is already receiving — no new backend work, the state signal exists. Keep it to a small persistent element in the console header, not a full-screen character; a face that idles wrong is worse than no face. Two spillovers worth taking: (1) the same 6-state sequence becomes the loading/progress vocabulary for the whole console, which is a UX win independent of the avatar; (2) the reference-sequence technique transfers directly to the surya-showcase animated product decks and the EnquiryPilot launch video, where a consistent character across frames is exactly the problem you keep hitting. Timebox this — it's a polish item, and Sarathi's brain quality and the funding/Hub71 deadlines outrank it. Build it when the console is otherwise stable, not before.

---
