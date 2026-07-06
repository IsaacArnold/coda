# UI Polish: Sidebar Figure, Diff-Pane Path, Identity-Color Inheritance, Header Figure — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix four GUI issues — the sidebar `+N −M` figure clipping when narrow, the diff-pane file path losing its filename, tab/identity colors not inheriting the repo color, and a redundant `+N −M` figure in the identity header.

**Architecture:** Three of the four fixes are pure AppKit view-layer changes (layout priorities, line-break mode + tooltip, deleting a label). The identity-color inheritance introduces one pure, unit-tested Core helper (`identityBaseColor`) that resolves `worktree → repo`; the per-surface (tab) override still layers on top via the existing `Surface.effectiveColor(worktreeColor:)`, yielding the full chain `surface override → worktree → repo → default`. All four identity call sites in `AppDelegate` route through the new helper.

**Tech Stack:** Swift, AppKit, Swift Package Manager, XCTest. macOS app split into `CodaCore` (pure, testable) and `Coda` (AppKit app).

## Global Constraints

- **Build (release/compile check):** `DEVELOPER_DIR=$(xcode-select -p) swift build` — uses CommandLineTools (Swift 6.3.2).
- **Tests:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest` — the full Xcode toolchain is required (CommandLineTools has no XCTest); a **separate `--build-path`** avoids a 6.3.2-vs-6.2.3 module clash with the release build.
- **Do not share `.build` between the two toolchains.** Compile checks use the default `.build`; tests use `.build-xctest`.
- Keyboard-shortcut notation in any prose/commits: space out modifiers (`Ctrl + ⌘ + D`).
- Trust `swift build`, not SourceKit's live cross-module diagnostics (known to emit phantom errors for Coda↔CodaCore edits).
- Every commit message ends with the co-author trailer:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- The per-surface override (`Surface.colorOverride`) and per-worktree override (`Worktree.color`) must remain user-settable and must win over the repo fallback. This plan only changes the *default* when a worktree has no color but its repo does.

---

## Task 1: Core — `identityBaseColor` worktree→repo resolution (unit-tested)

Introduce the one piece of real logic behind issue 3 as a pure Core function so it can be
test-driven. AppKit call sites (Task 5) consume it.

**Files:**
- Create: `Sources/CodaCore/IdentityColor.swift`
- Test: `Tests/CodaCoreTests/IdentityColorTests.swift`

**Interfaces:**
- Consumes: `RGB` (existing, `Sources/CodaCore/RGB.swift`) — has `init?(hex: String)` and `var hexString: String`.
- Produces: `public func identityBaseColor(worktreeColorHex: String?, repoColorHex: String?) -> RGB?`
  — returns the worktree's own color if present and parseable, else the repo's color if
  present and parseable, else `nil`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CodaCoreTests/IdentityColorTests.swift`:

```swift
import XCTest
@testable import CodaCore

final class IdentityColorTests: XCTestCase {
    func testWorktreeColorWinsOverRepo() {
        let result = identityBaseColor(worktreeColorHex: "#112233", repoColorHex: "#445566")
        XCTAssertEqual(result, RGB(hex: "#112233"))
    }

    func testFallsBackToRepoWhenWorktreeNil() {
        let result = identityBaseColor(worktreeColorHex: nil, repoColorHex: "#445566")
        XCTAssertEqual(result, RGB(hex: "#445566"))
    }

    func testWorktreeColorWithoutRepoColor() {
        let result = identityBaseColor(worktreeColorHex: "#112233", repoColorHex: nil)
        XCTAssertEqual(result, RGB(hex: "#112233"))
    }

    func testNilWhenNeitherSet() {
        XCTAssertNil(identityBaseColor(worktreeColorHex: nil, repoColorHex: nil))
    }

    func testUnparseableWorktreeHexFallsBackToRepo() {
        // A malformed worktree hex must not swallow the repo fallback.
        let result = identityBaseColor(worktreeColorHex: "not-a-color", repoColorHex: "#445566")
        XCTAssertEqual(result, RGB(hex: "#445566"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter IdentityColorTests`
