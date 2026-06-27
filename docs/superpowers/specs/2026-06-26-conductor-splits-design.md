# Conductor — Phase 1.5 PR B: Splits / Panes design

**Date:** 2026-06-26
**Status:** Approved (brainstorm complete; ready for implementation plan)
**Related:** Phase 1.5 multi-surface design (`docs/superpowers/specs/2026-06-26-conductor-multi-surface-design.md`) — this is **PR B** of that milestone (Tabs = PR A / #28 → **Splits = PR B** → Scratch = PR C). The split engine was proven in the spike (`spike/swiftterm-spike/` ⑤).

## Goal

Let a surface tab be split into multiple terminal panes, iTerm/tmux-style: split any pane horizontally **or** vertically, arbitrarily **nested**. Each pane is its own PTY. This completes the "splits/panes" half of the locked 3-level hierarchy (Decision #4).

In PR A a surface tab is exactly one terminal. PR B makes a surface tab own a **pane tree** of terminals.

## Locked decisions (from the grill, 2026-06-26)

| Decision | Choice |
|---|---|
| Split capability | **Both axes, nested (tree)** — split any pane right or down, arbitrarily nested. |
| Keybinds (all customizable) | Split right **⌘D**, split down **⌘⇧D** (split the focused pane); move focus **⌘⌥←/→/↑/↓**; close focused pane **⌘W** (pane-aware); click to focus. |
| New pane | A fresh shell in the worktree cwd (no auto-Claude), like a new tab. |
| Close pane | Closing the focused pane collapses its neighbor; closing the **last pane** in a tab closes the tab; closing the **last tab** respawns (PR A's never-empty rule). |
| Tab reflection | Tab label = focused pane's live title (or the tab's rename if set); tab badge = **rollup across the tab's panes**; Launch Claude (⌘R) → **focused pane**. |
| Per-pane identity | Color stays **tab-level** — panes do not get their own color. The focused pane shows a subtle accent border. |
| Restore | **In-memory only** (pane layout lost on restart), consistent with PR A. |

## Architecture

The codebase keeps fiddly logic in pure `ConductorCore` (XCTest-covered) and AppKit thin. A recursive pane tree with collapse-on-close + focus + geometric navigation is exactly that kind of logic, so the tree model lives in Core. Doing the tree shell-side was considered and **rejected** (untestable, breaks the pattern).

PR A's `WorktreeSurfaces<Handle>` is generic, so the surface **Handle changes from `TerminalSurface` → `SplitSurface`** (a shell container that owns a `PaneTree<TerminalSurface>` and renders it as nested `NSSplitView`s). The AppDelegate's surface lifecycle now drives `SplitSurface`, walking its panes.

### Core pane-tree model (`ConductorCore`, pure + tested)

- **`SplitAxis`**: `.horizontal` (side-by-side panes / vertical dividers) and `.vertical` (stacked panes / horizontal dividers).
- **`PaneTree<Leaf>`** (pure, tested): an `indirect` binary node —
  - `.leaf(id: String, Leaf)` — a terminal (the shell stores a `TerminalSurface` as `Leaf`);
  - `.split(axis: SplitAxis, a: Node, b: Node, ratio: Double)` — two children with a divider position (`ratio` 0…1, default 0.5).
  - Plus a `focusedLeafID`. Operations:
    - `splitFocused(axis:newLeafID:newLeaf:)` — replace the focused leaf with a `.split` of `{old, new}`; focus the new leaf.
    - `close(leafID:)` — remove the leaf; collapse the now-only-child `.split` into its parent (the sibling takes the split's place); re-focus a remaining sibling/nearest leaf. Removing the only leaf reports the tree empty (caller closes the tab).
    - `setFocus(leafID:)`, `focusedLeaf`, `leaves` (ordered list of `(id, Leaf)`), `leaf(id:)`.
- **`PaneRect`** value type (`id: String`, `x/y/width/height: Double`) — no CoreGraphics/AppKit import.
- **`nearestPane(from focusedID: String, direction: PaneDirection, frames: [PaneRect]) -> String?`** — pure geometric neighbor pick: among panes lying in the requested direction (`.left/.right/.up/.down`), choose the nearest by center distance; nil if none. Drives ⌘⌥arrow navigation; the shell feeds it the panes' view frames.
- No persistence (in-memory only).

### Shell `SplitSurface` container (AppKit)

- **`SplitSurface: NSViewController`** — the new surface Handle. Owns a `PaneTree<TerminalSurface>` and a root container view; rebuilds the **nested `NSSplitView`** hierarchy from the tree (each `.split` → an `NSSplitView` with `isVertical` per axis and its two child views arranged; each `.leaf` → that `TerminalSurface`'s view). After any structural change, runs the spike's **deferred distribute** pattern (`DispatchQueue.main.async` → `layoutSubtreeIfNeeded` → `setPosition(_:ofDividerAt:)`, applied recursively) seeded by each split's `ratio`, so dividers land correctly once real widths exist.
- A **single-pane** `SplitSurface` is just one `TerminalSurface` view filling the container (no `NSSplitView` until the first split), so unsplit tabs behave exactly like PR A.
- Per-leaf `TerminalSurface` is reused unchanged from PR A (own PTY, theme, font, title delegate, `outputSnapshot()`).
- Exposes to the AppDelegate: `focusedPane: TerminalSurface`, `allPanes: [TerminalSurface]`, `splitFocused(axis:)` (creates a fresh `TerminalSurface` in the worktree cwd, inserts into the tree, rebuilds, focuses it), `closeFocused() -> Bool` (false ⇒ last pane gone, caller closes the tab), `moveFocus(_ direction:)` (collects pane view frames → Core `nearestPane(...)` → focus + first responder), `focusPane(_:)`.
- **Focus visual:** the focused pane shows a subtle 1px accent border in the worktree's identity color; updated on every focus change. Click-to-focus via the first-responder path (`SplitSurface` tracks which `TerminalSurface` became first responder).

### Keybinds, lifecycle & PR A integration

- **`ShortcutCommand` changes** (all customizable, `.surface` category): rename PR A's `splitSurface` (⌘D) → **`splitRight`** (⌘D); add **`splitDown`** (⌘⇧D), **`focusPaneLeft/Right/Up/Down`** (⌘⌥←/→/↑/↓). **`closeSurface` (⌘W) becomes pane-aware** — closes the focused pane; last-pane closes the tab; last-tab respawns. The Surface menu gains Split Right / Split Down / Move Focus ▸ items; ⌘D is no longer a no-op.
- **AppDelegate Handle swap** — `WorktreeSurfaces<SplitSurface>`; `currentSurface: SplitSurface?`. Everything that walked one terminal now walks panes:
  - theme/font fan-out → `allPanes.forEach { applyTheme / applyFont }`;
  - agent-state poll → snapshot every pane; pane states `rollup` to the **tab badge**, then onward to the sidebar/notch rollup;
  - ⌘+click open-file → routes to the clicked `TerminalSurface` (the monitor already hit-tests);
  - Launch Claude (⌘R) → `currentSurface.focusedPane.sendCommand(...)`.
- **Lifecycle:** split → `currentSurface.splitFocused(axis:)`. Close pane (⌘W) → `currentSurface.closeFocused()`; if false, fall through to PR A's tab-close path (respawns when it was the last tab). Switching tabs/worktrees hides-not-destroys the whole `SplitSurface` (all panes' PTYs stay alive) — preserves PR A persistence.
- **Tab reflection:** `refreshTabBar` reads `focusedPane.terminalTitle` (or the surface's `nameOverride`) for the label and the pane-rollup for the badge. `SurfaceTabBar` is structurally unchanged.

## Testing

- **Core (XCTest):** `PaneTree` — `splitFocused` (focused leaf → 2-child split, axis correct, new leaf focused); `close` (removes leaf, collapses singleton-parent split into grandparent, re-focuses a sibling; only-leaf → empty); nested split/close sequences (build and tear down the diagrammed H+V tree); `leaves` ordering; focus tracking. `nearestPane(...)` — correct neighbor each direction, nil when none, center-distance tie-break. `rollup` reused for the pane→tab badge.
- **In-app:** ⌘D/⌘⇧D split the focused pane correctly; ⌘⌥arrows move focus; click focuses; focused-pane border; ⌘W closes focused pane + collapses neighbor, last-pane closes the tab, last-tab respawns; even divider layout on split; theme/font reach all panes; per-pane badges roll up to tab + sidebar; ⌘+click opens from the clicked pane; Launch Claude → focused pane; switching tabs/worktrees keeps every pane's PTY alive.

## Risks / open implementation questions (for planning)

- **Handle swap blast radius:** changing the surface Handle from `TerminalSurface` → `SplitSurface` touches every PR A surface call site in `AppDelegate` (create/switch/close/archive/theme/font/poll/⌘-click/launch). Sizeable but mechanical; the review must check for missed call sites. Consider giving `SplitSurface` a convenience that mirrors `TerminalSurface`'s old single-pane surface so call sites change minimally.
- **Nested-divider distribution:** the spike's deferred `setPosition` pattern must be applied recursively to inner `NSSplitView`s, after the outer ones lay out.
- **⌘⌥arrow keyEquivalents** firing while the terminal has focus — same responder-chain class as PR A's ⌘⇧[]/⌘1-9 (confirmed working); re-verify.
- **Click-to-focus** detection: confirm `SplitSurface` can reliably observe which `TerminalSurface` became first responder (window first-responder change notification or per-terminal hook).

## Out of scope (PR B)

- Scratch (worktree-less) tabs → PR C.
- Cross-restart restore of pane layout (in-memory only by design).
- Per-pane color/name overrides (color stays tab-level).
- Drag-to-reorder panes or move a pane to another tab.
