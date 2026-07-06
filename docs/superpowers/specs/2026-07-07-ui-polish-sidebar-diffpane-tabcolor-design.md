# UI polish: sidebar diff figure, diff-pane path, identity-color inheritance, header figure

**Date:** 2026-07-07
**Status:** Approved, ready for implementation plan

Four independent UI fixes surfaced from a GUI verification pass. Each is small and
well-bounded; they share no state, so they can be implemented and verified in any order.

## Issue 1 — Sidebar +/− figure gets cut off when the sidebar narrows

**Symptom:** In the left sidebar, the trailing `+N −M` diff figure on a worktree row
gets clipped when the user drags the sidebar narrower.

**Cause:** In `SidebarController.makeWorktreeCell()` the `statsLabel` is pinned to the
right (before the badge dot) via `stats.trailingAnchor` → `badge.leadingAnchor`, and the
title/subtitle use `lessThanOrEqualTo: stats.leadingAnchor`. But `statsLabel` never gets a
raised horizontal content-compression-resistance priority, so at the default (750, equal to
the title's) Auto Layout is free to compress the figure instead of truncating the title.

**Fix:** Give `statsLabel` a **required** horizontal content-compression-resistance and
content-hugging priority, and **lower** the title (`textField`) and `subtitleLabel`
horizontal compression resistance below that. The figure then holds its intrinsic width and
the title truncates first (it already has `.byTruncatingTail`).

**File:** `Sources/Coda/SidebarController.swift` (cell construction in `makeWorktreeCell()`).
**Scope:** Layout priorities only. No behavior or data change.

## Issue 2 — Diff-pane file path is unreadable when the pane is narrow

**Symptom:** In the right diff pane, a changed file's path truncates in the middle with no
way to see the full name on a narrow pane.

**Decision:** Tail-truncate + tooltip.

**Fix:**
- Change `pathLabel.lineBreakMode` from `.byTruncatingMiddle` to `.byTruncatingHead` so the
  **front** of the path drops and the filename (at the end) always stays visible.
- Set the file row cell's `toolTip` to the full path string — for renames this is the
  `"\(oldPath) → \(path)"` form already computed for `pathLabel.stringValue`; otherwise the
  plain `file.path`. Hovering reveals the complete path.

**File:** `Sources/Coda/DiffPaneView.swift` (`makeFileCell()` for the line-break mode;
`outlineView(_:viewFor:item:)` file-row branch for the tooltip, reusing the same string
already built for the label).
**Scope:** Presentation only.

## Issue 3 — Identity color should fall back to the repo color across the whole chain

**Decision:** Whole identity chain. New resolution order everywhere identity color is used:

```
per-tab override  →  worktree color  →  repo color  →  default
```

Per-tab (`Surface.colorOverride`) and per-worktree (`Worktree.color`) overrides are
untouched — the user keeps full manual control. This only changes the *default* when a
worktree has no color of its own but its repo does.

**Implementation:**
- Add a helper in `AppDelegate` that resolves a worktree's effective identity color with the
  repo fallback, e.g. `identityColor(for: Worktree) -> RGB?` returning
  `worktree.color.flatMap(RGB.init(hex:)) ?? repo(for: worktree)?.color.flatMap(RGB.init(hex:))`.
  The repo lookup uses `store.state.repositories.first { $0.id == wt.repoID }`.
- Route the four identity call sites through it:
  1. **Tab tint** — `refreshTabBar()`: the base color passed to
     `Surface.effectiveColor(worktreeColor:)` becomes `worktree ?? repo` (i.e. the helper's
     result) instead of `selectedWorktree?.color` alone. `effectiveColor` (Core) is
     unchanged — it still does `colorOverride ?? worktreeColor`; we just feed it a
     repo-aware base.
  2. **Identity bar fill** — the `WorktreeBar.update(...)` call site: pass the resolved
     color's hex instead of the raw worktree color.
  3. **Focused-pane border** — `split.identityColor` / `currentSurface.identityColor`
     assignments (the three sites around `AppDelegate` lines ~392, ~736, ~890): resolve via
     the helper.
  4. **Sidebar branch glyph** — the sidebar is a separate controller. Give `WorktreeNode`
     its repo's color hex at construction (the `reload(sections:)` path already has the
     `RepositorySection.repository`), and in the worktree cell's
     `applyIdentityColor(...)` fall back to that repo color when the worktree has no color
     and there's no live override.

**Files:** `Sources/Coda/AppDelegate.swift` (helper + call sites 1–3),
`Sources/Coda/SidebarController.swift` (site 4 + `WorktreeNode` gains repo color).
**Core:** No change to `Surface.effectiveColor`; the fallback is composed at the call sites.

## Issue 4 — Remove the +N −M figure from the identity (workspace) header

**Decision:** Remove it. It duplicates the sidebar's per-worktree green/red figure, and
green/red would clash with the arbitrary colored identity fill.

**Fix:** Delete `statsLabel` and its layout/wiring from `WorktreeBar`, drop the
`diffStats` parameter from `WorktreeBar.update(...)`, and remove the argument from its call
site in `AppDelegate`.

**Files:** `Sources/Coda/WorktreeBar.swift`, `Sources/Coda/AppDelegate.swift` (call site).
**Scope:** Deletion only.

## Verification

- `swift build` (with the Xcode `DEVELOPER_DIR` + separate `--build-path`, per project notes)
  and `swift test` stay green.
- GUI check per issue: narrow the sidebar (figure stays whole, title truncates); narrow the
  diff pane (filename stays visible, tooltip shows full path); set a repo color with an
  uncolored worktree (tabs, identity bar, sidebar glyph, pane border all pick it up; a
  worktree/tab override still wins); confirm the identity header no longer shows `+N −M`.

## Out of scope

- No new preferences or settings UI.
- No change to how repo/worktree/tab colors are *set* (existing context-menu swatches).
- No change to `Surface.effectiveColor`'s signature or the diff-stats computation pipeline.