Expected: FAIL — `cannot find 'identityBaseColor' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Sources/CodaCore/IdentityColor.swift`:

```swift
import Foundation

/// Resolve the identity-color *base* for a worktree: its own color, falling back to its
/// repository's color. The per-surface (tab) override is layered on top separately via
/// `Surface.effectiveColor(worktreeColor:)`, so the full chain is
/// `surface override → worktree → repo → default`.
///
/// A malformed worktree hex falls through to the repo color rather than resolving to nil,
/// so a bad override never suppresses an otherwise-valid repo default.
public func identityBaseColor(worktreeColorHex: String?, repoColorHex: String?) -> RGB? {
    worktreeColorHex.flatMap(RGB.init(hex:)) ?? repoColorHex.flatMap(RGB.init(hex:))
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter IdentityColorTests`
Expected: PASS — 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodaCore/IdentityColor.swift Tests/CodaCoreTests/IdentityColorTests.swift
git commit -m "feat(core): identityBaseColor resolves worktree→repo identity fallback

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Sidebar +/− figure holds its width when the sidebar narrows (issue 1)

**Files:**
- Modify: `Sources/Coda/SidebarController.swift` — `makeWorktreeCell()` (~lines 400–456).

**Interfaces:**
- Consumes: nothing new.
- Produces: no API change; layout-priority change only.

- [ ] **Step 1: Raise the stats label's priorities and lower the title/subtitle resistance**

In `makeWorktreeCell()`, the title (`tf`), subtitle (`sub`), and stats (`stats`) labels are
configured before the constraint block. Add priority lines so the figure never compresses and
the title yields first.

After the existing `stats` configuration (the block that sets `stats.font`,
`stats.textColor`, `stats.alignment = .right`, `stats.isHidden = true`), add:

```swift
        // The +/- figure must never compress; when the sidebar narrows, the title and
        // subtitle truncate (they already use .byTruncatingTail) instead of the figure clipping.
        stats.setContentCompressionResistancePriority(.required, for: .horizontal)
        stats.setContentHuggingPriority(.required, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
```

- [ ] **Step 2: Compile**

Run: `DEVELOPER_DIR=$(xcode-select -p) swift build`
Expected: Build succeeds (a fresh build may take a few minutes).

- [ ] **Step 3: GUI verify**

Launch the app (see project `/run` skill or existing launch path), select a repo with a
worktree that shows a `+N −M` figure, and drag the sidebar divider narrower. Confirm the
`+N −M` figure stays fully visible and the worktree **title** truncates with an ellipsis
instead. (No automated test — this is a layout-priority change with no Core surface.)

- [ ] **Step 4: Commit**

```bash
git add Sources/Coda/SidebarController.swift
git commit -m "fix(app): sidebar +/- figure holds width, title truncates first

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Diff-pane path tail-truncates and shows a full-path tooltip (issue 2)

**Files:**
- Modify: `Sources/Coda/DiffPaneView.swift` — `makeFileCell()` (~line 267) and the file-row
  branch of `outlineView(_:viewFor:item:)` (~lines 376–391).

**Interfaces:**
- Consumes: `DiffFile.path`, `DiffFile.oldPath` (existing, already used to build the label).
- Produces: no API change.

- [ ] **Step 1: Change the path label's truncation to head**

In `makeFileCell()`, find:

```swift
        path.lineBreakMode = .byTruncatingMiddle
```

Replace with:

```swift
        // Truncate the FRONT of the path so the filename (at the end) always stays visible;
        // the full path is available via the row's tooltip (set in viewFor).
        path.lineBreakMode = .byTruncatingHead
