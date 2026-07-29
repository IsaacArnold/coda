# Sidebar Hover Highlight Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Paint a faint neutral wash behind whichever left-sidebar row the pointer is over, in the same rounded-rect geometry as the existing selection fill, suppressed on the selected row.

**Architecture:** A pure `SidebarHoverState` value type in `CodaCore` owns the "which row is hovered / which rows need redrawing" bookkeeping so it can be unit-tested without AppKit. `SidebarController` feeds it from a single `NSTrackingArea` installed on the outline view (row views are recycled, so per-row tracking areas would be fragile), then pushes `isHovered` onto just the affected row views. `FocusHighlightRowView` draws the wash in `drawBackground(in:)`, leaving the existing `drawSelection(in:)` accent fill untouched.

**Tech Stack:** Swift 5/6, SwiftPM, AppKit (`NSOutlineView`, `NSTableRowView`, `NSTrackingArea`), XCTest. Two targets: `CodaCore` (pure, never imports AppKit) and `Coda` (the AppKit shell).

**Spec:** `docs/superpowers/specs/2026-07-29-sidebar-hover-highlight-design.md`

## Global Constraints

- **Branch:** work happens on `feat/sidebar-hover-highlight`, which already exists and already contains the spec commit. Do not branch again; do not commit to `main`.
- **macOS floor is 13.0** (`MIN_MACOS="13.0"` in `scripts/make-app.sh`). No API newer than macOS 13.
- **`CodaCore` must never import AppKit.** It is the pure layer; only `Foundation`. Anything touching `NSColor`/`NSView` belongs in the `Coda` target.
- **Tests run with the full Xcode toolchain and a separate build path.** The default `xcode-select -p` is CommandLineTools, which has no XCTest module:
  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest
  ```
  Never share `.build` between `swift build` and `swift test` — the two toolchains are different Swift versions and the modules are incompatible.
- **Plain `swift build`** (no `DEVELOPER_DIR` override) is the compile check for the `Coda` target.
- **Hover is purely visual.** It must never change selection, scroll the outline, move first responder, or call `reloadData()`. Focus normally lives in the terminal, not the sidebar.
- **The alpha values are 6% in light appearance and 10% in dark.** These are starting values; nudging them during the live-verify task is expected and needs no further approval.
- **Do not modify `drawSelection(in:)`** on `FocusHighlightRowView`. The focused-worktree accent fill is existing, tuned behaviour.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/CodaCore/SidebarHoverState.swift` | **New.** Pure hovered-row bookkeeping: which row is hovered, which row indices need redrawing after a change. |
| `Tests/CodaCoreTests/SidebarHoverStateTests.swift` | **New.** Unit tests for the above. |
| `Sources/Coda/SidebarController.swift` | **Modify.** `FocusHighlightRowView` gains `isHovered` + a `drawBackground(in:)` override. `SidebarController` gains the tracking area, the mouse handlers, the scroll/reload recompute, and the hover-state wiring. |

`SidebarController.swift` is ~1070 lines and does a lot, but it is the established home for everything sidebar-chrome-related (accent pushing, theme restyle, identity colours all live there as small focused methods). This change adds ~60 lines in the same style. No split is warranted.

---

### Task 1: `SidebarHoverState` — pure hover bookkeeping

The testable core. Tracks the hovered row index and reports which rows changed appearance, so the controller can repaint exactly those rows instead of reloading.

**Files:**
- Create: `Sources/CodaCore/SidebarHoverState.swift`
- Test: `Tests/CodaCoreTests/SidebarHoverStateTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public struct SidebarHoverState: Equatable`
  - `public init()`
  - `public private(set) var hoveredRow: Int?`
  - `public mutating func update(to row: Int?) -> [Int]` — moves hover to `row` (`nil` means "no row hovered") and returns the row indices whose highlight changed and therefore need redrawing. Empty when nothing moved. When hover moves between two rows, the vacated row comes first, then the entered row.

- [x] **Step 1: Write the failing tests**

Create `Tests/CodaCoreTests/SidebarHoverStateTests.swift`:

