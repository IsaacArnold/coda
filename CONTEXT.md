# Coda

A native macOS app that orchestrates Claude Code work across git worktrees. The user manages many parallel branches of work, each in its own worktree, with an embedded terminal as the primary surface.

## Language

**Repository**:
A registered local git repo that worktrees are created from. Carries per-repo settings (setup script, copy-allowlist).
_Avoid_: Project, repo (in user-facing text)

**Worktree**:
The primary unit of work: a branch + its on-disk git worktree + the persisted surface(s) opened inside it. Opening one drops you into a shell in that worktree; Claude is launched on demand, not automatically.
_Avoid_: Session (the old name — it wrongly implied a Claude run is the thing)

**Surface**:
A single pane inside a worktree — a terminal. (The read-only diff view is separate window chrome, a toggleable right-hand pane, not a Surface.) A worktree's surfaces persist (stay live) when you switch away and back.
_Avoid_: Pane (use for split geometry only), view

**Scratch terminal**:
A throwaway terminal not backed by any worktree — the escape hatch for quick one-off shell work.
_Avoid_: Throwaway tab, plain tab

**Claude run**:
An actual invocation of `claude` inside a worktree's terminal surface, started on demand. A worktree may have zero or one running.
_Avoid_: Session, agent (when referring to the process)

## Completions

**Completion popup**:
The dropdown that appears anchored at the terminal cursor as the user types a command, listing candidate subcommands, options, and arguments — each with a short description — navigable by keyboard. Modelled on Kiro/Fig CLI autocomplete.
_Avoid_: Autocomplete menu, intellisense, suggestion box

**Completion spec**:
A declarative description of one CLI's grammar (its subcommands, options, and argument kinds) that drives what the Completion popup offers for that command.
_Avoid_: Schema, definition, grammar file

**Shell integration**:
The consent-injected shell snippet that emits OSC 133 prompt markers (and OSC 7 cwd), letting Coda locate the editable command on the screen and know when a command is running versus being typed.
_Avoid_: Shell hook (reserve "hook" for the Claude Code agent-state hook), prompt hook

## Theming

**Theme**:
The colour scheme the user sets, imported as an `.itermcolors` file (16 ANSI colours + foreground/background/cursor). Drives both the terminal grid and, derived from it, the app chrome. Exactly one is active at a time.
_Avoid_: Colour scheme, palette (reserve "palette" for the identity palette)

**Identity colour**:
The colour that visually tags a repo, worktree, or surface tab so the user can tell parallel work apart — resolved down the chain `surface → worktree → repo → default`. The focused-row accent is a separate identity colour of the app itself. Kept visually distinct from the agent-state badge.
_Avoid_: Tab colour, repo colour (use only for the specific level)

**Identity hue**:
The theme-independent colour *role* an identity colour is stored as — one of `red, orange, yellow, green, cyan, blue, purple, pink`. Each theme resolves a hue to its own concrete colour, so identity colours restyle live when the theme changes ("my red repo" stays red-ish in every theme).
_Avoid_: Slot, index (rejected the positional model), swatch (that's the UI affordance)

**Pinned colour**:
An exact hex an identity colour is fixed to, deliberately ignoring the theme — the escape hatch for "this repo is always bright red". The alternative to storing a hue.
_Avoid_: Custom colour (that's the menu label), override (overloaded with the resolution chain)

**Curated palette**:
A hand-authored hue→hex map bundled per theme, so each bundled theme's identity colours look intentional rather than raw. A theme with no curated palette (any imported `.itermcolors`) falls back to deriving each hue from the theme's ANSI colours.
_Avoid_: Theme palette, colour map