```

- [ ] **Step 2: Set the full-path tooltip in the file-row branch**

In `outlineView(_:viewFor:item:)`, the file-row branch builds the label string like this:

```swift
            cell.pathLabel.stringValue = file.oldPath.map { "\($0) → \(file.path)" } ?? file.path
```

Immediately after that line, add:

```swift
            // Full path on hover — the only way to read a deeply-nested path on a narrow pane.
            cell.toolTip = cell.pathLabel.stringValue
```

- [ ] **Step 3: Compile**

Run: `DEVELOPER_DIR=$(xcode-select -p) swift build`
Expected: Build succeeds.

- [ ] **Step 4: GUI verify**

Open the diff pane (`Ctrl + ⌘ + D`) on a worktree with a deeply-nested changed file. Narrow
the pane and confirm the **filename** stays visible (front of the path drops to `…`), and
hovering the row shows a tooltip with the complete path (rename rows show `old → new`).

- [ ] **Step 5: Commit**

```bash
git add Sources/Coda/DiffPaneView.swift
git commit -m "fix(app): diff-pane path tail-truncates + full-path tooltip

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Remove the +N −M figure from the identity header (issue 4)

**Files:**
- Modify: `Sources/Coda/WorktreeBar.swift` — delete `statsLabel` and its wiring; drop the
  `diffStats` parameter from `update(...)`.
- Modify: `Sources/Coda/AppDelegate.swift` — remove the `diffStats:` argument at the
  `worktreeBar.update(...)` call site (~line 896).

**Interfaces:**
- Consumes: nothing new.
- Produces: `WorktreeBar.update(title:branch:colorHex:agentState:)` — the `diffStats`
  parameter is removed. (Task 5 further changes `colorHex` computation at the same call site,
  but the signature after this task is `update(title:branch:colorHex:agentState:)`.)

- [ ] **Step 1: Delete the stats label from `WorktreeBar`**

In `Sources/Coda/WorktreeBar.swift`:

1. Delete the property and its doc comment:

```swift
    /// Trailing "+N −M" diff-stats figure (Task 10) for the active worktree — mirrors
    /// the sidebar's per-row figure. Hidden when there's no diff.
    private let statsLabel = NSTextField(labelWithString: "")
```

2. Delete its font/hidden setup in `init`:

```swift
        statsLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        statsLabel.isHidden = true
```

3. Remove `statsLabel` from the stack view. Change:

```swift
        let stack = NSStackView(views: [titleLabel, branchLabel, NSView(), statsLabel, badge])
```

to (keep the flexible spacer `NSView()` so the badge stays right-aligned):

```swift
        let stack = NSStackView(views: [titleLabel, branchLabel, NSView(), badge])
```

- [ ] **Step 2: Drop the `diffStats` parameter from `update(...)`**

Change the signature:

```swift
    func update(title: String?, branch: String?, colorHex: String?, agentState: AgentState,
                diffStats: DiffStats? = nil) {
```

to:

```swift
    func update(title: String?, branch: String?, colorHex: String?, agentState: AgentState) {
```

Then delete the stats block from the body:

```swift
        if let s = diffStats, !s.isEmpty {
            statsLabel.stringValue = "+\(s.insertions) −\(s.deletions)"
            statsLabel.textColor = textColor.withAlphaComponent(0.9)
            statsLabel.isHidden = false
        } else {
            statsLabel.isHidden = true
        }
```

- [ ] **Step 3: Update the call site in `AppDelegate`**

In `refreshChromeForActiveSurface()` (~line 893), change:

```swift
        worktreeBar.update(title: wt.title, branch: wt.branch,
                           colorHex: effective?.hexString,
                           agentState: agentStates[wt.id] ?? .idle,
                           diffStats: diffStatsByWorktree[wt.id])
```

to:

```swift
        worktreeBar.update(title: wt.title, branch: wt.branch,
                           colorHex: effective?.hexString,
                           agentState: agentStates[wt.id] ?? .idle)
```

