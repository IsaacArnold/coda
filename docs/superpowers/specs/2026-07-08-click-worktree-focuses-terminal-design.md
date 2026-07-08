# Click a worktree/branch → focus its terminal

**Date:** 2026-07-08
**Status:** Approved

## Problem

Clicking a worktree in the sidebar switches the detail view to that worktree's
terminal, but keyboard focus stays in the sidebar. The user must click again
into the terminal before they can type — a daily friction.

Root cause: `AppDelegate.select(_:)` handles two ways a worktree's surface gets
shown, and only one focuses:

- **First open** (no surface yet) → `createSurface(...)` runs, which calls
  `view(focus:)`. Focus works.
- **Switch to an existing surface** (the common case) → the `else if let active`
  branch unhides the surface and sets `currentSurface`, but never calls
  `view(focus:)`. Focus is left wherever it was (the sidebar).

The tab-switch path (`activateSurface`) already focuses correctly and is the
proven pattern to mirror.

In this app the sidebar rows *are* worktrees, each labelled with its branch; the
top `WorktreeBar` branch label is display-only. "Click a worktree or branch" is
therefore fully covered by the sidebar selection path — no other clickable
branch surface exists.

## Design

### Core change: `select(_:focusTerminal:)`

Add a `focusTerminal: Bool = true` parameter to
`AppDelegate.select(_ s: Worktree?)`. When `focusTerminal` is true, focus the
resolved terminal in both paths:

1. **Re-clicking the already-shown worktree** — the idempotent early-return
   (`guard shownWorktreeID != s?.id else { return }`) focuses `currentSurface`
   *before* returning, so clicking the active row returns focus from the sidebar
   to its terminal (per the "always refocus" decision).
2. **Switching worktrees** — after the surface is resolved (either freshly
   created or an unhidden existing one), call `view(focus:)` on
   `currentSurface`. This covers the `else if let active` branch that currently
   unhides without focusing. The first-open path's existing focus in
   `createSurface` is harmless and redundant with this.

### Guard against background focus theft

"Always refocus" must not let a background reload steal focus. The sidebar's
periodic programmatic reload (on HEAD/branch changes) re-selects the current
row, which fires `outlineViewSelectionDidChange`. Without a guard, that would
yank focus into the terminal while the user is working in another view (e.g. the
diff pane).

`SidebarController` distinguishes a user click from a programmatic reload:

- Add a private `isReloading` flag. `reload(sections:selectedWorktreeID:...)`
  sets it `true` around its `selectRowIndexes` call and back to `false` after.
- Change `onSelect` from `((Worktree?) -> Void)?` to
  `((Worktree?, _ userInitiated: Bool) -> Void)?`.
- `outlineViewSelectionDidChange` passes `!isReloading` as `userInitiated`.

`AppDelegate` wires it as:

```swift
sidebar.onSelect = { [weak self] s, userInitiated in
    self?.select(s, focusTerminal: userInitiated)
}
```

The other six `select(...)` call sites (initial load, eviction, new worktree,
archive, external `focus(worktreeID:)`) are all explicit user actions and keep
the `focusTerminal: true` default.

## Call-site inventory

| Site | Context | `focusTerminal` |
|------|---------|-----------------|
| `sidebar.onSelect` | click **or** programmatic reload | `userInitiated` (`!isReloading`) |
| initial load (`select(displayWorktree(...))`) | app launch | `true` (default) |
| eviction fallback (`select(allDisplayWorktrees().first)`) | user removed a repo | `true` |
| `newWorktree` (`select(s)`) | user created a worktree | `true` |
| `archive` (`select(...first)`) | user archived a worktree | `true` |
| `focus(worktreeID:)` (`select(wt)`) | external activation (notification/hook) | `true` |

## Testing

This is pure AppKit first-responder wiring — no CodaCore model logic, so no new
unit tests. Verify by `swift build` (full Xcode `DEVELOPER_DIR`) then manually:

1. Click a **different** worktree → its terminal has focus; typing goes to it.
2. Click into the sidebar, then re-click the **already-active** worktree → focus
   returns to its terminal.
3. Trigger a branch/HEAD change (or wait for a background poll) while focused in
   another view (e.g. the diff pane) → focus is **not** stolen into the terminal.

## Out of scope

- No change to `WorktreeBar` (branch label is display-only).
- No change to CodaCore.
- No change to tab-switch focus (`activateSurface`), which already works.
