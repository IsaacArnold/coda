# Phase 1.5 PR B — Splits / Panes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a surface tab be split into nested terminal panes (iTerm/tmux-style — split any pane right or down, arbitrarily nested), each its own PTY.

**Architecture:** A pure-Core `PaneTree<Leaf>` (binary split tree, `Leaf` = opaque terminal handle) owns split/close-with-collapse/focus logic; a pure `nearestPane(...)` geometric helper drives directional focus. The shell gets a `SplitSurface` container (`NSViewController`) that owns a `PaneTree<TerminalSurface>` and renders it as nested `NSSplitView`s. PR A's generic `WorktreeSurfaces<Handle>` lets us swap the surface Handle from `TerminalSurface` → `SplitSurface`; the AppDelegate's surface lifecycle then drives `SplitSurface`, walking its panes.

**Tech Stack:** Swift 6.2 (Xcode toolchain), SwiftPM, AppKit, SwiftTerm. Two modules: `ConductorCore` (pure, tested), `Conductor` (AppKit shell).

**Spec:** `docs/superpowers/specs/2026-06-26-conductor-splits-design.md`
**Builds on:** Phase 1.5 PR A (`phase1.5-surface-tabs`, PR #28) — this branch (`phase1.5-splits`) is stacked on it.

## Global Constraints

- **Toolchain prefix mandatory on every build/run/test:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Test: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. If you hit `module compiled with Swift 6.3.2 cannot be imported`, `rm -rf .build` and rebuild through the Xcode `DEVELOPER_DIR`.
- **`swift test` builds the WHOLE package** (incl. the `Conductor` app target) — the app must compile after every task. (Learned in PR A.)
- **Tests are XCTest** (`import XCTest`, `@testable import ConductorCore`, `final class … : XCTestCase`).
- **`ConductorCore` stays pure** — never import AppKit (or CoreGraphics). Geometry uses the Core `PaneRect` value type (plain `Double`s).
- **In-memory only** — no persistence/serialization of pane layout (consistent with PR A).
- **SourceKit false alarms:** the editor flags freshly-added types / `Bundle.module` / cross-file symbols as errors. `swift build` / `swift test` is the source of truth, NOT editor diagnostics.
- **Axis convention:** `SplitAxis.horizontal` = side-by-side panes (an `NSSplitView` with `isVertical = true`, vertical dividers); `SplitAxis.vertical` = stacked panes (`isVertical = false`). "Split right" (⌘D) → `.horizontal`; "split down" (⌘⇧D) → `.vertical`.
- **PaneRect convention:** top-left origin, y increases downward. `.up` = toward smaller y, `.down` = larger y. The shell flips NSView frames to this convention before calling `nearestPane`.

---

## File Structure

**Core (new):**
- `Sources/ConductorCore/PaneGeometry.swift` — `SplitAxis`, `PaneDirection`, `PaneRect`, `nearestPane(...)`.
- `Sources/ConductorCore/PaneTree.swift` — `PaneTree<Leaf>` + its `Node`.

**Core (modified):**
- `Sources/ConductorCore/Keybindings.swift` — repurpose `splitSurface` displayName + add `splitDown` + `focusPaneLeft/Right/Up/Down`.

**Core tests (new/extended):**
- `Tests/ConductorCoreTests/PaneGeometryTests.swift` (new)
- `Tests/ConductorCoreTests/PaneTreeTests.swift` (new)
- `Tests/ConductorCoreTests/KeybindingsTests.swift` (extend)

**Shell (new):**
- `Sources/Conductor/SplitSurface.swift` — the pane container (new surface Handle).

**Shell (modified):**
- `Sources/Conductor/ClickableTerminalView.swift` — add `onBecomeFirstResponder` hook.
- `Sources/Conductor/TerminalSurface.swift` — expose `onFocused` (forwards the hook).
- `Sources/Conductor/AppDelegate.swift` — Handle swap + split/focus actions + menu + pane-aware close + per-pane badge rollup + tab reflection.

---

## Task 1: Core — pane geometry + `nearestPane`

**Files:**
- Create: `Sources/ConductorCore/PaneGeometry.swift`
- Test: `Tests/ConductorCoreTests/PaneGeometryTests.swift`

**Interfaces:**
- Produces:
  - `enum SplitAxis: Equatable { case horizontal, vertical }`
  - `enum PaneDirection { case left, right, up, down }`
  - `struct PaneRect: Equatable { let id: String; let x, y, width, height: Double; init(id:x:y:width:height:) }`
  - `func nearestPane(from focusedID: String, direction: PaneDirection, frames: [PaneRect]) -> String?`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ConductorCoreTests/PaneGeometryTests.swift
import XCTest
@testable import ConductorCore

final class PaneGeometryTests: XCTestCase {
    // Layout (top-left origin, y down):
    //   A(0,0,100,100)  B(100,0,100,100)   ← A left of B
    //   C(0,100,100,100)                    ← C below A
    private let frames = [
        PaneRect(id: "A", x: 0, y: 0, width: 100, height: 100),
        PaneRect(id: "B", x: 100, y: 0, width: 100, height: 100),
        PaneRect(id: "C", x: 0, y: 100, width: 100, height: 100),
    ]

    func testRightOfAIsB() {
        XCTAssertEqual(nearestPane(from: "A", direction: .right, frames: frames), "B")
    }
    func testDownOfAIsC() {
        XCTAssertEqual(nearestPane(from: "A", direction: .down, frames: frames), "C")
    }
    func testLeftOfBIsA() {
        XCTAssertEqual(nearestPane(from: "B", direction: .left, frames: frames), "A")
    }
    func testUpOfCIsA() {
        XCTAssertEqual(nearestPane(from: "C", direction: .up, frames: frames), "A")
    }
    func testNothingToTheLeftOfAReturnsNil() {
        XCTAssertNil(nearestPane(from: "A", direction: .left, frames: frames))
    }
    func testUnknownFocusReturnsNil() {
        XCTAssertNil(nearestPane(from: "Z", direction: .right, frames: frames))
    }
    func testPicksNearestByCenterDistance() {
        // Two panes to the right; the closer one wins.
        let fs = [
            PaneRect(id: "A", x: 0, y: 0, width: 50, height: 50),
            PaneRect(id: "near", x: 60, y: 0, width: 50, height: 50),
            PaneRect(id: "far", x: 200, y: 0, width: 50, height: 50),
        ]
        XCTAssertEqual(nearestPane(from: "A", direction: .right, frames: fs), "near")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PaneGeometryTests`
Expected: FAIL — `Cannot find 'PaneRect' / 'nearestPane' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/ConductorCore/PaneGeometry.swift
import Foundation

/// A split's orientation. `.horizontal` lays panes side-by-side (vertical dividers);
/// `.vertical` stacks panes (horizontal dividers).
public enum SplitAxis: Equatable {
    case horizontal, vertical
}

/// Arrow-key focus directions. Coordinates use a top-left origin (y increases downward),
/// so `.up` is toward smaller y and `.down` toward larger y.
public enum PaneDirection {
    case left, right, up, down
}

/// A pane's on-screen rectangle, top-left origin. Pure value type — the shell converts
/// AppKit frames (bottom-left origin) into this convention before calling `nearestPane`.
public struct PaneRect: Equatable {
    public let id: String
    public let x, y, width, height: Double
    public init(id: String, x: Double, y: Double, width: Double, height: Double) {
        self.id = id; self.x = x; self.y = y; self.width = width; self.height = height
    }
    var centerX: Double { x + width / 2 }
    var centerY: Double { y + height / 2 }
}

/// The nearest pane to the focused one in the given direction, by center distance.
/// Returns nil if the focused id isn't in `frames` or nothing lies that way.
public func nearestPane(from focusedID: String, direction: PaneDirection,
                        frames: [PaneRect]) -> String? {
    guard let cur = frames.first(where: { $0.id == focusedID }) else { return nil }
    var best: (id: String, dist: Double)?
    for f in frames where f.id != focusedID {
        let inDirection: Bool
        switch direction {
        case .left:  inDirection = f.centerX < cur.centerX
        case .right: inDirection = f.centerX > cur.centerX
        case .up:    inDirection = f.centerY < cur.centerY
        case .down:  inDirection = f.centerY > cur.centerY
        }
        guard inDirection else { continue }
        let dx = f.centerX - cur.centerX, dy = f.centerY - cur.centerY
        let dist = dx * dx + dy * dy
        if best == nil || dist < best!.dist { best = (f.id, dist) }
    }
    return best?.id
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PaneGeometryTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ConductorCore/PaneGeometry.swift Tests/ConductorCoreTests/PaneGeometryTests.swift
git commit -m "feat(core): pane geometry + nearestPane directional navigation"
```

---

## Task 2: Core — `PaneTree<Leaf>`

**Files:**
- Create: `Sources/ConductorCore/PaneTree.swift`
- Test: `Tests/ConductorCoreTests/PaneTreeTests.swift`

**Interfaces:**
- Consumes: `SplitAxis`.
- Produces: `final class PaneTree<Leaf>` with:
  - nested `public indirect enum Node { case leaf(id: String, Leaf); case split(axis: SplitAxis, a: Node, b: Node, ratio: Double) }`
  - `init(rootID: String, _ leaf: Leaf)`
  - `var root: Node` (private(set)), `var focusedLeafID: String` (private(set))
  - `var leaves: [(id: String, leaf: Leaf)]` (in-order), `var count: Int`
  - `func leaf(id: String) -> Leaf?`, `var focusedLeaf: Leaf?`
  - `func setFocus(id: String)` (no-op if unknown)
  - `func splitFocused(axis: SplitAxis, newID: String, newLeaf: Leaf, ratio: Double = 0.5)` — new leaf takes the `b` slot, becomes focused
  - `@discardableResult func close(id: String) -> Bool` — collapses the singleton parent; returns `false` if the tree is now empty (the closed leaf was the only one)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ConductorCoreTests/PaneTreeTests.swift
import XCTest
@testable import ConductorCore

final class PaneTreeTests: XCTestCase {
    private func ids(_ t: PaneTree<String>) -> [String] { t.leaves.map { $0.id } }

    func testStartsAsSingleFocusedLeaf() {
        let t = PaneTree(rootID: "A", "hA")
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t.focusedLeafID, "A")
        XCTAssertEqual(t.focusedLeaf, "hA")
        XCTAssertEqual(ids(t), ["A"])
    }

    func testSplitFocusedAddsLeafAfterAndFocusesIt() {
        let t = PaneTree(rootID: "A", "hA")
        t.splitFocused(axis: .horizontal, newID: "B", newLeaf: "hB")
        XCTAssertEqual(ids(t), ["A", "B"])     // in-order: a then b
        XCTAssertEqual(t.focusedLeafID, "B")   // new pane focused
        XCTAssertEqual(t.count, 2)
    }

    func testNestedSplitBuildsTree() {
        // A | B, then split B downward → A | (B / C)
        let t = PaneTree(rootID: "A", "hA")
        t.splitFocused(axis: .horizontal, newID: "B", newLeaf: "hB")  // focus B
        t.splitFocused(axis: .vertical, newID: "C", newLeaf: "hC")    // splits B
        XCTAssertEqual(ids(t), ["A", "B", "C"])
        XCTAssertEqual(t.focusedLeafID, "C")
        // Root is a horizontal split: a = leaf A, b = vertical split (B, C)
        guard case let .split(axis, a, b, _) = t.root else { return XCTFail("root not split") }
        XCTAssertEqual(axis, .horizontal)
        guard case .leaf(let aid, _) = a else { return XCTFail("a not leaf") }
        XCTAssertEqual(aid, "A")
        guard case .split(let inner, _, _, _) = b else { return XCTFail("b not split") }
        XCTAssertEqual(inner, .vertical)
    }

    func testCloseCollapsesParentIntoSibling() {
        let t = PaneTree(rootID: "A", "hA")
        t.splitFocused(axis: .horizontal, newID: "B", newLeaf: "hB")
        let remaining = t.close(id: "B")
        XCTAssertTrue(remaining)
        XCTAssertEqual(ids(t), ["A"])
        // Root collapsed back to a bare leaf.
        guard case .leaf(let id, _) = t.root else { return XCTFail("root not leaf") }
        XCTAssertEqual(id, "A")
    }

    func testClosingFocusedRefocusesSurvivor() {
        let t = PaneTree(rootID: "A", "hA")
        t.splitFocused(axis: .horizontal, newID: "B", newLeaf: "hB")  // focus B
        _ = t.close(id: "B")
        XCTAssertEqual(t.focusedLeafID, "A")
    }

    func testClosingNonFocusedKeepsFocus() {
        let t = PaneTree(rootID: "A", "hA")
        t.splitFocused(axis: .horizontal, newID: "B", newLeaf: "hB")  // focus B
        t.setFocus(id: "A")
        _ = t.close(id: "B")
        XCTAssertEqual(t.focusedLeafID, "A")
    }

    func testClosingOnlyLeafReportsEmpty() {
        let t = PaneTree(rootID: "A", "hA")
        XCTAssertFalse(t.close(id: "A"))   // nothing left
    }

    func testNestedCloseRefocusesIntoSiblingSubtree() {
        // A | (B / C), focus on C; close C → A | B, focus B
        let t = PaneTree(rootID: "A", "hA")
        t.splitFocused(axis: .horizontal, newID: "B", newLeaf: "hB")
        t.splitFocused(axis: .vertical, newID: "C", newLeaf: "hC")    // focus C
        _ = t.close(id: "C")
        XCTAssertEqual(ids(t), ["A", "B"])
        XCTAssertEqual(t.focusedLeafID, "B")
        guard case .split(.horizontal, _, let b, _) = t.root else { return XCTFail("root not h-split") }
        guard case .leaf(let bid, _) = b else { return XCTFail("b not leaf") }
        XCTAssertEqual(bid, "B")
    }

    func testSetFocusUnknownIsNoOp() {
        let t = PaneTree(rootID: "A", "hA")
        t.setFocus(id: "ghost")
        XCTAssertEqual(t.focusedLeafID, "A")
    }

    func testLeafLookup() {
        let t = PaneTree(rootID: "A", "hA")
        t.splitFocused(axis: .horizontal, newID: "B", newLeaf: "hB")
        XCTAssertEqual(t.leaf(id: "A"), "hA")
        XCTAssertEqual(t.leaf(id: "B"), "hB")
        XCTAssertNil(t.leaf(id: "Z"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PaneTreeTests`
Expected: FAIL — `Cannot find 'PaneTree' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/ConductorCore/PaneTree.swift
import Foundation

/// A binary tree of terminal panes inside one surface tab. Generic over `Leaf` (the shell
/// stores a `TerminalSurface`). Pure so split/close/collapse/focus logic is unit-testable.
public final class PaneTree<Leaf> {
    public indirect enum Node {
        case leaf(id: String, Leaf)
        case split(axis: SplitAxis, a: Node, b: Node, ratio: Double)
    }

    public private(set) var root: Node
    public private(set) var focusedLeafID: String

    public init(rootID: String, _ leaf: Leaf) {
        root = .leaf(id: rootID, leaf)
        focusedLeafID = rootID
    }

    public var count: Int { Self.leavesOf(root).count }
    public var leaves: [(id: String, leaf: Leaf)] { Self.leavesOf(root) }

    public func leaf(id: String) -> Leaf? { leaves.first { $0.id == id }?.leaf }
    public var focusedLeaf: Leaf? { leaf(id: focusedLeafID) }

    public func setFocus(id: String) {
        if leaves.contains(where: { $0.id == id }) { focusedLeafID = id }
    }

    /// Replace the focused leaf with a split of {focused, new}; the new leaf takes the `b`
    /// slot and becomes focused.
    public func splitFocused(axis: SplitAxis, newID: String, newLeaf: Leaf, ratio: Double = 0.5) {
        let target = focusedLeafID
        root = Self.replacingLeaf(root, id: target) { existing in
            .split(axis: axis, a: existing, b: .leaf(id: newID, newLeaf), ratio: ratio)
        }
        focusedLeafID = newID
    }

    /// Remove a leaf; collapse the now-only-child split into its parent. Returns false if the
    /// tree is now empty (the closed leaf was the only one). When the focused leaf is closed,
    /// focus moves to its SIBLING subtree's first leaf (not just the first leaf overall).
    @discardableResult
    public func close(id: String) -> Bool {
        if case let .leaf(rootID, _) = root {
            return rootID == id ? false : true   // closing the lone leaf empties the tab
        }
        guard leaves.contains(where: { $0.id == id }) else { return true }
        let refocusTo = (focusedLeafID == id) ? Self.siblingFirstLeaf(root, id: id) : focusedLeafID
        root = Self.removingLeaf(root, id: id)
        focusedLeafID = refocusTo ?? Self.leavesOf(root).first?.id ?? focusedLeafID
        return true
    }

    // MARK: - recursion helpers

    private static func leavesOf(_ node: Node) -> [(id: String, leaf: Leaf)] {
        switch node {
        case let .leaf(id, leaf): return [(id, leaf)]
        case let .split(_, a, b, _): return leavesOf(a) + leavesOf(b)
        }
    }

    /// The first leaf of the sibling of the leaf `id` — where focus goes when `id` is closed.
    private static func siblingFirstLeaf(_ node: Node, id: String) -> String? {
        switch node {
        case .leaf:
            return nil
        case let .split(_, a, b, _):
            if case let .leaf(lid, _) = a, lid == id { return leavesOf(b).first?.id }
            if case let .leaf(lid, _) = b, lid == id { return leavesOf(a).first?.id }
            return siblingFirstLeaf(a, id: id) ?? siblingFirstLeaf(b, id: id)
        }
    }

    private static func replacingLeaf(_ node: Node, id: String,
                                      _ transform: (Node) -> Node) -> Node {
        switch node {
        case .leaf(let lid, _):
            return lid == id ? transform(node) : node
        case let .split(axis, a, b, ratio):
            return .split(axis: axis,
                          a: replacingLeaf(a, id: id, transform),
                          b: replacingLeaf(b, id: id, transform),
                          ratio: ratio)
        }
    }

    /// Remove the leaf with `id`; a split that loses one child collapses to its survivor.
    /// NOTE the `case let .leaf(lid, _) = …, lid == id` form: `case .leaf(id, _)` would BIND
    /// a new `id` (shadowing the parameter) instead of comparing against it — a Swift gotcha.
    private static func removingLeaf(_ node: Node, id: String) -> Node {
        switch node {
        case .leaf:
            return node   // not the target (caller guarantees target exists below a split)
        case let .split(axis, a, b, ratio):
            if case let .leaf(lid, _) = a, lid == id { return b }   // a was the target → sibling survives
            if case let .leaf(lid, _) = b, lid == id { return a }   // b was the target → sibling survives
            return .split(axis: axis, a: removingLeaf(a, id: id), b: removingLeaf(b, id: id), ratio: ratio)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PaneTreeTests`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ConductorCore/PaneTree.swift Tests/ConductorCoreTests/PaneTreeTests.swift
git commit -m "feat(core): PaneTree binary split tree (split/close/collapse/focus)"
```

---

## Task 3: Core — split + focus `ShortcutCommand`s

**Files:**
- Modify: `Sources/ConductorCore/Keybindings.swift`
- Test: `Tests/ConductorCoreTests/KeybindingsTests.swift` (append)

**Interfaces:**
- Produces: repurposed `splitSurface` (displayName "Split Right", still ⌘D); new `ShortcutCommand`s `splitDown` (⌘⇧D), `focusPaneLeft` (⌘⌥←), `focusPaneRight` (⌘⌥→), `focusPaneUp` (⌘⌥↑), `focusPaneDown` (⌘⌥↓), all `.surface` category.

> The existing `splitSurface` case is KEPT (not renamed — avoids breaking `AppDelegate.splitSurfaceAction`/`.splitSurface` references and keybindings.json back-compat). Only its `displayName` changes to "Split Right". Arrow keyEquivalents use the macOS arrow scalars: ← `\u{f702}`, → `\u{f703}`, ↑ `\u{f700}`, ↓ `\u{f701}` (these are what `KeyChord`/`normalizedKeyEquivalent` already handle).

- [ ] **Step 1: Write the failing test**

Append to `Tests/ConductorCoreTests/KeybindingsTests.swift`:

```swift
final class PaneShortcutTests: XCTestCase {
    func testSplitRightKeepsCommandDAndIsRenamed() {
        XCTAssertEqual(ShortcutCommand.splitSurface.defaultChord, KeyChord("d", command: true))
        XCTAssertEqual(ShortcutCommand.splitSurface.displayName, "Split Right")
    }
    func testSplitDownIsShiftCommandD() {
        XCTAssertEqual(ShortcutCommand.splitDown.defaultChord, KeyChord("d", command: true, shift: true))
        XCTAssertEqual(ShortcutCommand.splitDown.category, .surface)
    }
    func testFocusPaneDefaultsAreCommandOptionArrows() {
        XCTAssertEqual(ShortcutCommand.focusPaneLeft.defaultChord,  KeyChord("\u{f702}", command: true, option: true))
        XCTAssertEqual(ShortcutCommand.focusPaneRight.defaultChord, KeyChord("\u{f703}", command: true, option: true))
        XCTAssertEqual(ShortcutCommand.focusPaneUp.defaultChord,    KeyChord("\u{f700}", command: true, option: true))
        XCTAssertEqual(ShortcutCommand.focusPaneDown.defaultChord,  KeyChord("\u{f701}", command: true, option: true))
    }
    func testAllPaneCommandsAreSurfaceCategory() {
        for c in [ShortcutCommand.splitDown, .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown] {
            XCTAssertEqual(c.category, .surface)
        }
    }
    func testDefaultBindingsStillHaveNoConflicts() {
        XCTAssertTrue(keybindingConflicts(Keybindings()).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PaneShortcutTests`
Expected: FAIL — `Type 'ShortcutCommand' has no member 'splitDown'`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/ConductorCore/Keybindings.swift`:

1. Add the cases to the declaration (after `splitSurface`):

```swift
    case newSurface, closeSurface, nextSurface, prevSurface, splitSurface
    case splitDown, focusPaneLeft, focusPaneRight, focusPaneUp, focusPaneDown
    case goToSurface1, goToSurface2, goToSurface3, goToSurface4, goToSurface5
    case goToSurface6, goToSurface7, goToSurface8, goToSurface9
```

2. In `displayName`: change `splitSurface`'s string and add the new ones:

```swift
        case .splitSurface: return "Split Right"
        case .splitDown: return "Split Down"
        case .focusPaneLeft: return "Focus Pane Left"
        case .focusPaneRight: return "Focus Pane Right"
        case .focusPaneUp: return "Focus Pane Up"
        case .focusPaneDown: return "Focus Pane Down"
```

3. In `category`, add the new cases to the `.surface` group:

```swift
        case .newSurface, .closeSurface, .nextSurface, .prevSurface, .splitSurface,
             .splitDown, .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown,
             .goToSurface1, .goToSurface2, .goToSurface3, .goToSurface4, .goToSurface5,
             .goToSurface6, .goToSurface7, .goToSurface8, .goToSurface9:
            return .surface
```

4. In `defaultChord`, add (keep `splitSurface` as ⌘D):

```swift
        case .splitDown:       return KeyChord("d", command: true, shift: true)
        case .focusPaneLeft:   return KeyChord("\u{f702}", command: true, option: true)
        case .focusPaneRight:  return KeyChord("\u{f703}", command: true, option: true)
        case .focusPaneUp:     return KeyChord("\u{f700}", command: true, option: true)
        case .focusPaneDown:   return KeyChord("\u{f701}", command: true, option: true)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PaneShortcutTests`
Then the full Core suite (a count assertion in `KeybindingsTests` may need updating from 22 → 27):
Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: all green. If `testThereAreTwentyTwoBindableCommands` exists, update it to expect **27** (22 + 5 new) and rename to match.

- [ ] **Step 5: Commit**

```bash
git add Sources/ConductorCore/Keybindings.swift Tests/ConductorCoreTests/KeybindingsTests.swift
git commit -m "feat(core): split-down + pane-focus shortcut commands; splitSurface → Split Right"
```

---

## Task 4: Shell — `SplitSurface` container

**Files:**
- Create: `Sources/Conductor/SplitSurface.swift`
- Modify: `Sources/Conductor/ClickableTerminalView.swift` (add focus hook)
- Modify: `Sources/Conductor/TerminalSurface.swift` (expose `onFocused`)

**Interfaces:**
- Consumes: `PaneTree`, `SplitAxis`, `PaneDirection`, `PaneRect`, `nearestPane`, `TerminalSurface`.
- Produces: `final class SplitSurface: NSViewController` with:
  - `init(firstPane: TerminalSurface, firstID: String, makePane: @escaping () -> (id: String, pane: TerminalSurface))`
  - `var allPanes: [TerminalSurface]`, `var focusedPane: TerminalSurface`
  - `var onFocusChange: (() -> Void)?` (fires when the focused pane changes or its title changes)
  - `var identityColor: NSColor?` (sets the focused-pane border tint)
  - `func splitFocused(axis: SplitAxis)`, `@discardableResult func closeFocused() -> Bool`, `func moveFocus(_ direction: PaneDirection)`
  - `func paneContaining(_ event: NSEvent) -> TerminalSurface?`

- [ ] **Step 1: Add the focus hook to `ClickableTerminalView`**

In `Sources/Conductor/ClickableTerminalView.swift`, add a stored hook + override `becomeFirstResponder`:

```swift
    /// Fired when this terminal becomes first responder (click or programmatic focus),
    /// so the owning SplitSurface can mark this pane focused.
    var onBecomeFirstResponder: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onBecomeFirstResponder?() }
        return ok
    }
```

- [ ] **Step 2: Expose `onFocused` on `TerminalSurface`**

In `Sources/Conductor/TerminalSurface.swift`, add a forwarding hook. Add the property near `onTitleChange`:

```swift
    /// Fired when this surface's terminal gains focus (forwarded from the terminal view).
    var onFocused: (() -> Void)?
```

And in `loadView()`, after `terminal.onTitleChange = …`, wire:

```swift
        terminal.onBecomeFirstResponder = { [weak self] in self?.onFocused?() }
```

- [ ] **Step 3: Create `SplitSurface`**

```swift
// Sources/Conductor/SplitSurface.swift
import AppKit
import ConductorCore

/// One surface tab's content: a tree of terminal panes rendered as nested NSSplitViews.
/// Owns a pure `PaneTree<TerminalSurface>`; the shell rebuilds the view hierarchy from it
/// after every structural change. A single-pane surface is just the one terminal view
/// (no NSSplitView) so unsplit tabs behave exactly like PR A.
final class SplitSurface: NSViewController {
    private let tree: PaneTree<TerminalSurface>
    /// Builds a fresh pane (id + TerminalSurface) for the worktree — used on every split.
    private let makePane: () -> (id: String, pane: TerminalSurface)
    private let container = NSView()

    /// Fires when the focused pane changes or its title changes (so the tab bar/chrome refresh).
    var onFocusChange: (() -> Void)?
    /// Identity color for the focused-pane border (worktree/tab color).
    var identityColor: NSColor? { didSet { updateFocusBorders() } }

    init(firstPane: TerminalSurface, firstID: String,
         makePane: @escaping () -> (id: String, pane: TerminalSurface)) {
        self.tree = PaneTree(rootID: firstID, firstPane)
        self.makePane = makePane
        super.init(nibName: nil, bundle: nil)
        wire(firstPane, id: firstID)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        container.translatesAutoresizingMaskIntoConstraints = false
        view = container
        rebuild()
    }

    var allPanes: [TerminalSurface] { tree.leaves.map { $0.leaf } }
    var focusedPane: TerminalSurface { tree.focusedLeaf ?? tree.leaves[0].leaf }

    func splitFocused(axis: SplitAxis) {
        let made = makePane()
        wire(made.pane, id: made.id)
        tree.splitFocused(axis: axis, newID: made.id, newLeaf: made.pane)
        rebuild()
        distributeDividers()
        focusActivePane()
        onFocusChange?()
    }

    /// Close the focused pane. Returns false when it was the last pane (caller closes the tab).
    @discardableResult
    func closeFocused() -> Bool {
        let target = tree.focusedLeafID
        let pane = tree.leaf(id: target)
        let remaining = tree.close(id: target)
        guard remaining else { return false }
        pane?.view.removeFromSuperview(); pane?.removeFromParent()
        rebuild()
        distributeDividers()
        focusActivePane()
        onFocusChange?()
        return true
    }

    func moveFocus(_ direction: PaneDirection) {
        let frames = tree.leaves.map { entry -> PaneRect in
            let f = entry.leaf.view.convert(entry.leaf.view.bounds, to: container)
            // NSView is bottom-left origin; flip y to top-left for Core's convention.
            let topY = container.bounds.height - f.maxY
            return PaneRect(id: entry.id, x: Double(f.minX), y: Double(topY),
                            width: Double(f.width), height: Double(f.height))
        }
        guard let next = nearestPane(from: tree.focusedLeafID, direction: direction, frames: frames) else { return }
        tree.setFocus(id: next)
        focusActivePane()
        onFocusChange?()
    }

    /// The pane whose view contains the click (for ⌘+click open-file routing).
    func paneContaining(_ event: NSEvent) -> TerminalSurface? {
        allPanes.first { $0.containsClick(event) }
    }

    // MARK: - private

    private func wire(_ pane: TerminalSurface, id: String) {
        addChild(pane)
        pane.onFocused = { [weak self] in
            guard let self else { return }
            self.tree.setFocus(id: id)
            self.updateFocusBorders()
            self.onFocusChange?()
        }
        // Title changes already call AppDelegate's onTitleChange (set when the pane is built);
        // we additionally refresh on focus change so the tab label tracks the focused pane.
    }

    private func focusActivePane() {
        view.window?.makeFirstResponder(focusedPane.view)
        updateFocusBorders()
    }

    /// Highlight the focused pane with a 1px identity-color border; clear the others.
    private func updateFocusBorders() {
        for entry in tree.leaves {
            let v = entry.leaf.view
            v.wantsLayer = true
            let focused = entry.id == tree.focusedLeafID && tree.count > 1
            v.layer?.borderWidth = focused ? 1 : 0
            v.layer?.borderColor = (focused ? identityColor : nil)?.cgColor
        }
    }

    /// Rebuild the view hierarchy from the tree.
    private func rebuild() {
        container.subviews.forEach { $0.removeFromSuperview() }
        let rootView = buildView(tree.root)
        rootView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(rootView)
        NSLayoutConstraint.activate([
            rootView.topAnchor.constraint(equalTo: container.topAnchor),
            rootView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            rootView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            rootView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        updateFocusBorders()
    }

    private func buildView(_ node: PaneTree<TerminalSurface>.Node) -> NSView {
        switch node {
        case let .leaf(_, pane):
            pane.view.translatesAutoresizingMaskIntoConstraints = true
            pane.view.autoresizingMask = [.width, .height]
            return pane.view
        case let .split(axis, a, b, _):
            let split = NSSplitView()
            split.isVertical = (axis == .horizontal)   // side-by-side ⇒ vertical dividers
            split.dividerStyle = .thin
            split.translatesAutoresizingMaskIntoConstraints = true
            split.autoresizingMask = [.width, .height]
            split.addArrangedSubview(buildView(a))
            split.addArrangedSubview(buildView(b))
            return split
        }
    }

    /// Even out every NSSplitView once real sizes exist (the spike's deferred pattern).
    private func distributeDividers() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.container.layoutSubtreeIfNeeded()
            self.splitViews(in: self.container).forEach(self.distribute)
        }
    }

    private func splitViews(in v: NSView) -> [NSSplitView] {
        var out: [NSSplitView] = []
        if let s = v as? NSSplitView { out.append(s) }
        v.subviews.forEach { out += splitViews(in: $0) }
        return out
    }

    private func distribute(_ split: NSSplitView) {
        let n = split.arrangedSubviews.count
        guard n > 1 else { return }
        let vertical = split.isVertical
        let total = vertical ? split.bounds.width : split.bounds.height
        let dividerW = split.dividerThickness
        let usable = total - dividerW * CGFloat(n - 1)
        guard usable > 0 else { return }
        let pane = usable / CGFloat(n)
        for i in 0..<(n - 1) {
            let pos = CGFloat(i + 1) * pane + CGFloat(i) * dividerW
            split.setPosition(pos, ofDividerAt: i)
        }
    }
}
```

> **Note:** PR A's `TerminalSurface` already sets `onOpenFile`/`onTitleChange`/theme/font when the AppDelegate builds it. In `SplitSurface`, the `makePane` closure (provided by the AppDelegate in Task 5) is responsible for building each new pane fully-configured (cwd, theme, font, `onOpenFile`, `onTitleChange`). `SplitSurface.wire` only adds the child + the `onFocused` hook.

- [ ] **Step 4: Build (the new file is unused until Task 5 wires it)**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: clean build (one pre-existing `try?` warning in AppDelegate is not yours). `SplitSurface` compiles; nothing uses it yet. If errors mention `SplitSurface.swift`, fix them.

- [ ] **Step 5: Commit**

```bash
git add Sources/Conductor/SplitSurface.swift Sources/Conductor/ClickableTerminalView.swift Sources/Conductor/TerminalSurface.swift
git commit -m "feat(app): SplitSurface pane container (nested NSSplitViews) + focus hook"
```

---

## Task 5: Shell — swap the surface Handle to `SplitSurface`

**Files:**
- Modify: `Sources/Conductor/AppDelegate.swift`

This is the mechanical integration: change `SurfaceRegistry<TerminalSurface>` → `<SplitSurface>` and update every call site so PR A behaves identically with each tab wrapping a single-pane `SplitSurface`. No split keybinds yet (Task 6); this task must leave the app working exactly as PR A.

**Interfaces:**
- Consumes: `SplitSurface`.

- [ ] **Step 1: Change the registry + currentSurface types**

- `private let surfaces = SurfaceRegistry<TerminalSurface>()` → `SurfaceRegistry<SplitSurface>()`
- `private var currentSurface: TerminalSurface?` → `private var currentSurface: SplitSurface?`

- [ ] **Step 2: Rewrite `createSurface` to build a `SplitSurface`**

Replace `createSurface(in:runSetupAndAutoLaunch:)` with:

```swift
    @discardableResult
    private func createSurface(in wt: Worktree, runSetupAndAutoLaunch: Bool) -> SplitSurface {
        shownWorktreeID = wt.id
        surfaces.setActive(wt.id)
        let repo = store.state.repositories.first { $0.id == wt.repoID }
        let isNewlyCreated = runSetupAndAutoLaunch && pendingSetupWorktreeIDs.contains(wt.id)
        let setup = isNewlyCreated ? (repo?.setupScript ?? "") : ""
        pendingSetupWorktreeIDs.remove(wt.id)
        let command = (isNewlyCreated && repo?.autoLaunchClaude == true) ? launchCommand(for: repo!) : ""

        // The first pane carries setup/command; split panes are plain shells (makePane).
        let firstPane = makePane(in: wt, command: command, setup: setup)
        let split = SplitSurface(
            firstPane: firstPane, firstID: nextPaneID(),
            makePane: { [weak self, wt] in
                let pane = self?.makePane(in: wt, command: "", setup: "") ?? TerminalSurface(workingDirectory: wt.worktreePath, command: "", setupScript: "")
                return (self?.nextPaneID() ?? UUID().uuidString, pane)
            })
        split.onFocusChange = { [weak self] in self?.refreshTabBar(); self?.refreshChromeForActiveSurface() }

        surfaceSeq += 1
        let id = "surface-\(surfaceSeq)"
        let list = surfaces.surfaces(for: wt.id)
        list.activeHandle?.view.isHidden = true
        list.add(split, surface: Surface(id: id))

        addChild(split)
        split.view.translatesAutoresizingMaskIntoConstraints = false
        detail.view.addSubview(split.view)
        NSLayoutConstraint.activate([
            split.view.topAnchor.constraint(equalTo: surfaceTabBar.bottomAnchor, constant: 6),
            split.view.bottomAnchor.constraint(equalTo: detail.view.bottomAnchor),
            split.view.leadingAnchor.constraint(equalTo: detail.view.leadingAnchor, constant: 8),
            split.view.trailingAnchor.constraint(equalTo: detail.view.trailingAnchor, constant: -8),
        ])
        currentSurface = split
        split.identityColor = (selectedWorktree?.color).flatMap { NSColor(hex: $0) }
        view(focus: split)
        refreshChromeForActiveSurface()
        refreshTabBar()
        return split
    }

    /// Build a fully-configured terminal pane for a worktree (cwd, theme, font, callbacks).
    private func makePane(in wt: Worktree, command: String, setup: String) -> TerminalSurface {
        let pane = TerminalSurface(workingDirectory: wt.worktreePath, command: command, setupScript: setup)
        pane.onOpenFile = { [weak self] path, line in self?.openInDefaultEditor(path: path, line: line) }
        pane.onTitleChange = { [weak self] _ in self?.refreshTabBar() }
        pane.applyTheme(activeTheme)
        pane.applyFont(resolvedTerminalFont())
        return pane
    }

    private var paneSeq = 0
    private func nextPaneID() -> String { paneSeq += 1; return "pane-\(paneSeq)" }
```

- [ ] **Step 3: Update `view(focus:)` to take a `SplitSurface`**

```swift
    private func view(focus surface: SplitSurface) {
        window.makeFirstResponder(surface.focusedPane.view)
    }
```

- [ ] **Step 4: Update `refreshTabBar` to read the focused pane's title**

Change the `label:` and `state:` lines inside the `items` map:

```swift
            return SurfaceTabItem(
                id: entry.surface.id,
                label: surfaceLabel(nameOverride: entry.surface.nameOverride,
                                    terminalTitle: entry.handle.focusedPane.terminalTitle, index: idx),
                state: agentStates[surfaceKey(wtID, entry.surface.id)] ?? .idle,
                isActive: entry.surface.id == list.activeSurfaceID,
                tint: effective?.nsColor)
```

- [ ] **Step 5: Update theme/font fan-out + poll to walk panes**

In `applyActiveTheme()`:

```swift
        for wtID in surfaces.worktreeIDs {
            surfaces.existingSurfaces(for: wtID)?.handles.forEach { split in
                split.allPanes.forEach { $0.applyTheme(activeTheme) }
            }
        }
```

In `setTerminalFont(_:)`:

```swift
        let font = resolvedTerminalFont()
        for wtID in surfaces.worktreeIDs {
            surfaces.existingSurfaces(for: wtID)?.handles.forEach { split in
                split.allPanes.forEach { $0.applyFont(font) }
            }
        }
```

In `pollAgentStates()`, the per-surface snapshot rolls up the surface's panes (the per-tab key keeps working; the cross-pane rollup is finalized in Task 8, but make it compile now by rolling up panes):

```swift
    private func pollAgentStates() {
        var states: [String: AgentState] = [:]
        var rollups: [String: AgentState] = [:]
        for wtID in surfaces.worktreeIDs {
            guard let list = surfaces.existingSurfaces(for: wtID) else { continue }
            var perSurface: [AgentState] = []
            for entry in list.entries {
                let paneStates = entry.handle.allPanes.map { agentState(fromOutput: $0.outputSnapshot()) }
                let surfaceState = rollup(paneStates)
                states[surfaceKey(wtID, entry.surface.id)] = surfaceState
                perSurface.append(surfaceState)
            }
            rollups[wtID] = rollup(perSurface)
        }
        for (k, v) in rollups { states[k] = v }
        agentStates = states
        sidebar.updateAgentStates(rollups)
        updateNotch()
        refreshChromeForActiveSurface()
        refreshTabBar()
    }
```

- [ ] **Step 6: Update `archive`, the ⌘+click monitor, and Launch Claude**

`archive(_:)` already iterates `surfaces.evict(worktreeID:)` and calls `removeFromSuperview()/removeFromParent()` per handle — now each handle is a `SplitSurface`; its child panes are removed with it. Add, before removing each `split`, a teardown of its panes so PTYs don't leak:

```swift
            for split in surfaces.evict(worktreeID: s.id) {
                split.allPanes.forEach { $0.view.removeFromSuperview(); $0.removeFromParent() }
                split.view.removeFromSuperview()
                split.removeFromParent()
            }
```

The ⌘+click monitor (in `applicationDidFinishLaunching`) currently uses `currentSurface` (was a `TerminalSurface`). Update to route to the clicked pane:

```swift
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self, event.modifierFlags.contains(.command), event.window === self.window,
                  let split = self.currentSurface, let pane = split.paneContaining(event) else { return event }
            if event.type == .leftMouseDown { pane.handleCommandClick(event) }
            return nil
        }
```

`launchClaudeAction()` uses `currentSurface` (was TerminalSurface, `.sendCommand`). Update to the focused pane:

```swift
        guard let wt = selectedWorktree,
              let repo = store.state.repositories.first(where: { $0.id == wt.repoID }),
              let split = currentSurface else {
            presentMessage("Select a worktree first."); return
        }
        split.focusedPane.sendCommand(launchCommand(for: repo))
```

- [ ] **Step 7: Build + full test + in-app smoke**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` (clean) and `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` (173+ pass).
Run the app: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run` and confirm **PR A behavior is intact** — tabs create/switch/close, ⌘T/⌘W/⌘1-9, badges, color, Launch Claude, ⌘+click — all with each tab now a single-pane `SplitSurface`. No splitting yet.

- [ ] **Step 8: Commit**

```bash
git add Sources/Conductor/AppDelegate.swift
git commit -m "refactor(app): swap surface Handle TerminalSurface -> SplitSurface (single-pane parity)"
```

---

## Task 6: Shell — split actions + keybinds + pane-aware close

**Files:**
- Modify: `Sources/Conductor/AppDelegate.swift`

**Interfaces:**
- Consumes: `SplitSurface.splitFocused(axis:)`, `closeFocused()`, `ShortcutCommand.splitSurface/.splitDown`.

- [ ] **Step 1: Implement split actions**

Replace the no-op `splitSurfaceAction` and add split-down:

```swift
    @objc private func splitSurfaceAction() { currentSurface?.splitFocused(axis: .horizontal) }
    @objc private func splitDownAction() { currentSurface?.splitFocused(axis: .vertical) }
```

- [ ] **Step 2: Make `closeSurface` (⌘W) pane-aware**

At the TOP of `closeSurface(_ id: String? = nil)`, before the existing tab-close logic, add: if no explicit surface id is given and the current surface has more than one pane, close the focused pane instead of the tab.

```swift
    private func closeSurface(_ id: String? = nil) {
        // ⌘W (no explicit surface id): close the focused PANE first; only close the tab
        // when the surface is down to its last pane.
        if id == nil, let split = currentSurface, split.allPanes.count > 1 {
            _ = split.closeFocused()
            refreshChromeForActiveSurface()
            refreshTabBar()
            return
        }
        // (existing tab-close logic unchanged below — guard shownWorktreeID, busy-confirm,
        //  list.close, respawn-on-last-tab, etc.)
        guard let wtID = shownWorktreeID, let list = surfaces.existingSurfaces(for: wtID) else { return }
        ...
    }
```

> Keep the rest of `closeSurface` exactly as it is. The busy-confirm in the existing path is per-tab; a per-pane busy-confirm is out of scope (a pane close is cheaper to redo). When `closeFocused()` is called here it always returns true (we gated on `count > 1`).

- [ ] **Step 3: Add menu items + keybind wiring**

In `buildMenu()`'s Surface menu, change the split item label/command and add split-down + a separator. Find:

```swift
        addItem(to: surfaceMenu, "Split Surface", #selector(splitSurfaceAction), command: .splitSurface)
```

Replace with:

```swift
        addItem(to: surfaceMenu, "Split Right", #selector(splitSurfaceAction), command: .splitSurface)
        addItem(to: surfaceMenu, "Split Down", #selector(splitDownAction), command: .splitDown)
```

- [ ] **Step 4: Build + in-app verify**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` (clean) + `swift test` (green).
Run the app and verify: ⌘D splits the focused pane into a side-by-side pair (even widths); ⌘⇧D splits into a stacked pair; splitting a pane again nests correctly; new pane is a fresh shell; ⌘W closes the focused pane and the neighbor expands to fill; ⌘W on the last pane closes the tab (and respawns if it was the last tab). Capture the divider-evenness result.

- [ ] **Step 5: Commit**

```bash
git add Sources/Conductor/AppDelegate.swift
git commit -m "feat(app): split right/down actions + keybinds + pane-aware close"
```

---

## Task 7: Shell — directional focus + click-to-focus + ⌘+click routing

**Files:**
- Modify: `Sources/Conductor/AppDelegate.swift`

**Interfaces:**
- Consumes: `SplitSurface.moveFocus(_:)`, `ShortcutCommand.focusPane*`.

- [ ] **Step 1: Add focus-move actions**

```swift
    @objc private func focusPaneLeftAction()  { currentSurface?.moveFocus(.left) }
    @objc private func focusPaneRightAction() { currentSurface?.moveFocus(.right) }
    @objc private func focusPaneUpAction()    { currentSurface?.moveFocus(.up) }
    @objc private func focusPaneDownAction()  { currentSurface?.moveFocus(.down) }
```

- [ ] **Step 2: Add menu items**

In the Surface menu (after Split Down), add a separator and the four focus items:

```swift
        surfaceMenu.addItem(.separator())
        addItem(to: surfaceMenu, "Focus Pane Left",  #selector(focusPaneLeftAction),  command: .focusPaneLeft)
        addItem(to: surfaceMenu, "Focus Pane Right", #selector(focusPaneRightAction), command: .focusPaneRight)
        addItem(to: surfaceMenu, "Focus Pane Up",    #selector(focusPaneUpAction),    command: .focusPaneUp)
        addItem(to: surfaceMenu, "Focus Pane Down",  #selector(focusPaneDownAction),  command: .focusPaneDown)
```

- [ ] **Step 3: Keep the identity-color border in sync**

In `refreshChromeForActiveSurface()`, after computing the worktree's effective color, push it to the current surface so the focused-pane border matches. Add near the end of that method:

```swift
        currentSurface?.identityColor = effective?.nsColor
```

(Click-to-focus and ⌘+click routing already work: `SplitSurface.wire` sets each pane's `onFocused` → updates focus + border + `onFocusChange`; the ⌘+click monitor from Task 5 routes via `paneContaining`.)

- [ ] **Step 4: Build + in-app verify**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` + `swift test`.
Run the app with a split tab and verify: ⌘⌥arrows move focus to the correct neighbor pane in each direction; clicking a pane focuses it; the focused pane shows the identity-color border; ⌘+click in a specific pane opens the file from THAT pane's directory; Launch Claude runs in the focused pane. Capture whether ⌘⌥arrows fire while the terminal has focus.

- [ ] **Step 5: Commit**

```bash
git add Sources/Conductor/AppDelegate.swift
git commit -m "feat(app): directional pane focus (⌘⌥arrows) + click-to-focus border"
```

---

## Task 8: Shell — per-pane badge rollup + tab reflects focused pane

**Files:**
- Modify: `Sources/Conductor/AppDelegate.swift`

Most of this landed in Task 5 (poll rolls up panes → tab badge; tab label reads `focusedPane.terminalTitle`). This task verifies the end-to-end behavior and tightens the tab label to also refresh when focus changes between panes.

**Interfaces:**
- Consumes: `SplitSurface.onFocusChange` (already calls `refreshTabBar` + `refreshChromeForActiveSurface`, wired in Task 5).

- [ ] **Step 1: Confirm focus-change refreshes the tab label**

`createSurface` (Task 5) set `split.onFocusChange = { self.refreshTabBar(); self.refreshChromeForActiveSurface() }`. Verify this line is present; it makes the tab label follow the focused pane when you move focus between panes. No code change if present.

- [ ] **Step 2: Build + in-app verify the rollup + label**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` + `swift test`.
Run the app and verify:
- A tab with two panes shows the **focused pane's** title as the tab label; moving focus to the other pane updates the label.
- Run `claude` in one pane: the **tab badge** shows that state (rollup), and the **sidebar/notch** roll it up too — even when the busy pane is NOT focused and even when its tab is a background tab.
- Two panes in different states (one 🔴 needsYou, one 🟡 working): the tab badge shows 🔴 (rollup priority).

- [ ] **Step 3: Commit (if any change was needed)**

```bash
git add Sources/Conductor/AppDelegate.swift
git commit -m "feat(app): tab badge rolls up panes; tab label follows focused pane"
```

(If Step 1 confirmed everything was already wired in Task 5, skip the commit and note that in the task report.)

---

## Final Verification

- [ ] Full Core suite green: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
- [ ] Clean build: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
- [ ] In-app smoke of Tasks 5–8 behaviors (single-pane parity, split right/down, nested, close+collapse, last-pane→tab close, ⌘⌥arrow focus, click focus, border, ⌘+click per pane, Launch Claude in focused pane, badge rollup, tab label follows focus).
- [ ] Confirm the flagged risks were resolved or documented:
  - Nested-divider distribution is even (deferred `setPosition` applied recursively).
  - ⌘⌥arrows fire while the terminal has focus (or a working default substituted + noted).
  - Click-to-focus reliably detects the focused pane (`becomeFirstResponder` hook fires).
- [ ] Request whole-branch review (`superpowers:requesting-code-review`); this branch is stacked on PR A — review against the PR A tip as merge-base, or rebase onto `main` first if #28 has merged.

## Notes / carried-forward

- **Stacked branch:** `phase1.5-splits` is off `phase1.5-surface-tabs` (#28). If #28 merges first, rebase this onto `main` before opening PR B.
- **In-memory only:** pane layout lost on restart, by design.
- **Out of scope:** scratch tabs (PR C), per-pane color/name, drag-to-reorder/move-pane-to-tab, per-pane busy-confirm on ⌘W.