(The two `worktreeBar.update(title: nil, ...)` early-return calls at ~lines 671 and 887 pass
no `diffStats`, so they need no change.)

- [ ] **Step 4: Compile**

Run: `DEVELOPER_DIR=$(xcode-select -p) swift build`
Expected: Build succeeds with no unused-variable or missing-argument errors.

- [ ] **Step 5: GUI verify**

Launch, select a worktree with changes. Confirm the identity header bar above the terminal no
longer shows `+N −M`, the title/branch/badge still render, and the badge stays right-aligned.
Confirm the sidebar still shows its green/red `+N −M` figure.

- [ ] **Step 6: Commit**

```bash
git add Sources/Coda/WorktreeBar.swift Sources/Coda/AppDelegate.swift
git commit -m "fix(app): remove redundant +/- figure from identity header

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Route the identity chain through the repo fallback (issue 3)

Wire `identityBaseColor` (Task 1) into all four identity call sites so an uncolored worktree
inherits its repo's color for the tab tint, identity bar, focused-pane border, and sidebar
branch glyph. Per-surface and per-worktree overrides still win.

**Files:**
- Modify: `Sources/Coda/AppDelegate.swift` — add `identityBase(for:)` helper; update
  `setWorktreeColor` (~line 392), the split-setup site (~line 736), `refreshTabBar` (~line 786),
  and `refreshChromeForActiveSurface` (~line 890).
- Modify: `Sources/Coda/SidebarController.swift` — give `WorktreeNode` a repo color; fall back
  to it in the worktree cell.

**Interfaces:**
- Consumes: `identityBaseColor(worktreeColorHex:repoColorHex:) -> RGB?` (Task 1);
  `Surface.effectiveColor(worktreeColor: RGB?) -> RGB?` (existing);
  `store.state.repositories` / `store.state.worktrees` (existing `[Repository]` / `[Worktree]`).
- Produces:
  - `AppDelegate.identityBase(for: Worktree) -> RGB?` (private).
  - `WorktreeNode(_ worktree: Worktree, repoColorHex: String?)` — the node initializer gains a
    second argument.
  - `WorktreeCellView.applyIdentityColor(_ identity: NSColor?, repoColor: NSColor?, glyphTint: NSColor?)`
    — a `repoColor` fallback is inserted between `identity` and `glyphTint`.

- [ ] **Step 1: Add the `identityBase(for:)` helper to `AppDelegate`**

Place it next to `refreshChromeForActiveSurface()` (just before line ~884):

```swift
    /// The identity-color base for a worktree — its own color, else its repo's — routed
    /// through Core's `identityBaseColor` so the fallback logic is unit-tested. Per-surface
    /// (tab) overrides layer on top via `Surface.effectiveColor(worktreeColor:)`.
    private func identityBase(for wt: Worktree) -> RGB? {
        let repoHex = store.state.repositories.first { $0.id == wt.repoID }?.color
        return identityBaseColor(worktreeColorHex: wt.color, repoColorHex: repoHex)
    }
```

- [ ] **Step 2: Use the repo-aware base in `refreshChromeForActiveSurface`**

Change (~line 890):

```swift
        let worktreeColor = wt.color.flatMap { RGB(hex: $0) }
        let active = surfaces.existingSurfaces(for: wt.id)?.activeSurface
        let effective = active?.effectiveColor(worktreeColor: worktreeColor) ?? worktreeColor
```

to:

```swift
        let base = identityBase(for: wt)
        let active = surfaces.existingSurfaces(for: wt.id)?.activeSurface
        let effective = active?.effectiveColor(worktreeColor: base) ?? base
```

(The `worktreeBar.update(...)` call below already uses `effective?.hexString`, and
`sidebar.setIdentityOverride(effective?.nsColor, ...)` / `currentSurface?.identityColor` also
use `effective` — all now repo-aware with no further change here.)

- [ ] **Step 3: Use the repo-aware base for the tab tint in `refreshTabBar`**

Change (~line 786):

```swift
        let worktreeColor = selectedWorktree?.color.flatMap { RGB(hex: $0) }