```swift
import XCTest
@testable import CodaCore

final class SidebarHoverStateTests: XCTestCase {
    func testStartsWithNoHoveredRow() {
        let state = SidebarHoverState()
        XCTAssertNil(state.hoveredRow)
    }

    func testEnteringARowFromNothingRedrawsThatRow() {
        var state = SidebarHoverState()
        XCTAssertEqual(state.update(to: 3), [3])
        XCTAssertEqual(state.hoveredRow, 3)
    }

    func testMovingBetweenRowsRedrawsVacatedThenEntered() {
        // Both rows change appearance: one loses the wash, one gains it. Order is
        // vacated-first so a caller repainting in sequence never leaves two rows lit.
        var state = SidebarHoverState()
        _ = state.update(to: 3)
        XCTAssertEqual(state.update(to: 4), [3, 4])
        XCTAssertEqual(state.hoveredRow, 4)
    }

    func testReportingTheSameRowRedrawsNothing() {
        // The tracking area fires mouseMoved continuously while the pointer sits on one
        // row; re-reporting it must not churn needsDisplay every event.
        var state = SidebarHoverState()
        _ = state.update(to: 3)
        XCTAssertEqual(state.update(to: 3), [])
        XCTAssertEqual(state.hoveredRow, 3)
    }

    func testLeavingRedrawsOnlyTheVacatedRow() {
        var state = SidebarHoverState()
        _ = state.update(to: 3)
        XCTAssertEqual(state.update(to: nil), [3])
        XCTAssertNil(state.hoveredRow)
    }

    func testLeavingWhenNothingWasHoveredRedrawsNothing() {
        // mouseExited can arrive with no prior hover (e.g. the pointer crossed a gap).
        var state = SidebarHoverState()
        XCTAssertEqual(state.update(to: nil), [])
        XCTAssertNil(state.hoveredRow)
    }
}
```

- [x] **Step 2: Run the tests to verify they fail**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter SidebarHoverStateTests
```

Expected: FAIL to compile with `cannot find 'SidebarHoverState' in scope`.

- [x] **Step 3: Write the implementation**

Create `Sources/CodaCore/SidebarHoverState.swift`:

```swift
import Foundation

/// Tracks which sidebar row the pointer is over. Pure bookkeeping — no AppKit — so the
/// hover logic is unit-testable away from the mouse-tracking plumbing that drives it.
///
/// Callers report the row under the pointer (`nil` = none) and get back the rows whose
/// highlight changed, so only those rows are repainted. Deliberately NOT a reload: the
/// sidebar's selection and the terminal's focus must be untouched by mere hovering.
public struct SidebarHoverState: Equatable {
    /// The row currently under the pointer, or nil when the pointer is elsewhere.
    public private(set) var hoveredRow: Int?

    public init() {}

    /// Move hover to `row` (nil for "no row"). Returns the row indices whose highlight
    /// changed and therefore need redrawing — empty when hover didn't actually move.
    /// On a move between rows the vacated row is returned first, then the entered one.
    public mutating func update(to row: Int?) -> [Int] {
        guard row != hoveredRow else { return [] }
        let vacated = hoveredRow
        hoveredRow = row
        return [vacated, row].compactMap { $0 }
    }
}
```

- [x] **Step 4: Run the tests to verify they pass**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter SidebarHoverStateTests
```

Expected: PASS, 6 tests.

- [x] **Step 5: Run the whole suite to check nothing regressed**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest
```

Expected: PASS. The suite was 528 tests before this change, so expect 534.

- [x] **Step 6: Commit**

```bash
git add Sources/CodaCore/SidebarHoverState.swift Tests/CodaCoreTests/SidebarHoverStateTests.swift
git commit -m "feat(sidebar): add SidebarHoverState hover bookkeeping

Pure value type tracking the hovered row and reporting which rows need
repainting on a change, so hover never goes near reloadData (which would
drop the outline selection).

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Draw the wash and wire up pointer tracking

Makes hover actually visible. After this task, moving the pointer over the sidebar highlights rows.

**Files:**
- Modify: `Sources/Coda/SidebarController.swift` — `FocusHighlightRowView` (currently lines 108–132), `loadView()` (currently lines 272–294), `outlineView(_:rowViewForItem:)` (currently lines 772–778)

**Interfaces:**
- Consumes: `SidebarHoverState` from Task 1 — `init()`, `hoveredRow: Int?`, `mutating func update(to: Int?) -> [Int]`.
- Produces:
  - `FocusHighlightRowView.isHovered: Bool` — set by the controller; drives the wash.
  - `SidebarController.updateHover(to row: Int?)` — private; the single funnel every hover trigger goes through.
  - `SidebarController.hoveredRow` — private read access used by `rowViewForItem` to keep recycled row views consistent.

- [x] **Step 1: Add the hover wash colour**

