# Conductor — Phase 1.5: Multi-surface design

**Date:** 2026-06-26
**Status:** Approved (brainstorm complete; ready for implementation plan)
**Related:** `DECISIONS.md` → "Phase 1.5 — Multi-surface"; locked theming design (`docs/superpowers/specs/2026-06-25-conductor-theming-design.md`); keybindings + settings work (PRs #21–#23); surface persistence (`SurfaceRegistry`, PR #8).

## Goal

Bring Conductor's surface layer to Supacode parity by completing the two pieces of the locked 3-level hierarchy (Decision #4) plus the escape hatch (Decision #3) that Phase 1 stubbed but never built:

1. **Per-worktree surface tabs** — multiple terminal surfaces inside one worktree, each its own PTY, persisting across worktree switches.
2. **Splits / panes** — split a surface tab into side-by-side panes.
3. **Scratch (worktree-less) tabs** — throwaway shells not bound to any worktree.

Today the model is exactly **one surface per worktree**: `SurfaceRegistry<Handle>` is a flat `[worktreeID: Handle]` map. Phase 1.5 changes that fundamentally.

## Scope & sequencing

This spec covers the **whole Phase 1.5 architecture** so the data model supports all three pieces, but delivery is **sequenced into three PRs**:

- **PR A — Surface tabs** *(this spec's implementation slice)*: Core surface model + tab bar UI + keybinds + lifecycle + per-tab badge with sidebar/notch rollup.
- **PR B — Splits / panes**: split a surface tab into panes (engine proven in the spike ⑤).
- **PR C — Scratch tabs**: worktree-less shells in the tab bar, outside the sidebar grouping.

PR A wires the seams for B and C (a no-op `splitSurface`/⌘D command; a reserved `Surface.kind = .scratch`) but builds neither. Each PR is independently reviewable and verifiable in-app, built via the usual subagent-driven TDD loop (per-task review + final whole-branch review).

## Locked decisions (from the grill, 2026-06-26)

| Decision | Choice |
|---|---|
| Scope | Sequenced: Tabs (PR A) → Splits (PR B) → Scratch (PR C). Spec covers whole arch. |
| Tab identity | Auto-label + optional rename + optional **per-tab color override**. Active tab's *effective* color drives chrome. |
| Keybinds | Full **customizable** set: ⌘T new, ⌘W close, ⌘⇧] / ⌘⇧[ next/prev, ⌘1–9 go-to-N, ⌘D split (PR B). |
| Launch Claude (⌘R) | Runs `claude` in the **active** surface (unchanged, now scoped to active tab). |
| Close tab | Confirm if a foreground process is busy; closing the **last** tab respawns a fresh shell immediately — a selected worktree always has ≥1 surface (never an empty pane). _(Revised 2026-06-26 after in-app testing: the original "leave worktree empty" left a dead-end with no affordance; flipped to never-empty.)_ |
| Badge | **Per-tab badge** in the tab bar **+ sidebar/notch rollup** (priority: needsYou > working > done > idle). |
| Restore | **In-memory only**, no cross-restart restore. Surfaces persist across worktree switches but a restart starts each worktree with one fresh shell. |

## Architecture

The codebase pattern is deliberate: decision logic lives in pure `ConductorCore` (XCTest-covered); AppKit is kept thin. Putting tab ordering/active-tracking in the shell was considered and **rejected** (breaks the pattern, loses test coverage).

The existing generic `SurfaceRegistry<Handle>` is extended from a flat `[worktreeID: Handle]` map into a **two-level** structure: `[worktreeID: WorktreeSurfaces<Handle>]`. All ordering/active logic stays pure and testable with a stub `Handle`; the shell stores `TerminalSurface` as the `Handle`.

### Core surface model (`ConductorCore`, pure + tested)

- **`Surface`** (value type):
  - `id: String`
  - `nameOverride: String?` — user rename; `nil` ⇒ use the live auto-label.
  - `colorOverride: RGB?` — per-tab color; `nil` ⇒ inherit worktree color.
  - `kind: SurfaceKind` — `.worktree` now; `.scratch` reserved for PR C.
  - `effectiveColor(worktreeColor:) = colorOverride ?? worktreeColor`.
  - The auto-label is **not stored** — the shell derives the display label from the live terminal title (OSC-set by zsh/claude), falling back to `nameOverride ?? "Terminal {index+1}"`.

- **`WorktreeSurfaces<Handle>`**: an ordered `[(Surface, Handle)]` plus `activeSurfaceID`. Pure operations:
  - `add(handle:metadata:)` — appends **after** the active surface and makes it active.
  - `close(id:)` — removes; if it was active, selects the **right** neighbor, else **left**, else `nil` (empty worktree).
  - `setActive(id:)`, `next()` / `prev()` (wraparound), `goTo(index:)` (bounds-checked).
  - `reorder(from:to:)`.
  - `rename(id:to:)`, `setColor(id:to:)`.

- **`SurfaceRegistry<Handle>`** (extended): `[worktreeID: WorktreeSurfaces<Handle>]`; keeps `activeWorktreeID`. `evict(worktreeID:)` tears down **all** of a worktree's surfaces on archive. A single-surface worktree must behave exactly like today (back-compat).

- **`rollup(_ states: [AgentState]) -> AgentState`** (free function): needsYou > working > done > idle. Feeds the sidebar row + notch.

- **Persistence:** none. `nameOverride`/`colorOverride` are in-memory only (consistent with no-restore) — no `local.json`/serialization changes.

### Tab bar UI & chrome interaction (shell/AppKit)

- **`SurfaceTabBar`** — a new `NSView` placed directly **below the floating identity bar**, above the terminal area. Supacode-style horizontal row of tab buttons, each `[badge dot] [label] [×]`, active one highlighted, with a trailing `+` button (= ⌘T). Shown only when a worktree is focused.
- **Label** — live terminal title via SwiftTerm's title delegate (`titleChanged` / `setTerminalTitle`), falling back to `nameOverride ?? "Terminal {index+1}"`. Rename via double-click (inline field) or context menu.
- **Per-tab context menu** (right-click): Rename…, Set Color ▸ (IdentityPalette swatches), Remove Color, Close Tab. **Refactor:** extract the near-duplicate repo/worktree Set-Color submenu (the DRY tech-debt flagged in PR #27) into a shared helper and reuse it here.
- **Chrome/identity coupling** — the **active surface's** `effectiveColor` (per-tab override → worktree color) drives the identity bar fill + sidebar glyph accent, routed through the existing `ChromeTheme` seam. Switching tabs re-tints chrome live. The terminal grid stays the one global theme (unchanged, per the locked theming design).
- **Switching** — keeps persist-don't-destroy: `TerminalSurface` views are hidden-not-destroyed on switch, now extended to sibling surfaces within a worktree.

### Keybinds, menu & lifecycle

- **New `ShortcutCommand` cases** (all customizable, new "Surfaces" category in the Keybindings pane): `newSurface` (⌘T), `closeSurface` (⌘W), `nextSurface` (⌘⇧]), `prevSurface` (⌘⇧[), `goToSurface1…9` (⌘1–⌘9), `splitSurface` (⌘D, reserved/no-op until PR B). Each gets a `defaultChord`; menu key-equivalents derive from effective chords as today.
- **New "Surface" menu** in the menu bar exposing New/Close/Next/Prev/Go-to/Split so they respect rebinding.
- **Lifecycle:**
  - *New surface* — spawns a fresh `TerminalSurface` (shell in the worktree's cwd), appended after active, becomes active + first responder. Claude **not** auto-launched.
  - *Launch Claude (⌘R)* — types `claude` into the **active** surface.
  - *Close surface (⌘W)* — if a foreground process is running (reuse the agent-state non-idle check), confirm "X is running. Close anyway?"; on confirm, kill the PTY, evict from the registry, activate the neighbor. Closing the last tab leaves the worktree **empty**; re-focus spawns a fresh shell.
- **Badge polling** — the ~1s poll snapshots **every** surface of each worktree (background tabs included — hidden-not-destroyed, so `outputSnapshot()` still reads their buffer), sets each tab's badge, and feeds `rollup(...)` for the sidebar row + notch.

## Extension points (do not build in PR A)

- **Splits (PR B)** — live *inside* one surface tab. The shell's per-surface container becomes an `NSSplitView` of panes (spike ⑤: dynamic add-pane + the `setPosition(_:ofDividerAt:)`-after-layout gotcha). PR A's Core model stays **split-agnostic**; `splitSurface`/⌘D is wired but no-op.
- **Scratch tabs (PR C)** — `Surface.kind = .scratch`, worktree-less shells living in the tab bar outside the sidebar's repo→worktree grouping. The two-level registry already accommodates a special non-worktree bucket later.

## Risks / open implementation questions (for planning)

- **Shifted-symbol keyEquivalents** — `KeyChordAppKit` requires ≥1 modifier and rejects some shifted-symbol chords. ⌘1–9 are fine; **⌘⇧] / ⌘⇧[ must be verified** as live `keyEquivalent`s — if they don't fire, pick a working default (e.g. ⌃Tab / ⌃⇧Tab or ⌘⌥→/←). ⌘T/⌘W aren't currently reserved → no conflict.
- **Off-screen snapshot** — confirm `TerminalSurface.outputSnapshot()` reads a hidden (background-tab) surface's buffer correctly, so per-tab badges work for non-active tabs.
- **Terminal-title auto-label** — confirm SwiftTerm reports OSC title changes via its delegate for the auto-label; otherwise fall back to "Terminal N".

## Testing

- **Core (XCTest):** `WorktreeSurfaces` ordering & active-selection (add appends-after-active + activates; close-active picks right→left→nil; next/prev wraparound; goTo bounds; reorder); `Surface.effectiveColor` + label fallback; `rollup` priority across all `AgentState` combinations; `SurfaceRegistry` two-level register/handle/evict-all-on-archive; back-compat (single-surface worktree behaves like today).
- **In-app (PR A):** tab create/close/switch, rename, per-tab color → live chrome re-tint, busy-close confirmation, ⌘T/⌘W/⌘1–9 keybinds, per-tab badge + sidebar rollup, last-tab-empty → re-focus respawns shell.

## Out of scope (Phase 1.5)

- Cross-restart restore of tabs/layout (#14 stays deferred).
- Splits (PR B) and scratch tabs (PR C) — separate PRs after PR A.
- Per-surface `runScript` / fuller per-surface config (Phase 3).