```

to (resolve from the worktree actually being shown, with the repo fallback):

```swift
        let base = store.state.worktrees.first { $0.id == wtID }.flatMap { identityBase(for: $0) }
```

Then, in the `list.entries.enumerated().map { ... }` closure just below, change:

```swift
            let effective = entry.surface.effectiveColor(worktreeColor: worktreeColor)
```

to:

```swift
            let effective = entry.surface.effectiveColor(worktreeColor: base)
```

- [ ] **Step 4: Remove the redundant border override in `setWorktreeColor`**

At ~line 388–393 the block already calls `refreshChromeForActiveSurface()` (which now sets the
repo-aware `currentSurface?.identityColor`), then immediately overwrites it with the raw
worktree color — a redundant line that also drops any surface override. Delete line ~392:

```swift
                // Keep the focused-pane border tint in sync with the new color.
                currentSurface?.identityColor = (store.state.worktrees.first { $0.id == worktreeID }?.color).flatMap { NSColor(hex: $0) }
```

After deletion the block reads:

```swift
            if worktreeID == selectedWorktree?.id {
                selectedWorktree = store.state.worktrees.first { $0.id == worktreeID }
                refreshChromeForActiveSurface()
            }
```

- [ ] **Step 5: Route the split-setup border through the helper**

At ~line 736, change:

```swift
        split.identityColor = (selectedWorktree?.color).flatMap { NSColor(hex: $0) }
```

to:

```swift
        split.identityColor = selectedWorktree.flatMap { identityBase(for: $0) }?.nsColor
```

- [ ] **Step 6: Give `WorktreeNode` its repo color (SidebarController)**

In `Sources/Coda/SidebarController.swift`, change the `WorktreeNode` definition (~line 14):

```swift
private final class WorktreeNode: NSObject {
    let worktree: Worktree
    init(_ worktree: Worktree) { self.worktree = worktree }
}
```

to:

```swift
private final class WorktreeNode: NSObject {
    let worktree: Worktree
    /// The parent repo's identity color hex, so an uncolored worktree can fall back to it.
    let repoColorHex: String?
    init(_ worktree: Worktree, repoColorHex: String?) {
        self.worktree = worktree
        self.repoColorHex = repoColorHex
    }
}
```

- [ ] **Step 7: Pass the repo color when building nodes in `reload(sections:)`**

In `reload(sections:...)` (~line 215), change:

```swift
        repoNodes = sections.map { section in
            RepoNode(repository: section.repository,
                     children: section.worktrees.map(WorktreeNode.init))
        }
```

to:

```swift
        repoNodes = sections.map { section in
            RepoNode(repository: section.repository,
                     children: section.worktrees.map {
                         WorktreeNode($0, repoColorHex: section.repository.color)
                     })
        }
```

- [ ] **Step 8: Add the `repoColor` fallback to `applyIdentityColor`**

Change the method on `WorktreeCellView` (~line 70):

```swift
    func applyIdentityColor(_ identity: NSColor?, glyphTint: NSColor?) {
        imageView?.contentTintColor = identity ?? glyphTint ?? .secondaryLabelColor
    }
```

to:

```swift
    func applyIdentityColor(_ identity: NSColor?, repoColor: NSColor?, glyphTint: NSColor?) {
        imageView?.contentTintColor = identity ?? repoColor ?? glyphTint ?? .secondaryLabelColor
    }
```

- [ ] **Step 9: Pass the node's repo color at the call site**

In `outlineView(_:viewFor:item:)`, the worktree branch (~line 356) computes `identity` and
calls `applyIdentityColor`. Change:

```swift
            let identity = identityOverrides[wt.worktree.id]
                ?? wt.worktree.color.flatMap { NSColor(hex: $0) }
            cell.applyIdentityColor(identity, glyphTint: chrome?.color(.glyphTint).nsColor)