`CodaCore` can't hold this (it's an `NSColor`), and it's sidebar-local, so put it as a private static on the row view. Add just above `FocusHighlightRowView`'s existing `accentColor` property (currently line 110):

```swift
    /// The hover wash: a neutral fill, deliberately NOT the accent. The accent means
    /// "this is the active worktree"; reusing it for hover would put two accent-tinted
    /// rows on screen at once and dilute that meaning. Dark mode needs more alpha than
    /// light for the same perceived weight over the darker sidebar.
    private static let hoverWash = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor.labelColor.withAlphaComponent(isDark ? 0.10 : 0.06)
    }
```

- [x] **Step 2: Add the `isHovered` property**

Add directly below `hoverWash`, still inside `FocusHighlightRowView`:

```swift
    /// True while the pointer is over this row. Set by `SidebarController.updateHover(to:)`;
    /// repaints only on an actual change so the continuous stream of mouseMoved events
    /// (and the 1s agent-state poll) don't churn `needsDisplay`.
    var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
```

- [x] **Step 3: Draw the wash**

Add below the existing `drawSelection(in:)` override (which ends at line 131), inside `FocusHighlightRowView`. Do not modify `drawSelection`:

```swift
    /// The hover wash, in the same rounded rect as the selection fill so hover and
    /// selection read as one system. No rim stroke — the selection's stroked edge is what
    /// makes it read as a defined panel, so omitting it keeps hover subordinate. Skipped
    /// on the selected row so its accent glass fill is never muddied; because that check
    /// lives here, selection always wins with no ordering subtlety between the two
    /// overrides.
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isHovered, !isSelected else { return }
        let rect = bounds.insetBy(dx: 4, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        Self.hoverWash.setFill()
        path.fill()
    }
```

- [x] **Step 4: Add the hover state and the update funnel to the controller**

Add next to the existing `accentFill` property (currently line 227), inside `SidebarController`:

```swift
    /// Which row the pointer is over, and the bookkeeping for repainting on a change.
    private var hoverState = SidebarHoverState()
    /// Read access for `rowViewForItem`, which must seed a recycled row view's hover flag.
    private var hoveredRow: Int? { hoverState.hoveredRow }

    /// The single funnel for every hover trigger (pointer motion, pointer exit, scroll,
    /// reload). Repaints only the rows whose highlight changed — never a reload, which
    /// would drop the outline's selection and erase the focused-worktree highlight.
    private func updateHover(to row: Int?) {
        // Only rows that are actually hoverable: a row index of -1 (below the last row,
        // or in the gap around one) means "no row".
        let target = (row ?? -1) >= 0 ? row : nil
        for changed in hoverState.update(to: target) {
            (outline.rowView(atRow: changed, makeIfNecessary: false)
                as? FocusHighlightRowView)?.isHovered = (changed == hoverState.hoveredRow)
        }
    }

    /// The outline row under the pointer right now, or nil if the pointer is outside the
    /// sidebar. Used by both the motion handler and the scroll/reload recompute, so all
    /// paths agree on how a screen point maps to a row.
    private func rowUnderPointer() -> Int? {
        guard let window = outline.window else { return nil }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let inOutline = outline.convert(inWindow, from: nil)
        guard outline.visibleRect.contains(inOutline) else { return nil }
        let row = outline.row(at: inOutline)
        return row >= 0 ? row : nil
    }
```

- [x] **Step 5: Install the tracking area**

Add to `loadView()`, just before `scroll.documentView = outline` (currently line 289):

```swift
        // One tracking area on the outline, not one per row: row views are recycled by
        // `makeView(withIdentifier:)` and their frames shift as rows are inserted, removed
        // and re-measured, so per-row areas would need tearing down and re-adding at
        // exactly the right moments. `.inVisibleRect` has AppKit maintain the rect as the
        // outline resizes and scrolls, so this is installed once and never rebuilt.
        // `.mouseMoved` in a tracking area delivers motion to the owner without needing
        // `window.acceptsMouseMovedEvents`. `.activeInActiveApp` means the area goes
        // inactive when the app deactivates, which fires mouseExited and clears the wash.
        outline.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self))
```

- [x] **Step 6: Add the mouse handlers**

`NSViewController` is an `NSResponder`, so it can be a tracking-area owner directly. Add these right after `loadView()` (i.e. before the `clickedRepoID()` helper at line 297):

