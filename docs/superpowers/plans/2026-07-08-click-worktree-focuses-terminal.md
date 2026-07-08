# Click Worktree/Branch Focuses Terminal — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Selecting a worktree in the sidebar moves keyboard focus to that worktree's terminal, so the user can type immediately without a second click.

**Architecture:** Add a `focusTerminal` flag to `AppDelegate.select(_:)` that calls `view(focus:)` on the resolved surface. Teach `SidebarController` to report whether a selection came from a real user click versus a programmatic reload, and pass that through as `focusTerminal` so background branch/HEAD reloads never steal focus.

**Tech Stack:** Swift, AppKit (`NSOutlineView`, first-responder), Swift Package Manager.

## Global Constraints

- Build with full Xcode `DEVELOPER_DIR` (CommandLineTools lacks XCTest and clashes on toolchain versions). Use a separate `--build-path` when running `swift test`.
- Follow existing file patterns; no CodaCore changes — this is Coda (AppKit) view wiring only.
- No change to `WorktreeBar` (branch label is display-only) or to `activateSurface` (tab-switch focus already works).

---

### Task 1: Focus the terminal on user-initiated worktree selection

The `SidebarController.onSelect` signature change and the `AppDelegate` call-site update must land together to compile, so this is one atomic task with one commit.

**Files:**
- Modify: `Sources/Coda/SidebarController.swift` (`onSelect` property ~line 95; `reload(...)` ~lines 218–240; `outlineViewSelectionDidChange` ~lines 402–407)
- Modify: `Sources/Coda/AppDelegate.swift` (`onSelect` wiring ~line 372; `select(_:)` ~lines 655–689)

**Interfaces:**
- Produces: `SidebarController.onSelect: ((Worktree?, _ userInitiated: Bool) -> Void)?`
- Produces: `AppDelegate.select(_ s: Worktree?, focusTerminal: Bool = true)` — the six existing direct callers rely on the `true` default and keep compiling unchanged.
- Consumes: existing `AppDelegate.view(focus: SplitSurface)` (`Sources/Coda/AppDelegate.swift:775`) and `currentSurface`.

- [ ] **Step 1: Add an `isReloading` guard flag to `SidebarController`**

Add the flag next to the other private state (near line 90, after `private var metrics = ...`):

```swift
    /// True only while `reload(...)` programmatically re-selects a row. Lets
    /// `outlineViewSelectionDidChange` tell a real user click from a reload so the
    /// app doesn't steal terminal focus on a background branch/HEAD refresh.
    private var isReloading = false
```

- [ ] **Step 2: Widen the `onSelect` signature**

Replace line ~95:

```swift
    var onSelect: ((Worktree?) -> Void)?
```

with:

```swift
    var onSelect: ((Worktree?, _ userInitiated: Bool) -> Void)?
```

- [ ] **Step 3: Set the flag around programmatic selection in `reload(...)`**

In `reload(sections:selectedWorktreeID:selectedRepoID:)`, wrap the selection block (the `if let selectedItem { ... }` at ~lines 233–239) so the flag is set while AppKit fires the selection notification:

```swift
        if let selectedItem {
            let row = outline.row(forItem: selectedItem)
            if row >= 0 {
                isReloading = true
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                isReloading = false
                outline.scrollRowToVisible(row)
            }
        }
```

- [ ] **Step 4: Pass `userInitiated` from the selection delegate**

Replace `outlineViewSelectionDidChange` (~lines 402–407):

```swift
    func outlineViewSelectionDidChange(_ notification: Notification) {
        let userInitiated = !isReloading
        switch outline.item(atRow: outline.selectedRow) {
        case let wt as WorktreeNode: onSelect?(wt.worktree, userInitiated)
        default: onSelect?(nil, userInitiated)   // a repo row (or nothing) clears the detail surface
        }
    }
```

- [ ] **Step 5: Update the `onSelect` wiring in `AppDelegate`**

Replace line ~372:

```swift
        sidebar.onSelect = { [weak self] s in self?.select(s) }
```

with:

```swift
        sidebar.onSelect = { [weak self] s, userInitiated in self?.select(s, focusTerminal: userInitiated) }
```

- [ ] **Step 6: Add `focusTerminal` to `select(_:)` and focus the surface**

Change the signature and add focus in both the idempotent early-return and the main path. Replace the opening of `select` (~lines 655–657):

```swift
    private func select(_ s: Worktree?) {
        guard shownWorktreeID != s?.id else { return }   // idempotent
        shownWorktreeID = s?.id
```

with:

```swift
    private func select(_ s: Worktree?, focusTerminal: Bool = true) {
        guard shownWorktreeID != s?.id else {
            // Already shown — honor an explicit click by returning focus to its terminal.
            if focusTerminal, let cur = currentSurface { view(focus: cur) }
            return
        }
        shownWorktreeID = s?.id
```

Then, at the end of `select`, focus the resolved surface just before the final `recomputeRollupsAndRefreshUI()` call (~line 688). Replace:

```swift
        // Force an immediate repaint from current agent state so the switched-to worktree's
        // badges (sidebar + notch + tabs) are correct instantly, rather than waiting for the
        // next hook event or the fallback poll. (Superset of refreshChrome+refreshTabBar.)
        recomputeRollupsAndRefreshUI()
    }
```

with:

```swift
        // Move keyboard focus into the switched-to worktree's terminal so the user can type
        // immediately. (createSurface already focuses on first open; this covers the common
        // case of unhiding an existing surface, and is a harmless no-op re-focus otherwise.)
        if focusTerminal, let cur = currentSurface { view(focus: cur) }

        // Force an immediate repaint from current agent state so the switched-to worktree's
        // badges (sidebar + notch + tabs) are correct instantly, rather than waiting for the
        // next hook event or the fallback poll. (Superset of refreshChrome+refreshTabBar.)
        recomputeRollupsAndRefreshUI()
    }
```

- [ ] **Step 7: Build**

Run (full Xcode toolchain required):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

Expected: `Build complete!` with no errors. (If a phantom cross-module diagnostic appears in an editor, trust `swift build`.)

- [ ] **Step 8: Manual verification**

Launch the app and confirm all three behaviors from the spec:

1. Click a **different** worktree in the sidebar → its terminal has keyboard focus; typing goes straight to it (no second click).
2. Click into the sidebar, then re-click the **already-active** worktree → focus returns to its terminal.
3. With focus in another view (e.g. the diff pane via `Ctrl + ⌘ + D`), trigger or wait for a branch/HEAD change (e.g. commit in that worktree) → focus is **not** yanked into the terminal.

- [ ] **Step 9: Commit**

```bash
git add Sources/Coda/SidebarController.swift Sources/Coda/AppDelegate.swift
git commit -m "feat(app): focus the terminal when selecting a worktree

Selecting a worktree now moves keyboard focus into its terminal so the user
can type immediately. A userInitiated flag from the sidebar distinguishes a
real click from a programmatic reload, so background branch/HEAD refreshes
don't steal focus.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Core `select(_:focusTerminal:)` + focus on switch and re-click → Steps 6, 1 (early-return). ✓
- Guard against background focus theft (`isReloading` + `userInitiated`) → Steps 1, 3, 4, 5. ✓
- Six other call sites keep `true` default → signature default in Step 6; no edits needed. ✓
- "Branch" == sidebar rows, no `WorktreeBar` change → Global Constraints. ✓
- Testing (build + 3 manual checks) → Steps 7, 8. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step shows full code. ✓

**Type consistency:** `onSelect: ((Worktree?, Bool) -> Void)?` (Step 2) matches the two call sites in Step 4 and the wiring in Step 5. `select(_:focusTerminal:)` (Step 6) matches the wiring in Step 5. `view(focus:)` and `currentSurface` are existing symbols. ✓

**Note on TDD:** This change is AppKit first-responder wiring with no pure-logic seam to unit-test (the `isReloading` flag only has meaning inside a live `NSOutlineView` selection cycle). Verification is `swift build` plus the three manual behavior checks in Step 8, matching the spec's testing section.