```

to:

```swift
            let identity = identityOverrides[wt.worktree.id]
                ?? wt.worktree.color.flatMap { NSColor(hex: $0) }
            cell.applyIdentityColor(identity,
                                    repoColor: wt.repoColorHex.flatMap { NSColor(hex: $0) },
                                    glyphTint: chrome?.color(.glyphTint).nsColor)
```

- [ ] **Step 10: Compile**

Run: `DEVELOPER_DIR=$(xcode-select -p) swift build`
Expected: Build succeeds.

- [ ] **Step 11: Full test run (guard the Core helper + no regressions)**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest`
Expected: All tests pass, including `IdentityColorTests`.

- [ ] **Step 12: GUI verify the whole chain**

1. Pick a repo, set a **repo color** (right-click the repo header → Set Color). Ensure it has a
   worktree with **no** color of its own.
2. Confirm the worktree's tabs, the identity bar above the terminal, the sidebar branch glyph,
   and the focused-pane border all now show the **repo color**.
3. Set a **worktree color** on that worktree → all four switch to the worktree color (worktree
   wins over repo).
4. Set a **per-tab color** (right-click a tab → Set Color) → that tab shows its own color while
   others still show the worktree color (tab override wins).
5. Remove all colors → everything returns to the default grey/neutral look.

- [ ] **Step 13: Commit**

```bash
git add Sources/Coda/AppDelegate.swift Sources/Coda/SidebarController.swift
git commit -m "feat(app): identity color inherits repo color across tabs/bar/glyph/border

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Issue 1 (sidebar figure) → Task 2. ✓
- Issue 2 (diff-pane path tail-truncate + tooltip) → Task 3. ✓
- Issue 3 (repo-color inheritance across whole chain: tabs, identity bar, sidebar glyph, pane
  border) → Task 1 (Core helper + tests) + Task 5 (all four sites + sidebar plumbing). ✓
- Issue 4 (remove header figure) → Task 4. ✓
- Spec "Verification" section: `swift build` + `swift test` green (Tasks steps) and per-issue
  GUI checks (each task's verify step). ✓
- Spec "Out of scope": no new settings, no change to how colors are set, no change to
  `effectiveColor`'s signature or the diff-stats pipeline — honored (Task 1 adds a new free
  function; `effectiveColor` is unchanged). ✓

**Placeholder scan:** No TBD/TODO/"add error handling"/"similar to Task N". Every code step
shows the exact before/after. ✓

**Type consistency:**
- `identityBaseColor(worktreeColorHex:repoColorHex:) -> RGB?` — defined Task 1, consumed Task 5
  (`identityBase(for:)`). ✓
- `identityBase(for: Worktree) -> RGB?` — defined Task 5 Step 1, used Steps 2/3/5. ✓
- `WorktreeNode(_:repoColorHex:)` — redefined Task 5 Step 6, constructed Step 7. ✓
- `applyIdentityColor(_:repoColor:glyphTint:)` — redefined Step 8, called Step 9. ✓
- `WorktreeBar.update(title:branch:colorHex:agentState:)` — `diffStats` removed in Task 4; the
  Task 5 edits to `refreshChromeForActiveSurface` touch only `colorHex`'s source, not the
  signature — consistent (Task 4 precedes Task 5 in file edits but both are on `main` before
  Task 5 GUI verify). ✓

**Ordering note:** Task 1 must precede Task 5 (helper dependency). Tasks 2, 3, 4 are
independent and may run in any order. Task 4 and Task 5 both edit `refreshChromeForActiveSurface`
in `AppDelegate.swift` at adjacent lines — if run out of order, re-anchor on the surrounding
`let effective` / `worktreeBar.update` lines rather than absolute line numbers.