```swift
    // MARK: - Hover
    //
    // Motion and exit come from the tracking area installed in `loadView()`, whose owner
    // is this controller. These are the only mouse events the sidebar handles — hover is
    // purely visual and must never select, scroll, or take first responder.

    override func mouseMoved(with event: NSEvent) {
        updateHover(to: rowUnderPointer())
    }

    override func mouseExited(with event: NSEvent) {
        updateHover(to: nil)
    }
```

- [x] **Step 7: Keep recycled row views consistent**

`outlineView(_:rowViewForItem:)` vends recycled `FocusHighlightRowView`s, so a view that was hovered can come back for a different row with a stale `isHovered == true`. Seed the flag the same way `accentColor` is already seeded. Replace the body of that method (currently lines 772–778) with:

```swift
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("focusRow")
        let row = (outline.makeView(withIdentifier: id, owner: self) as? FocusHighlightRowView)
            ?? { let r = FocusHighlightRowView(); r.identifier = id; return r }()
        row.accentColor = accentFill
        // Row views are recycled, so a previously-hovered instance must not arrive at a
        // different row still lit. Seed from the live hover state.
        let index = outline.row(forItem: item)
        row.isHovered = (index >= 0 && index == hoveredRow)
        return row
    }
```

- [x] **Step 8: Build**

```bash
swift build
```

Expected: builds clean, no warnings from the new code. If SourceKit/your editor reports phantom "cannot find type" errors across the Coda↔CodaCore boundary, ignore them — `swift build` is the authority.

- [x] **Step 9: Run the suite**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest
```

Expected: PASS, 534 tests. No test covers the AppKit drawing; this is a regression check.

- [x] **Step 10: Live-check the basic effect**

```bash
scripts/make-app.sh && open dist/Coda.app
```

Confirm, with at least one repo and one worktree in the sidebar:
1. Hovering a worktree row shows the faint wash, with the same footprint as the selection fill.
2. Hovering a repo header and a section header shows it too.
3. Hovering the selected worktree leaves its lavender fill unchanged.
4. Moving the pointer out of the sidebar clears the wash.

If the wash is invisible or too heavy, adjust the two alpha values in `hoverWash` and rebuild. Do not proceed until all four hold.

- [x] **Step 11: Commit**

```bash
git add Sources/Coda/SidebarController.swift
git commit -m "feat(sidebar): hover wash on sidebar rows

A faint neutral fill behind the row under the pointer, in the same
rounded rect as the selection fill and skipped on the selected row so
its accent glass fill stays unmuddied.

One tracking area on the outline rather than per row view: row views are
recycled and reflow, so per-row areas would need re-adding at exactly
the right moments. rowViewForItem reseeds isHovered for the same reason.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Keep hover correct when rows move under a still pointer

Scrolling and reordering both slide rows under a stationary pointer. Neither produces a `mouseMoved`, so without this the wash sticks to a row that is no longer under the cursor — the most obviously-broken failure mode of the feature.

**Files:**
- Modify: `Sources/Coda/SidebarController.swift` — `loadView()`, plus the end of `reload(rootItems:selectedWorktreeID:selectedRepoID:)` (currently lines 459–507)

**Interfaces:**
- Consumes: `updateHover(to:)` and `rowUnderPointer()` from Task 2.
- Produces: nothing consumed by later tasks.

- [x] **Step 1: Observe the clip view's bounds changes**

`NSScrollView` scrolling moves its clip view's bounds. Add to `loadView()`, immediately after the `scroll.documentView = outline` line and before `scroll.hasVerticalScroller = true`:

```swift
        // Scrolling with the pointer held still produces no mouseMoved, so the wash would
        // stay on a row that has slid out from under the cursor. Recompute from the
        // pointer's actual position whenever the clip view scrolls.
        // `postsBoundsChangedNotifications` is true by default, but set it explicitly so
        // this doesn't silently break if that ever changes.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView)
```

- [x] **Step 2: Add the notification handler**

Add directly below the `mouseExited(with:)` handler added in Task 2:

```swift
    /// The sidebar scrolled. The pointer may not have moved, but a different row is now
    /// under it.
    @objc private func clipViewBoundsChanged() {
        updateHover(to: rowUnderPointer())
    }
```

- [x] **Step 3: Recompute after a reload**

A reorder, a new worktree, or a collapse can put a different row under a stationary pointer. `reload(rootItems:...)` already defers work to the next runloop tick to let the outline settle; hook the recompute onto the same pattern. Add as the last statement of `reload(rootItems:selectedWorktreeID:selectedRepoID:)`, after the closing brace of the `if let selectedItem { … } else { … }` chain (currently line 506):

