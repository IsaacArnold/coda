# Icon Brief — "Coda" (macOS app)

> Brief for an icon designer / image generator to build the macOS app icon.
> Name pending rename (app is currently "Conductor" in code — see note at bottom).

**What it is:** A native macOS app that orchestrates multiple AI coding agents
(Claude Code) running in parallel across isolated git worktrees. Think of it as a
control surface sitting *above* a terminal — you spin up sessions, watch each
agent's status, and switch between them. It's a developer power-tool,
terminal-centric, keyboard-driven.

**The name's metaphor:** "Coda" works on two levels — it's a near-homophone of
**"code"**, and in music a **coda** (symbol **𝄌**) is the passage that brings many
voices to a unified close. The idea to convey: **bringing parallel work to a clean,
coordinated finish.** (It also quietly honors a lineage of beloved Mac developer
tools named Coda.)

## Concept directions (pick or blend)

1. **The coda symbol as hero mark** — the musical coda sign **𝄌** (a circle bisected
   by a crosshair) is already a clean, geometric, instantly-iconic shape. Render it
   boldly with depth and an accent glow; it reads as a confident app mark at any size
   and ties straight to the name.
2. **Coda symbol meets the terminal** — fuse the 𝄌 crosshair with a terminal
   cursor/caret or a `>_` prompt, so the mark says "code" and "coordination" at once.
3. **Converging streams resolving to a point** — several parallel glowing lines
   (parallel agents/worktrees) flowing inward and resolving into a single mark or note
   — the "coda" as the moment they come together.

## Visual style

- Modern macOS (Tahoe-era) icon: **rounded-square "squircle"** shape, front-facing,
  subtle depth via soft gradient and a gentle drop shadow. A single bold,
  instantly-readable motif — no fine detail that dies at 32px.
- **Dark, terminal-inspired base** with a **Dracula-style palette**: deep charcoal
  background (`#282A36`) with vivid accents — purple (`#BD93F9`), cyan (`#8BE9FD`),
  green (`#50FA7B`), pink (`#FF79C6`). Use one or two accents as the hero color, not
  all at once.
- Optional warm accent: the app's existing brand mark is a **terracotta/clay-orange**
  ("Claude mark") — a small terracotta highlight could tie it to the ecosystem.
- Feel: precise, premium, a little "synthwave/IDE," not playful or cartoonish.

## Technical requirements

- Master at **1024×1024 PNG**, square canvas. macOS applies the squircle mask +
  standard icon margins, so keep the motif centered with breathing room (don't fill
  edge-to-edge).
- Must read clearly at 16, 32, 128, 256, 512, 1024 — design for the smallest size first.
- Deliverable ideally as a layered/vector source so it can export the full `.icns`
  set (and a tintable/monochrome variant for Tahoe's themed icons is a plus).

## Avoid

Literal sheet-music or orchestra clichés, skeuomorphic terminals with tiny unreadable
text, clip-art git logos, busy multi-color gradients, anything that looks like a
generic CLI app.

---

**Naming note:** This brief uses the new name **Coda**. The codebase, bundle id,
window titles, and `DECISIONS.md` still say **Conductor** — the `Conductor → Coda`
rename is deferred to a later code change.