```swift
        // Rows may have shifted under a stationary pointer. Deferred so the outline has
        // finished expanding/selecting and `row(at:)` reflects the settled layout.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateHover(to: self.rowUnderPointer())
        }
```

- [x] **Step 4: Build**

```bash
swift build
```

Expected: builds clean.

- [x] **Step 5: Run the suite**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest
```

Expected: PASS, 534 tests.

- [x] **Step 6: Live-check the moving-rows cases**

```bash
scripts/make-app.sh && open dist/Coda.app
```

You need enough repos/worktrees for the sidebar to scroll — collapse nothing, and add worktrees if necessary.

1. Put the pointer over a row mid-list, then scroll with the trackpad *without moving the pointer*. The wash must follow whichever row is now under the cursor, and must never appear on two rows at once.
2. Scroll so the pointer ends up past the last row. The wash must clear.
3. Collapse and expand a section with the pointer resting over a row below it. The wash must land on the row that is now under the pointer.

- [x] **Step 7: Commit**

```bash
git add Sources/Coda/SidebarController.swift
git commit -m "fix(sidebar): recompute hover when rows move under a still pointer

Scrolling and reloading slide rows under a stationary cursor without
producing a mouseMoved, which would leave the wash on the wrong row.
Observe the clip view's bounds changes and recompute after reload.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Full live-verify sweep

The spec's verification list, run end to end on a real build. This sidebar's genuine bugs have all surfaced here rather than in tests — programmatic selection not applying, background reloads dropping state — so this task is not optional polish.

**Files:**
- Modify (only if a check fails): `Sources/Coda/SidebarController.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–3.
- Produces: nothing.

- [x] **Step 1: Build and launch a fresh app**

```bash
scripts/make-app.sh && open dist/Coda.app
```

- [x] **Step 2: Work the checklist**

Record the result of each. Every one must hold:

1. **All three row types.** Worktree, repo header, section header each show the wash, with the selection's footprint.
2. **Selected row untouched.** Hovering the selected worktree leaves its lavender glass fill exactly as before — no darkening, no rim change.
3. **Scroll under a still pointer.** The wash follows the row now under the cursor (re-check from Task 3; it is the most fragile behaviour).
4. **No flicker under the poll.** Rest the pointer on a row for ~30s with an agent running, so the 1s agent-state poll fires `reloadData(forRowIndexes:)` repeatedly. The wash must stay steady — no blinking.
5. **Click still works.** Clicking a hovered worktree selects it and focuses its terminal, as before. Clicking a section header still toggles collapse.
6. **Clears on leave and on deactivate.** Move the pointer out of the sidebar → wash clears. Switch to another app with the pointer resting on a sidebar row → wash clears.
7. **Both appearances, and a non-default accent.** Toggle System Settings → Appearance between Light and Dark; then set a non-default accent in Coda's Settings → Appearance. The wash must be clearly visible but clearly weaker than the selection in all four combinations.

- [x] **Step 3: Tune if needed**

If the wash is too subtle or too strong in either appearance, adjust the alphas in `FocusHighlightRowView.hoverWash` and repeat the relevant checks. If a check fails structurally (not just visually), fix it, rebuild, and re-run the whole checklist.

- [x] **Step 4: Commit any tuning**

Skip if nothing changed.

```bash
git add Sources/Coda/SidebarController.swift
git commit -m "style(sidebar): tune hover wash alpha after live verification

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

- [x] **Step 5: Final full-suite run and report**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest
```

Expected: PASS, 534 tests. Report the actual count and the checklist results — including anything that needed tuning — rather than asserting success generically.

---

## Notes for the implementer

- **`swift build` is the authority on compile errors.** SourceKit routinely reports phantom "cannot find type / no member / extra argument" errors for edits spanning the `Coda`↔`CodaCore` boundary. Ignore the editor; trust the build.
- **Don't reach for `reloadData()`** to make hover appear. A full reload silently drops the outline's selection (verified previously: `selectedRow` goes 1 → -1), which erases the focused-worktree highlight. Every hover path repaints specific row views instead.
- **`enumerateAvailableRowViews`** is the existing pattern for pushing state onto all visible row views (see `setAccentColor(_:)`). Hover deliberately uses targeted `rowView(atRow:makeIfNecessary:false)` calls instead, since only one or two rows change.
- **Nothing in this change is user-configurable.** No Settings entry, no preference key, no persistence.
