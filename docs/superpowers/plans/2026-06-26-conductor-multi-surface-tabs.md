# Phase 1.5 PR A — Surface Tabs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each worktree multiple terminal surfaces ("tabs"), each its own PTY, with a tab bar, keybinds, per-tab rename/color, and per-tab agent badges that roll up to the sidebar.

**Architecture:** Extend the pure-Core `SurfaceRegistry<Handle>` from a flat `[worktreeID: Handle]` map into a two-level `[worktreeID: WorktreeSurfaces<Handle>]`, where `WorktreeSurfaces` owns an ordered list of `(Surface, Handle)` + an active id. All ordering/active logic stays pure and XCTest-covered with a stub `Handle`. The AppKit shell stores `TerminalSurface` as the `Handle`, renders a `SurfaceTabBar`, and wires new `ShortcutCommand` cases into the menu + customizable Keybindings system.

**Tech Stack:** Swift 6.2 (Xcode toolchain), SwiftPM, AppKit, SwiftTerm. Two modules: `ConductorCore` (pure, tested) and `Conductor` (AppKit shell).

**Spec:** `docs/superpowers/specs/2026-06-26-conductor-multi-surface-design.md`

## Global Constraints

- **Toolchain prefix is mandatory on every build/run/test:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (Command Line Tools ship no XCTest; the two toolchains diverge — see `DECISIONS.md`). Build/test command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. If you hit `module compiled with Swift 6.3.2 cannot be imported`, run `rm -rf .build` then rebuild through the Xcode `DEVELOPER_DIR`.
- **Tests are XCTest**, not Swift Testing (`import XCTest`, `@testable import ConductorCore`, `final class … : XCTestCase`).
- **Core stays pure** — `ConductorCore` never imports AppKit. Colors are `RGB` (sRGB 0…1), not `NSColor`.
- **SourceKit false alarms:** the editor may flag `Bundle.module` / freshly-added types as `inaccessible` / `Cannot find <type>`. `swift build` is the source of truth, not editor diagnostics.
- **In-memory only, no restore:** `Surface.nameOverride` / `colorOverride` are session-only; do **not** add serialization (`local.json` / `Codable` round-trips) for them.
- **Scope = PR A only.** `splitSurface` (⌘D) is wired but a no-op; `SurfaceKind.scratch` is declared but never constructed. Do not build splits or scratch tabs.

---

## File Structure

**Core (new):**
- `Sources/ConductorCore/Surface.swift` — `Surface` value type, `SurfaceKind`, `surfaceLabel(...)` pure helper.
- `Sources/ConductorCore/WorktreeSurfaces.swift` — `WorktreeSurfaces<Handle>` ordered list + active tracking.

**Core (modified):**
- `Sources/ConductorCore/SurfaceRegistry.swift` — rework to two-level.
- `Sources/ConductorCore/AgentState.swift` — add `rollup(_:)`.
- `Sources/ConductorCore/Keybindings.swift` — add `.surface` category + 14 `ShortcutCommand` cases.

**Core tests:**
- `Tests/ConductorCoreTests/SurfaceTests.swift` (new)
- `Tests/ConductorCoreTests/WorktreeSurfacesTests.swift` (new)
- `Tests/ConductorCoreTests/SurfaceRegistryTests.swift` (rewrite)
- `Tests/ConductorCoreTests/AgentStateTests.swift` (extend — add rollup tests)
- `Tests/ConductorCoreTests/KeybindingsTests.swift` (extend — new commands conflict-free)

**Shell (new):**
- `Sources/Conductor/SurfaceTabBar.swift` — the tab-bar `NSView`.
- `Sources/Conductor/ColorMenu.swift` — shared Set-Color submenu builder.

**Shell (modified):**
- `Sources/Conductor/SidebarController.swift` — use `ColorMenu` helper (DRY the two near-dup blocks).
- `Sources/Conductor/AppDelegate.swift` — multi-surface lifecycle, Surface menu, keybinds, tab context menu, per-tab badge + rollup.

---

## Task 1: Core — `Surface` value type + label helper

**Files:**
- Create: `Sources/ConductorCore/Surface.swift`
- Test: `Tests/ConductorCoreTests/SurfaceTests.swift`

**Interfaces:**
- Produces:
  - `enum SurfaceKind: String, Codable, Equatable { case worktree, scratch }`
  - `struct Surface: Equatable { let id: String; var nameOverride: String?; var colorOverride: RGB?; var kind: SurfaceKind; init(id:nameOverride:colorOverride:kind:); func effectiveColor(worktreeColor: RGB?) -> RGB? }`
  - `func surfaceLabel(nameOverride: String?, terminalTitle: String?, index: Int) -> String`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ConductorCoreTests/SurfaceTests.swift
import XCTest
@testable import ConductorCore

final class SurfaceTests: XCTestCase {
    func testEffectiveColorPrefersOverride() {
        let s = Surface(id: "s1", colorOverride: RGB(r: 1, g: 0, b: 0))
        XCTAssertEqual(s.effectiveColor(worktreeColor: RGB(r: 0, g: 0, b: 1)), RGB(r: 1, g: 0, b: 0))
    }

    func testEffectiveColorFallsBackToWorktreeColor() {
        let s = Surface(id: "s1")
        XCTAssertEqual(s.effectiveColor(worktreeColor: RGB(r: 0, g: 0, b: 1)), RGB(r: 0, g: 0, b: 1))
    }

    func testEffectiveColorNilWhenNeither() {
        XCTAssertNil(Surface(id: "s1").effectiveColor(worktreeColor: nil))
    }

    func testDefaultKindIsWorktree() {
        XCTAssertEqual(Surface(id: "s1").kind, .worktree)
    }

    func testLabelPrefersRename() {
        XCTAssertEqual(surfaceLabel(nameOverride: "logs", terminalTitle: "zsh", index: 2), "logs")
    }

    func testLabelUsesTerminalTitleWhenNoRename() {
        XCTAssertEqual(surfaceLabel(nameOverride: nil, terminalTitle: "claude", index: 0), "claude")
    }

    func testLabelFallsBackToTerminalN() {
        XCTAssertEqual(surfaceLabel(nameOverride: nil, terminalTitle: "", index: 0), "Terminal 1")
        XCTAssertEqual(surfaceLabel(nameOverride: "   ", terminalTitle: nil, index: 4), "Terminal 5")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SurfaceTests`
Expected: FAIL — `Cannot find 'Surface' in scope` / `Cannot find 'surfaceLabel'`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/ConductorCore/Surface.swift
import Foundation

/// Whether a surface belongs to a worktree or is a worktree-less scratch shell.
/// `.scratch` is reserved for Phase 1.5 PR C; PR A only constructs `.worktree`.
public enum SurfaceKind: String, Codable, Equatable {
    case worktree, scratch
}

/// One terminal surface ("tab") inside a worktree. The live PTY/terminal is held by
/// the shell as the registry's `Handle`; this value type carries only the metadata
/// Core reasons about. All fields are in-memory only (no restore).
public struct Surface: Equatable {
    public let id: String
    public var nameOverride: String?
    public var colorOverride: RGB?
    public var kind: SurfaceKind

    public init(id: String, nameOverride: String? = nil,
                colorOverride: RGB? = nil, kind: SurfaceKind = .worktree) {
        self.id = id
        self.nameOverride = nameOverride
        self.colorOverride = colorOverride
        self.kind = kind
    }

    /// The color this surface contributes to chrome: its own override, else the worktree's.
    public func effectiveColor(worktreeColor: RGB?) -> RGB? { colorOverride ?? worktreeColor }
}

/// The label to show for a surface tab: an explicit rename wins; otherwise the live
/// terminal title (OSC-set by the shell/claude) if non-empty; otherwise "Terminal N"
/// (1-based). Pure so the shell's labeling is unit-testable.
public func surfaceLabel(nameOverride: String?, terminalTitle: String?, index: Int) -> String {
    if let n = nameOverride, !n.trimmingCharacters(in: .whitespaces).isEmpty { return n }
    if let t = terminalTitle?.trimmingCharacters(in: .whitespaces), !t.isEmpty { return t }
    return "Terminal \(index + 1)"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SurfaceTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ConductorCore/Surface.swift Tests/ConductorCoreTests/SurfaceTests.swift
git commit -m "feat(core): Surface value type + label helper for multi-surface tabs"
```

---

## Task 2: Core — `rollup(_:)` agent-state aggregation

**Files:**
- Modify: `Sources/ConductorCore/AgentState.swift` (append)
- Test: `Tests/ConductorCoreTests/AgentStateTests.swift` (append a new test class or methods)

**Interfaces:**
- Consumes: `AgentState` (existing enum).
- Produces: `func rollup(_ states: [AgentState]) -> AgentState`

- [ ] **Step 1: Write the failing test**

Append to `Tests/ConductorCoreTests/AgentStateTests.swift`:

```swift
final class AgentStateRollupTests: XCTestCase {
    func testEmptyRollsUpToIdle() {
        XCTAssertEqual(rollup([]), .idle)
    }
    func testNeedsYouWinsOverEverything() {
        XCTAssertEqual(rollup([.idle, .working, .done, .needsYou]), .needsYou)
    }
    func testWorkingWinsOverDoneAndIdle() {
        XCTAssertEqual(rollup([.idle, .done, .working]), .working)
    }
    func testDoneWinsOverIdle() {
        XCTAssertEqual(rollup([.idle, .done, .idle]), .done)
    }
    func testAllIdleRollsUpToIdle() {
        XCTAssertEqual(rollup([.idle, .idle]), .idle)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AgentStateRollupTests`
Expected: FAIL — `Cannot find 'rollup' in scope`.

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/ConductorCore/AgentState.swift`:

```swift
/// The worktree-level badge across its surfaces: the highest-priority state present.
/// Priority: needsYou > working > done > idle. An empty list rolls up to idle.
public func rollup(_ states: [AgentState]) -> AgentState {
    if states.contains(.needsYou) { return .needsYou }
    if states.contains(.working) { return .working }
    if states.contains(.done) { return .done }
    return .idle
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AgentStateRollupTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ConductorCore/AgentState.swift Tests/ConductorCoreTests/AgentStateTests.swift
git commit -m "feat(core): rollup() aggregates per-surface agent states for sidebar badge"
```

---

## Task 3: Core — `WorktreeSurfaces<Handle>` ordered list

**Files:**
- Create: `Sources/ConductorCore/WorktreeSurfaces.swift`
- Test: `Tests/ConductorCoreTests/WorktreeSurfacesTests.swift`

**Interfaces:**
- Consumes: `Surface`, `RGB`.
- Produces: `final class WorktreeSurfaces<Handle>` with:
  - `struct Entry { var surface: Surface; let handle: Handle }`
  - `var entries: [Entry]` (private(set)), `var activeSurfaceID: String?` (private(set)), `var count: Int`, `var isEmpty: Bool`, `var handles: [Handle]`
  - `func index(of: String) -> Int?`, `func entry(for: String) -> Entry?`, `func handle(for: String) -> Handle?`
  - `var activeEntry: Entry?`, `var activeHandle: Handle?`, `var activeSurface: Surface?`
  - `func add(_ handle: Handle, surface: Surface)`
  - `@discardableResult func close(id: String) -> Handle?`
  - `func setActive(id: String)`, `@discardableResult func next() -> String?`, `@discardableResult func prev() -> String?`, `@discardableResult func goTo(index: Int) -> String?`
  - `func rename(id: String, to: String?)`, `func setColor(id: String, to: RGB?)`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ConductorCoreTests/WorktreeSurfacesTests.swift
import XCTest
@testable import ConductorCore

final class WorktreeSurfacesTests: XCTestCase {
    private func make() -> WorktreeSurfaces<String> { WorktreeSurfaces<String>() }

    func testAddAppendsAfterActiveAndActivatesIt() {
        let s = make()
        s.add("hA", surface: Surface(id: "a"))
        s.add("hB", surface: Surface(id: "b"))
        // Re-activate a, then add c: it should land between a and b.
        s.setActive(id: "a")
        s.add("hC", surface: Surface(id: "c"))
        XCTAssertEqual(s.entries.map { $0.surface.id }, ["a", "c", "b"])
        XCTAssertEqual(s.activeSurfaceID, "c")
    }

    func testAddToEmptyActivatesAndAppends() {
        let s = make()
        s.add("hA", surface: Surface(id: "a"))
        XCTAssertEqual(s.activeSurfaceID, "a")
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.activeHandle, "hA")
    }

    func testCloseActiveSelectsRightNeighbor() {
        let s = make()
        ["a", "b", "c"].forEach { s.add("h\($0)", surface: Surface(id: $0)) }
        s.setActive(id: "b")
        let removed = s.close(id: "b")
        XCTAssertEqual(removed, "hb")
        XCTAssertEqual(s.activeSurfaceID, "c")   // right neighbor
        XCTAssertEqual(s.entries.map { $0.surface.id }, ["a", "c"])
    }

    func testClosingLastActiveSelectsLeftNeighbor() {
        let s = make()
        ["a", "b"].forEach { s.add("h\($0)", surface: Surface(id: $0)) }
        s.setActive(id: "b")
        _ = s.close(id: "b")
        XCTAssertEqual(s.activeSurfaceID, "a")   // no right → left
    }

    func testClosingOnlySurfaceEmptiesAndClearsActive() {
        let s = make()
        s.add("hA", surface: Surface(id: "a"))
        _ = s.close(id: "a")
        XCTAssertTrue(s.isEmpty)
        XCTAssertNil(s.activeSurfaceID)
    }

    func testClosingNonActiveLeavesActiveUntouched() {
        let s = make()
        ["a", "b", "c"].forEach { s.add("h\($0)", surface: Surface(id: $0)) }
        s.setActive(id: "a")
        _ = s.close(id: "c")
        XCTAssertEqual(s.activeSurfaceID, "a")
    }

    func testNextAndPrevWrapAround() {
        let s = make()
        ["a", "b", "c"].forEach { s.add("h\($0)", surface: Surface(id: $0)) }
        s.setActive(id: "c")
        XCTAssertEqual(s.next(), "a")   // wrap forward
        XCTAssertEqual(s.prev(), "c")   // wrap backward
    }

    func testGoToIndexIsBoundsChecked() {
        let s = make()
        ["a", "b"].forEach { s.add("h\($0)", surface: Surface(id: $0)) }
        XCTAssertEqual(s.goTo(index: 0), "a")
        XCTAssertEqual(s.goTo(index: 5), "a")   // out of range → no change
        XCTAssertEqual(s.activeSurfaceID, "a")
    }

    func testRenameAndSetColorMutateMetadata() {
        let s = make()
        s.add("hA", surface: Surface(id: "a"))
        s.rename(id: "a", to: "logs")
        s.setColor(id: "a", to: RGB(r: 0, g: 1, b: 0))
        XCTAssertEqual(s.entry(for: "a")?.surface.nameOverride, "logs")
        XCTAssertEqual(s.entry(for: "a")?.surface.colorOverride, RGB(r: 0, g: 1, b: 0))
    }

    func testSetActiveIgnoresUnknownID() {
        let s = make()
        s.add("hA", surface: Surface(id: "a"))
        s.setActive(id: "ghost")
        XCTAssertEqual(s.activeSurfaceID, "a")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter WorktreeSurfacesTests`
Expected: FAIL — `Cannot find 'WorktreeSurfaces' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/ConductorCore/WorktreeSurfaces.swift
import Foundation

/// An ordered list of terminal surfaces ("tabs") for one worktree, plus the active
/// surface. Generic over `Handle` (the shell stores a `TerminalSurface`); pure so the
/// ordering/active rules are unit-testable with a stub handle.
public final class WorktreeSurfaces<Handle> {
    public struct Entry {
        public var surface: Surface
        public let handle: Handle
        public init(surface: Surface, handle: Handle) { self.surface = surface; self.handle = handle }
    }

    public private(set) var entries: [Entry] = []
    public private(set) var activeSurfaceID: String?

    public init() {}

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    public var handles: [Handle] { entries.map { $0.handle } }

    public func index(of id: String) -> Int? { entries.firstIndex { $0.surface.id == id } }
    public func entry(for id: String) -> Entry? { index(of: id).map { entries[$0] } }
    public func handle(for id: String) -> Handle? { entry(for: id)?.handle }

    public var activeEntry: Entry? { activeSurfaceID.flatMap { entry(for: $0) } }
    public var activeHandle: Handle? { activeEntry?.handle }
    public var activeSurface: Surface? { activeEntry?.surface }

    /// Insert a new surface after the active one (end if none) and make it active.
    public func add(_ handle: Handle, surface: Surface) {
        let insertAt = activeSurfaceID.flatMap { index(of: $0) }.map { $0 + 1 } ?? entries.count
        entries.insert(Entry(surface: surface, handle: handle), at: insertAt)
        activeSurfaceID = surface.id
    }

    /// Remove a surface, returning its handle. If it was active, select the right
    /// neighbor, else the left, else nil (worktree now empty).
    @discardableResult
    public func close(id: String) -> Handle? {
        guard let i = index(of: id) else { return nil }
        let removed = entries.remove(at: i)
        if activeSurfaceID == id {
            activeSurfaceID = entries.isEmpty ? nil : entries[min(i, entries.count - 1)].surface.id
        }
        return removed.handle
    }

    public func setActive(id: String) { if index(of: id) != nil { activeSurfaceID = id } }

    @discardableResult public func next() -> String? { advance(by: 1) }
    @discardableResult public func prev() -> String? { advance(by: -1) }

    private func advance(by step: Int) -> String? {
        guard !entries.isEmpty else { return nil }
        guard let cur = activeSurfaceID, let i = index(of: cur) else {
            activeSurfaceID = entries.first?.surface.id
            return activeSurfaceID
        }
        let n = entries.count
        activeSurfaceID = entries[((i + step) % n + n) % n].surface.id
        return activeSurfaceID
    }

    /// Activate the surface at a zero-based index; out-of-range is a no-op. Returns the active id.
    @discardableResult
    public func goTo(index: Int) -> String? {
        guard entries.indices.contains(index) else { return activeSurfaceID }
        activeSurfaceID = entries[index].surface.id
        return activeSurfaceID
    }

    public func rename(id: String, to name: String?) {
        guard let i = index(of: id) else { return }
        entries[i].surface.nameOverride = name
    }

    public func setColor(id: String, to color: RGB?) {
        guard let i = index(of: id) else { return }
        entries[i].surface.colorOverride = color
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter WorktreeSurfacesTests`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ConductorCore/WorktreeSurfaces.swift Tests/ConductorCoreTests/WorktreeSurfacesTests.swift
git commit -m "feat(core): WorktreeSurfaces ordered surface list + active tracking"
```

---

## Task 4: Core — rework `SurfaceRegistry` to two-level

**Files:**
- Modify (replace whole file): `Sources/ConductorCore/SurfaceRegistry.swift`
- Test (rewrite): `Tests/ConductorCoreTests/SurfaceRegistryTests.swift`

**Interfaces:**
- Consumes: `WorktreeSurfaces<Handle>`.
- Produces: `final class SurfaceRegistry<Handle>` with:
  - `var activeWorktreeID: String?` (private(set))
  - `func surfaces(for worktreeID: String) -> WorktreeSurfaces<Handle>` (creates on first access)
  - `func existingSurfaces(for worktreeID: String) -> WorktreeSurfaces<Handle>?`
  - `func setActive(_ worktreeID: String?)`
  - `@discardableResult func evict(worktreeID: String) -> [Handle]`
  - `var worktreeIDs: [String]`

> **Migration note:** The old flat API (`register(_:for:)`, `handle(for:)`, `count`, `evict → Handle?`) is removed. AppDelegate (Task 8) and these tests move to the new API.

- [ ] **Step 1: Rewrite the test file**

Replace the entire contents of `Tests/ConductorCoreTests/SurfaceRegistryTests.swift`:

```swift
import XCTest
@testable import ConductorCore

final class SurfaceRegistryTests: XCTestCase {
    func testSurfacesForNewWorktreeIsCreatedEmpty() {
        let registry = SurfaceRegistry<String>()
        let list = registry.surfaces(for: "wt1")
        XCTAssertTrue(list.isEmpty)
        // Same instance returned on re-access (mutations persist).
        registry.surfaces(for: "wt1").add("h", surface: Surface(id: "s1"))
        XCTAssertEqual(registry.surfaces(for: "wt1").count, 1)
    }

    func testExistingSurfacesIsNilUntilCreated() {
        let registry = SurfaceRegistry<String>()
        XCTAssertNil(registry.existingSurfaces(for: "wt1"))
        _ = registry.surfaces(for: "wt1")
        XCTAssertNotNil(registry.existingSurfaces(for: "wt1"))
    }

    func testActiveSelectionTracksTheActiveWorktree() {
        let registry = SurfaceRegistry<String>()
        XCTAssertNil(registry.activeWorktreeID)
        registry.setActive("wt1")
        XCTAssertEqual(registry.activeWorktreeID, "wt1")
        registry.setActive(nil)
        XCTAssertNil(registry.activeWorktreeID)
    }

    func testEvictReturnsAllHandlesAndRemovesTheWorktree() {
        let registry = SurfaceRegistry<String>()
        let list = registry.surfaces(for: "wt1")
        list.add("h1", surface: Surface(id: "s1"))
        list.add("h2", surface: Surface(id: "s2"))
        let evicted = registry.evict(worktreeID: "wt1")
        XCTAssertEqual(evicted.sorted(), ["h1", "h2"])
        XCTAssertNil(registry.existingSurfaces(for: "wt1"))
    }

    func testEvictingTheActiveWorktreeClearsActive() {
        let registry = SurfaceRegistry<String>()
        _ = registry.surfaces(for: "wt1")
        registry.setActive("wt1")
        _ = registry.evict(worktreeID: "wt1")
        XCTAssertNil(registry.activeWorktreeID)
    }

    func testEvictingNonActiveLeavesActiveUntouched() {
        let registry = SurfaceRegistry<String>()
        _ = registry.surfaces(for: "wt1")
        _ = registry.surfaces(for: "wt2")
        registry.setActive("wt1")
        _ = registry.evict(worktreeID: "wt2")
        XCTAssertEqual(registry.activeWorktreeID, "wt1")
    }

    func testEvictingMissingWorktreeReturnsEmpty() {
        let registry = SurfaceRegistry<String>()
        XCTAssertEqual(registry.evict(worktreeID: "ghost"), [])
    }

    func testWorktreeIDsListsWorktreesWithSurfaceLists() {
        let registry = SurfaceRegistry<String>()
        _ = registry.surfaces(for: "wt1")
        _ = registry.surfaces(for: "wt2")
        XCTAssertEqual(Set(registry.worktreeIDs), ["wt1", "wt2"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SurfaceRegistryTests`
Expected: FAIL — old `SurfaceRegistry` lacks `surfaces(for:)` etc. (compile error).

- [ ] **Step 3: Replace the implementation**

Replace the entire contents of `Sources/ConductorCore/SurfaceRegistry.swift`:

```swift
import Foundation

/// Tracks each worktree's ordered list of terminal surfaces plus the active worktree,
/// so the shell keeps surfaces alive across sidebar switches and tears them all down on
/// archive. Pure: `Handle` is whatever the shell stores (a `TerminalSurface`).
public final class SurfaceRegistry<Handle> {
    private var worktrees: [String: WorktreeSurfaces<Handle>] = [:]
    public private(set) var activeWorktreeID: String?

    public init() {}

    /// The surface list for a worktree, creating an empty one on first access. Returns the
    /// same class instance each time, so mutations through it persist.
    public func surfaces(for worktreeID: String) -> WorktreeSurfaces<Handle> {
        if let existing = worktrees[worktreeID] { return existing }
        let fresh = WorktreeSurfaces<Handle>()
        worktrees[worktreeID] = fresh
        return fresh
    }

    /// Peek without creating — nil if the worktree has never had a surface.
    public func existingSurfaces(for worktreeID: String) -> WorktreeSurfaces<Handle>? {
        worktrees[worktreeID]
    }

    /// Mark the active worktree (the one whose surfaces are on screen). Idempotent.
    public func setActive(_ worktreeID: String?) { activeWorktreeID = worktreeID }

    /// Remove a worktree's entire surface list (on archive); returns all handles so the
    /// shell can tear down every PTY. Clears the active selection if it was this worktree.
    @discardableResult
    public func evict(worktreeID: String) -> [Handle] {
        let removed = worktrees.removeValue(forKey: worktreeID)
        if activeWorktreeID == worktreeID { activeWorktreeID = nil }
        return removed?.handles ?? []
    }

    /// Worktree ids that currently have a surface list (for badge polling).
    public var worktreeIDs: [String] { Array(worktrees.keys) }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SurfaceRegistryTests`
Expected: PASS (8 tests). (The `Conductor` shell target will NOT build yet — AppDelegate still uses the old API. That's fixed in Task 8. `swift test` builds only the test targets + their deps; if the shell target is in the test graph and fails, proceed — Task 8 restores it. Run `swift test` per-filter here.)

- [ ] **Step 5: Commit**

```bash
git add Sources/ConductorCore/SurfaceRegistry.swift Tests/ConductorCoreTests/SurfaceRegistryTests.swift
git commit -m "feat(core): rework SurfaceRegistry to two-level (worktree → surfaces)"
```

---

## Task 5: Core — surface `ShortcutCommand` cases + category

**Files:**
- Modify: `Sources/ConductorCore/Keybindings.swift` (extend `ShortcutCategory` and `ShortcutCommand`)
- Test: `Tests/ConductorCoreTests/KeybindingsTests.swift` (append) and `Tests/ConductorCoreTests/KeybindingConflictsTests.swift` (append a defaults-clean assertion if not present)

**Interfaces:**
- Produces: new `ShortcutCommand` cases `newSurface, closeSurface, nextSurface, prevSurface, splitSurface, goToSurface1…goToSurface9`, all in category `.surface`, each with a `defaultChord`. New `ShortcutCategory.surface`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/ConductorCoreTests/KeybindingsTests.swift`:

```swift
final class SurfaceShortcutTests: XCTestCase {
    func testNewSurfaceDefaultsToCommandT() {
        XCTAssertEqual(ShortcutCommand.newSurface.defaultChord, KeyChord("t", command: true))
    }
    func testCloseSurfaceDefaultsToCommandW() {
        XCTAssertEqual(ShortcutCommand.closeSurface.defaultChord, KeyChord("w", command: true))
    }
    func testNextPrevDefaults() {
        XCTAssertEqual(ShortcutCommand.nextSurface.defaultChord, KeyChord("]", command: true, shift: true))
        XCTAssertEqual(ShortcutCommand.prevSurface.defaultChord, KeyChord("[", command: true, shift: true))
    }
    func testSplitDefaultsToCommandD() {
        XCTAssertEqual(ShortcutCommand.splitSurface.defaultChord, KeyChord("d", command: true))
    }
    func testGoToSurfaceDefaultsAreCommandDigits() {
        XCTAssertEqual(ShortcutCommand.goToSurface1.defaultChord, KeyChord("1", command: true))
        XCTAssertEqual(ShortcutCommand.goToSurface9.defaultChord, KeyChord("9", command: true))
    }
    func testAllSurfaceCommandsAreInSurfaceCategory() {
        let surfaceCmds: [ShortcutCommand] = [.newSurface, .closeSurface, .nextSurface,
            .prevSurface, .splitSurface, .goToSurface1, .goToSurface5, .goToSurface9]
        for cmd in surfaceCmds { XCTAssertEqual(cmd.category, .surface) }
    }
    func testDefaultBindingsHaveNoConflicts() {
        XCTAssertTrue(keybindingConflicts(Keybindings()).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SurfaceShortcutTests`
Expected: FAIL — `Type 'ShortcutCommand' has no member 'newSurface'`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/ConductorCore/Keybindings.swift`, extend `ShortcutCategory` (add `surface` case + its `displayName` + `order`):

```swift
public enum ShortcutCategory: String, CaseIterable, Sendable {
    case worktree, surface, repository, view, app
    public var displayName: String {
        switch self {
        case .worktree: return "Worktree"
        case .surface: return "Surfaces"
        case .repository: return "Repository"
        case .view: return "View"
        case .app: return "App"
        }
    }
    public var order: Int {
        switch self {
        case .worktree: return 0
        case .surface: return 1
        case .repository: return 2
        case .view: return 3
        case .app: return 4
        }
    }
}
```

Then extend `ShortcutCommand` — add the cases to the declaration line, and add a branch to each of the three switches (`displayName`, `category`, `defaultChord`):

```swift
public enum ShortcutCommand: String, Codable, CaseIterable, Sendable {
    case newWorktree, launchClaude, openInEditor, revealInFinder, archiveWorktree
    case addRepository, toggleSidebar, openSettings
    case newSurface, closeSurface, nextSurface, prevSurface, splitSurface
    case goToSurface1, goToSurface2, goToSurface3, goToSurface4, goToSurface5
    case goToSurface6, goToSurface7, goToSurface8, goToSurface9

    public var displayName: String {
        switch self {
        case .newWorktree: return "New Worktree"
        case .launchClaude: return "Launch Claude"
        case .openInEditor: return "Open in Editor"
        case .revealInFinder: return "Reveal in Finder"
        case .archiveWorktree: return "Archive Worktree"
        case .addRepository: return "Add Repository"
        case .toggleSidebar: return "Toggle Sidebar"
        case .openSettings: return "Settings"
        case .newSurface: return "New Tab"
        case .closeSurface: return "Close Tab"
        case .nextSurface: return "Next Tab"
        case .prevSurface: return "Previous Tab"
        case .splitSurface: return "Split Surface"
        case .goToSurface1: return "Go to Tab 1"
        case .goToSurface2: return "Go to Tab 2"
        case .goToSurface3: return "Go to Tab 3"
        case .goToSurface4: return "Go to Tab 4"
        case .goToSurface5: return "Go to Tab 5"
        case .goToSurface6: return "Go to Tab 6"
        case .goToSurface7: return "Go to Tab 7"
        case .goToSurface8: return "Go to Tab 8"
        case .goToSurface9: return "Go to Tab 9"
        }
    }

    public var category: ShortcutCategory {
        switch self {
        case .newWorktree, .launchClaude, .openInEditor, .revealInFinder, .archiveWorktree:
            return .worktree
        case .newSurface, .closeSurface, .nextSurface, .prevSurface, .splitSurface,
             .goToSurface1, .goToSurface2, .goToSurface3, .goToSurface4, .goToSurface5,
             .goToSurface6, .goToSurface7, .goToSurface8, .goToSurface9:
            return .surface
        case .addRepository: return .repository
        case .toggleSidebar: return .view
        case .openSettings: return .app
        }
    }

    public var defaultChord: KeyChord {
        switch self {
        case .newWorktree:     return KeyChord("n", command: true)
        case .launchClaude:    return KeyChord("r", command: true)
        case .openInEditor:    return KeyChord("o", command: true)
        case .revealInFinder:  return KeyChord("r", command: true, option: true)
        case .archiveWorktree: return KeyChord("\u{8}", command: true)
        case .addRepository:   return KeyChord("n", command: true, shift: true)
        case .toggleSidebar:   return KeyChord("s", command: true, control: true)
        case .openSettings:    return KeyChord(",", command: true)
        case .newSurface:      return KeyChord("t", command: true)
        case .closeSurface:    return KeyChord("w", command: true)
        case .nextSurface:     return KeyChord("]", command: true, shift: true)
        case .prevSurface:     return KeyChord("[", command: true, shift: true)
        case .splitSurface:    return KeyChord("d", command: true)
        case .goToSurface1:    return KeyChord("1", command: true)
        case .goToSurface2:    return KeyChord("2", command: true)
        case .goToSurface3:    return KeyChord("3", command: true)
        case .goToSurface4:    return KeyChord("4", command: true)
        case .goToSurface5:    return KeyChord("5", command: true)
        case .goToSurface6:    return KeyChord("6", command: true)
        case .goToSurface7:    return KeyChord("7", command: true)
        case .goToSurface8:    return KeyChord("8", command: true)
        case .goToSurface9:    return KeyChord("9", command: true)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SurfaceShortcutTests`
Expected: PASS. Then run the full Core suite to catch any category-count assumptions:
Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ConductorCoreTests`
Expected: all green. If a pre-existing `KeybindingsTests`/`KeybindingConflictsTests` hard-codes the category or command count, update its expected value to include the new entries.

- [ ] **Step 5: Commit**

```bash
git add Sources/ConductorCore/Keybindings.swift Tests/ConductorCoreTests/KeybindingsTests.swift Tests/ConductorCoreTests/KeybindingConflictsTests.swift
git commit -m "feat(core): surface shortcut commands (new/close/next/prev/goto/split) + Surfaces category"
```

---

## Task 6: Shell — `SurfaceTabBar` view

**Files:**
- Create: `Sources/Conductor/SurfaceTabBar.swift`

**Interfaces:**
- Consumes: `AgentState`, `agentBadgeColor(_:)` (existing, in `SidebarController.swift`), `RGB`.
- Produces:
  - `struct SurfaceTabItem { let id: String; let label: String; let state: AgentState; let isActive: Bool; let tint: NSColor? }`
  - `final class SurfaceTabBar: NSView` with `static let height: CGFloat`, callbacks `onSelect/onClose/onNew: ...`, `onContext: ((String, NSView) -> Void)?`, and `func update(items: [SurfaceTabItem])`.

This view has no unit tests (AppKit); it's verified in-app in Task 8.

- [ ] **Step 1: Create the view**

```swift
// Sources/Conductor/SurfaceTabBar.swift
import AppKit
import ConductorCore

/// One tab's display state, computed by AppDelegate from Core's Surface + live title + badge.
struct SurfaceTabItem {
    let id: String
    let label: String
    let state: AgentState
    let isActive: Bool
    /// The tab's effective identity color (per-tab override → worktree color), or nil.
    let tint: NSColor?
}

/// The per-worktree surface tab bar: a horizontal row of tab buttons (badge dot + label +
/// close ×) and a trailing "+" to open a new tab. Sits between the identity bar and the
/// terminal. Rebuilt wholesale on `update(items:)`; it holds no model state of its own.
final class SurfaceTabBar: NSView {
    static let height: CGFloat = 28

    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onNew: (() -> Void)?
    /// Right-click on a tab → (surfaceID, anchorView) so the caller can pop a context menu.
    var onContext: ((String, NSView) -> Void)?

    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func update(items: [SurfaceTabItem]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items { stack.addArrangedSubview(makeTab(item)) }
        let plus = NSButton(title: "+", target: self, action: #selector(newTapped))
        plus.bezelStyle = .texturedRounded
        plus.setButtonType(.momentaryPushIn)
        stack.addArrangedSubview(plus)
    }

    @objc private func newTapped() { onNew?() }

    private func makeTab(_ item: SurfaceTabItem) -> NSView {
        let tab = TabButtonView(id: item.id)
        tab.translatesAutoresizingMaskIntoConstraints = false
        tab.wantsLayer = true
        tab.layer?.cornerRadius = 5
        tab.layer?.backgroundColor = (item.isActive
            ? NSColor.selectedControlColor.withAlphaComponent(0.35)
            : NSColor.clear).cgColor
        tab.onClick = { [weak self] in self?.onSelect?(item.id) }
        tab.onContext = { [weak self] view in self?.onContext?(item.id, view) }

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        if let c = agentBadgeColor(item.state) {
            dot.layer?.backgroundColor = c.cgColor
            dot.isHidden = false
        } else {
            dot.isHidden = true
        }

        let label = NSTextField(labelWithString: item.label)
        label.font = .systemFont(ofSize: 11, weight: item.isActive ? .semibold : .regular)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = item.tint ?? .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let close = NSButton(title: "", target: tab, action: #selector(TabButtonView.closeTapped))
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        close.imageScaling = .scaleProportionallyDown
        close.isBordered = false
        close.translatesAutoresizingMaskIntoConstraints = false
        tab.onClose = { [weak self] in self?.onClose?(item.id) }

        let row = NSStackView(views: [dot, label, close])
        row.orientation = .horizontal
        row.spacing = 5
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 6)
        row.translatesAutoresizingMaskIntoConstraints = false
        tab.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: tab.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: tab.trailingAnchor),
            row.topAnchor.constraint(equalTo: tab.topAnchor),
            row.bottomAnchor.constraint(equalTo: tab.bottomAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            close.widthAnchor.constraint(equalToConstant: 14),
            close.heightAnchor.constraint(equalToConstant: 14),
            tab.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            tab.heightAnchor.constraint(equalToConstant: 22),
        ])
        return tab
    }
}

/// A clickable tab background that reports left-click (select), the close button, and
/// right-click (context menu) back to the bar.
private final class TabButtonView: NSView {
    let id: String
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    var onContext: ((NSView) -> Void)?
    init(id: String) { self.id = id; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onContext?(self) }
    @objc func closeTapped() { onClose?() }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: the shell target still won't link `AppDelegate` (uses old registry API) — that's Task 8. Confirm `SurfaceTabBar.swift` itself produces no errors (no diagnostics mentioning `SurfaceTabBar.swift`). If `swift build` fails only inside `AppDelegate.swift`, proceed.

- [ ] **Step 3: Commit**

```bash
git add Sources/Conductor/SurfaceTabBar.swift
git commit -m "feat(app): SurfaceTabBar view (tabs, badges, close, new)"
```

---

## Task 7: Shell — extract shared Set-Color submenu helper

**Files:**
- Create: `Sources/Conductor/ColorMenu.swift`
- Modify: `Sources/Conductor/SidebarController.swift` (replace the two near-duplicate Set-Color blocks)

This is the DRY refactor flagged as deferred tech-debt in PR #27. Pure mechanical extraction; verified by the existing app behavior staying identical (sidebar Set-Color still works) — confirm by build + the Task 8 in-app run.

**Interfaces:**
- Consumes: `IdentityPalette.colors`, `NSColor(hex:)` (existing extension).
- Produces: `enum ColorMenu { static func swatchImage(_:) -> NSImage; static func makeSetColorItem(targetID:target:setColor:removeColor:) -> NSMenuItem }`

- [ ] **Step 1: Create the helper**

```swift
// Sources/Conductor/ColorMenu.swift
import AppKit
import ConductorCore

/// Builds the reusable "Set Color ▸ (swatches…) / Remove Color" submenu used by the
/// sidebar (repo + worktree rows) and the surface tab bar. The `setColor` selector
/// receives an item whose `representedObject` is `["id": targetID, "hex": hex]`; the
/// `removeColor` selector receives an item whose `representedObject` is `targetID`.
enum ColorMenu {
    /// A small rounded filled square for a color menu item.
    static func swatchImage(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 2, yRadius: 2).fill()
        image.unlockFocus()
        return image
    }

    /// A top-level "Set Color" item whose submenu is the palette swatches + "Remove Color".
    static func makeSetColorItem(targetID: String, target: AnyObject,
                                 setColor: Selector, removeColor: Selector) -> NSMenuItem {
        let colorItem = NSMenuItem(title: "Set Color", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()
        for hex in IdentityPalette.colors {
            let swatch = NSMenuItem(title: hex, action: setColor, keyEquivalent: "")
            swatch.target = target
            swatch.representedObject = ["id": targetID, "hex": hex]
            if let color = NSColor(hex: hex) { swatch.image = swatchImage(color) }
            colorMenu.addItem(swatch)
        }
        colorMenu.addItem(.separator())
        let remove = NSMenuItem(title: "Remove Color", action: removeColor, keyEquivalent: "")
        remove.target = target
        remove.representedObject = targetID
        colorMenu.addItem(remove)
        colorItem.submenu = colorMenu
        return colorItem
    }
}
```

- [ ] **Step 2: Refactor `SidebarController.menuNeedsUpdate` to use it**

In `Sources/Conductor/SidebarController.swift`, replace the repo-header color block (the `let colorItem = NSMenuItem(title: "Set Color"…` … `menu.addItem(colorItem)` inside `if clickedWorktreeID() == nil`) with:

```swift
            menu.addItem(ColorMenu.makeSetColorItem(
                targetID: repoID, target: self,
                setColor: #selector(contextSetRepoColor(_:)),
                removeColor: #selector(contextRemoveRepoColor(_:))))
```

And replace the worktree color block (inside `if let worktreeID = clickedWorktreeID()`) with:

```swift
            menu.addItem(.separator())
            menu.addItem(ColorMenu.makeSetColorItem(
                targetID: worktreeID, target: self,
                setColor: #selector(contextSetColor(_:)),
                removeColor: #selector(contextRemoveColor(_:))))
```

Then delete the now-unused `private static func swatchImage(...)` from `SidebarController` (it moved to `ColorMenu`).

- [ ] **Step 3: Build to verify it compiles**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: `SidebarController.swift` and `ColorMenu.swift` produce no diagnostics (AppDelegate may still fail — Task 8).

- [ ] **Step 4: Commit**

```bash
git add Sources/Conductor/ColorMenu.swift Sources/Conductor/SidebarController.swift
git commit -m "refactor(app): extract shared ColorMenu Set-Color submenu (DRY repo/worktree)"
```

---

## Task 8: Shell — multi-surface lifecycle in AppDelegate + Surface menu + keybinds

**Files:**
- Modify: `Sources/Conductor/AppDelegate.swift`

This is the largest task: it makes tabs actually work and is independently verifiable (create/close/switch tabs by mouse and keyboard). It rewrites the surface-management methods to drive the two-level registry and the `SurfaceTabBar`, adds the new/close/next/prev/goto actions, the "Surface" menu, and routes the new `ShortcutCommand`s through the existing `apply(_:to:)` keybind machinery.

**Interfaces:**
- Consumes: `SurfaceRegistry` (new API), `WorktreeSurfaces`, `Surface`, `surfaceLabel(...)`, `SurfaceTabBar`, `SurfaceTabItem`, the new `ShortcutCommand` cases.

- [ ] **Step 1: Add state + the tab bar to the detail view**

Replace the stored property `private var currentSurface: TerminalSurface?` region by adding, near the other detail-related properties (after `private let worktreeBar = WorktreeBar()`):

```swift
    private let surfaceTabBar = SurfaceTabBar()
    private var surfaceSeq = 0   // monotonic id source for new surfaces
```

In `buildWindow()`, after the `worktreeBar` constraints block and before `worktreeBar.isHidden = true`, add the tab bar between the identity bar and the (later) terminal:

```swift
        detail.view.addSubview(surfaceTabBar)
        NSLayoutConstraint.activate([
            surfaceTabBar.topAnchor.constraint(equalTo: worktreeBar.bottomAnchor, constant: 6),
            surfaceTabBar.leadingAnchor.constraint(equalTo: detail.view.leadingAnchor, constant: 8),
            surfaceTabBar.trailingAnchor.constraint(equalTo: detail.view.trailingAnchor, constant: -8),
        ])
        surfaceTabBar.isHidden = true
        surfaceTabBar.onNew = { [weak self] in self?.newSurface() }
        surfaceTabBar.onSelect = { [weak self] id in self?.activateSurface(id) }
        surfaceTabBar.onClose = { [weak self] id in self?.closeSurface(id) }
        surfaceTabBar.onContext = { [weak self] id, view in self?.showSurfaceContextMenu(id, anchor: view) }
```

In `wireSidebar()` nothing changes. Note the surface view's top anchor changes from `worktreeBar.bottomAnchor` to `surfaceTabBar.bottomAnchor` (Step 3).

- [ ] **Step 2: Replace `select(_:)` with multi-surface-aware version**

Replace the entire `private func select(_ s: Worktree?)` method with:

```swift
    private func select(_ s: Worktree?) {
        guard shownWorktreeID != s?.id else { return }   // idempotent
        shownWorktreeID = s?.id
        selectedWorktree = s
        updateNotch()

        // Hide (don't destroy) the leaving worktree's active surface — its PTY keeps running.
        if let leavingID = surfaces.activeWorktreeID,
           let leaving = surfaces.existingSurfaces(for: leavingID)?.activeHandle {
            leaving.view.isHidden = true
        }
        surfaces.setActive(s?.id)
        currentSurface = nil

        guard let s else {
            worktreeBar.update(title: nil, branch: nil, colorHex: nil, agentState: .idle)
            surfaceTabBar.isHidden = true
            return
        }

        let list = surfaces.surfaces(for: s.id)
        if list.isEmpty {
            // First open (or re-focus after the last tab was closed): spawn one shell.
            createSurface(in: s, runSetupAndAutoLaunch: true)
        } else if let active = list.activeHandle {
            active.view.isHidden = false
            currentSurface = active
        }
        refreshChromeForActiveSurface()
        refreshTabBar()
    }
```

- [ ] **Step 3: Add the surface-creation + activation + tab-bar helpers**

Add these new methods (e.g. right after `select(_:)`):

```swift
    /// Build a fresh TerminalSurface for `wt`, register it, install it in the detail view,
    /// make it the active surface, and focus it. `runSetupAndAutoLaunch` is true only for the
    /// worktree's very first surface (mirrors the old first-open behavior: setupScript +
    /// optional auto-launch Claude); additional tabs are always plain shells.
    @discardableResult
    private func createSurface(in wt: Worktree, runSetupAndAutoLaunch: Bool) -> TerminalSurface {
        let repo = store.state.repositories.first { $0.id == wt.repoID }
        let isNewlyCreated = runSetupAndAutoLaunch && pendingSetupWorktreeIDs.contains(wt.id)
        let setup = isNewlyCreated ? (repo?.setupScript ?? "") : ""
        pendingSetupWorktreeIDs.remove(wt.id)
        let command = (isNewlyCreated && repo?.autoLaunchClaude == true) ? launchCommand(for: repo!) : ""

        let surface = TerminalSurface(workingDirectory: wt.worktreePath, command: command, setupScript: setup)
        surface.onOpenFile = { [weak self] path, line in self?.openInDefaultEditor(path: path, line: line) }
        surface.onTitleChange = { [weak self] _ in self?.refreshTabBar() }
        surface.applyTheme(activeTheme)
        surface.applyFont(resolvedTerminalFont())

        surfaceSeq += 1
        let id = "surface-\(surfaceSeq)"
        let list = surfaces.surfaces(for: wt.id)
        // Hide the current active surface (we're inserting after it and switching to the new one).
        list.activeHandle?.view.isHidden = true
        list.add(surface, surface: Surface(id: id))

        detail.addChild(surface)
        surface.view.translatesAutoresizingMaskIntoConstraints = false
        detail.view.addSubview(surface.view)
        NSLayoutConstraint.activate([
            surface.view.topAnchor.constraint(equalTo: surfaceTabBar.bottomAnchor, constant: 6),
            surface.view.bottomAnchor.constraint(equalTo: detail.view.bottomAnchor),
            surface.view.leadingAnchor.constraint(equalTo: detail.view.leadingAnchor, constant: 8),
            surface.view.trailingAnchor.constraint(equalTo: detail.view.trailingAnchor, constant: -8),
        ])
        currentSurface = surface
        view(focus: surface)
        refreshChromeForActiveSurface()
        refreshTabBar()
        return surface
    }

    /// Switch the shown worktree's active surface to `id`: hide the old, show the new, focus it.
    private func activateSurface(_ id: String) {
        guard let wtID = shownWorktreeID, let list = surfaces.existingSurfaces(for: wtID),
              list.activeSurfaceID != id, let handle = list.handle(for: id) else { return }
        list.activeHandle?.view.isHidden = true
        list.setActive(id: id)
        handle.view.isHidden = false
        currentSurface = handle
        view(focus: handle)
        refreshChromeForActiveSurface()
        refreshTabBar()
    }

    private func view(focus surface: TerminalSurface) {
        window.makeFirstResponder(surface.view)
    }

    /// Rebuild the tab bar from the shown worktree's surface list.
    private func refreshTabBar() {
        guard let wtID = shownWorktreeID, let list = surfaces.existingSurfaces(for: wtID),
              !list.isEmpty else {
            surfaceTabBar.isHidden = true
            return
        }
        surfaceTabBar.isHidden = false
        let worktreeColor = selectedWorktree?.color.flatMap { RGB(hex: $0) }
        let items: [SurfaceTabItem] = list.entries.enumerated().map { idx, entry in
            let effective = entry.surface.effectiveColor(worktreeColor: worktreeColor)
            return SurfaceTabItem(
                id: entry.surface.id,
                label: surfaceLabel(nameOverride: entry.surface.nameOverride,
                                    terminalTitle: entry.handle.terminalTitle, index: idx),
                state: agentStates[surfaceKey(wtID, entry.surface.id)] ?? .idle,
                isActive: entry.surface.id == list.activeSurfaceID,
                tint: effective?.nsColor)
        }
        surfaceTabBar.update(items: items)
    }

    /// Composite key for the per-surface agent-state map (Task 10 populates it).
    private func surfaceKey(_ worktreeID: String, _ surfaceID: String) -> String {
        "\(worktreeID)#\(surfaceID)"
    }
```

> **Note:** `TerminalSurface.onTitleChange` and `.terminalTitle` are added in Step 7. `RGB.nsColor` already exists (used in `WorktreeBar`/`ThemeAppKit`).

- [ ] **Step 4: Add `newSurface` / `closeSurface` / `nextSurface` / `prevSurface` / `goToSurface`**

Add these methods (near the other actions):

```swift
    private func newSurface() {
        guard let wt = selectedWorktree else { presentMessage("Select a worktree first."); return }
        createSurface(in: wt, runSetupAndAutoLaunch: false)
    }

    /// Close a specific surface (defaults to the active one). Confirms if it looks busy
    /// (non-idle agent state). Closing the last surface leaves the worktree empty.
    private func closeSurface(_ id: String? = nil) {
        guard let wtID = shownWorktreeID, let list = surfaces.existingSurfaces(for: wtID) else { return }
        guard let targetID = id ?? list.activeSurfaceID else { return }
        let state = agentStates[surfaceKey(wtID, targetID)] ?? .idle
        if state != .idle {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Close this tab?"
            alert.informativeText = "A process is still running in this tab. Closing it ends that process."
            alert.addButton(withTitle: "Close Tab")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if let removed = list.close(id: targetID) {
            removed.view.removeFromSuperview()
            removed.removeFromParent()
        }
        if let newActive = list.activeHandle {
            newActive.view.isHidden = false
            currentSurface = newActive
            view(focus: newActive)
        } else {
            // Last tab closed: worktree is now empty. Allow re-focus to spawn a fresh shell.
            currentSurface = nil
            shownWorktreeID = nil
            surfaces.setActive(nil)
        }
        refreshChromeForActiveSurface()
        refreshTabBar()
    }

    private func nextSurface() {
        guard let wtID = shownWorktreeID, let list = surfaces.existingSurfaces(for: wtID),
              let id = list.next() else { return }
        activateSurfaceAfterListMove(id, in: list)
    }

    private func prevSurface() {
        guard let wtID = shownWorktreeID, let list = surfaces.existingSurfaces(for: wtID),
              let id = list.prev() else { return }
        activateSurfaceAfterListMove(id, in: list)
    }

    private func goToSurface(_ oneBased: Int) {
        guard let wtID = shownWorktreeID, let list = surfaces.existingSurfaces(for: wtID),
              let id = list.goTo(index: oneBased - 1) else { return }
        activateSurfaceAfterListMove(id, in: list)
    }

    /// `next/prev/goTo` already moved the list's active id; reflect it in the views.
    private func activateSurfaceAfterListMove(_ id: String, in list: WorktreeSurfaces<TerminalSurface>) {
        for entry in list.entries { entry.handle.view.isHidden = (entry.surface.id != id) }
        currentSurface = list.handle(for: id)
        if let h = currentSurface { view(focus: h) }
        refreshChromeForActiveSurface()
        refreshTabBar()
    }
```

- [ ] **Step 5: Update `archive`, `launchClaudeAction`, theme/font fan-out, and chrome to the new API**

In `archive(_:)`, replace the eviction block:

```swift
            // Tear down all of the archived worktree's surfaces (kills every PTY, no leak).
            for surface in surfaces.evict(worktreeID: s.id) {
                surface.view.removeFromSuperview()
                surface.removeFromParent()
            }
            if shownWorktreeID == s.id { shownWorktreeID = nil; currentSurface = nil }
```

In `launchClaudeAction()`, it already uses `currentSurface` — leave as is (it runs in the active surface, which is exactly the desired behavior).

In `applyActiveTheme()`, replace the per-worktree loop:

```swift
    private func applyActiveTheme() {
        for wtID in surfaces.worktreeIDs {
            surfaces.existingSurfaces(for: wtID)?.handles.forEach { $0.applyTheme(activeTheme) }
        }
        applyChromeTheme()
    }
```

In `setTerminalFont(_:)`, replace the per-worktree loop:

```swift
        let font = resolvedTerminalFont()
        for wtID in surfaces.worktreeIDs {
            surfaces.existingSurfaces(for: wtID)?.handles.forEach { $0.applyFont(font) }
        }
```

Add a helper that drives the identity bar + sidebar accent from the **active surface's effective color** (full implementation in Task 9; for Task 8 a minimal version keeps the bar working):

```swift
    /// Repaint the identity bar from the shown worktree + active surface's effective color.
    private func refreshChromeForActiveSurface() {
        guard let wt = selectedWorktree else {
            worktreeBar.update(title: nil, branch: nil, colorHex: nil, agentState: .idle)
            return
        }
        let worktreeColor = wt.color.flatMap { RGB(hex: $0) }
        let active = surfaces.existingSurfaces(for: wt.id)?.activeSurface
        let effective = active?.effectiveColor(worktreeColor: worktreeColor) ?? worktreeColor
        worktreeBar.update(title: wt.title, branch: wt.branch,
                           colorHex: effective?.hexString,
                           agentState: agentStates[wt.id] ?? .idle)
    }
```

The old `pollAgentStates` and `setWorktreeColor` call `surfaces.handle(for:)` / `worktreeBar.update(...)` directly, which no longer compile against the new registry. Rewrite both now (an interim `pollAgentStates` — Task 10 expands it to per-surface + rollup):

Replace `pollAgentStates()` with this interim version (compiles against the new API; rolls up by the active surface only for now):

```swift
    private func pollAgentStates() {
        var states: [String: AgentState] = [:]
        for wtID in surfaces.worktreeIDs {
            let active = surfaces.existingSurfaces(for: wtID)?.activeHandle
            states[wtID] = active.map { agentState(fromOutput: $0.outputSnapshot()) } ?? .idle
        }
        agentStates = states
        sidebar.updateAgentStates(states)
        updateNotch()
        refreshChromeForActiveSurface()
    }
```

In `setWorktreeColor`, replace the `if let s = store.state.worktrees.first(where: { $0.id == worktreeID }), s.id == selectedWorktree?.id { selectedWorktree = s; worktreeBar.update(...) }` block with:

```swift
            if worktreeID == selectedWorktree?.id {
                selectedWorktree = store.state.worktrees.first { $0.id == worktreeID }
                refreshChromeForActiveSurface()
            }
```

- [ ] **Step 6: Add the "Surface" menu + actions + keybind wiring**

In `buildMenu()`, after the Worktree menu block (`wtItem.submenu = wtMenu`) and before the Window menu, insert:

```swift
        // Surface menu — per-worktree terminal tabs
        let surfaceItem = NSMenuItem()
        mainMenu.addItem(surfaceItem)
        let surfaceMenu = NSMenu(title: "Surface")
        addItem(to: surfaceMenu, "New Tab", #selector(newSurfaceAction), command: .newSurface)
        addItem(to: surfaceMenu, "Close Tab", #selector(closeSurfaceAction), command: .closeSurface)
        addItem(to: surfaceMenu, "Split Surface", #selector(splitSurfaceAction), command: .splitSurface)
        surfaceMenu.addItem(.separator())
        addItem(to: surfaceMenu, "Next Tab", #selector(nextSurfaceAction), command: .nextSurface)
        addItem(to: surfaceMenu, "Previous Tab", #selector(prevSurfaceAction), command: .prevSurface)
        surfaceMenu.addItem(.separator())
        let gotoCommands: [(ShortcutCommand, Int)] = [
            (.goToSurface1, 1), (.goToSurface2, 2), (.goToSurface3, 3), (.goToSurface4, 4),
            (.goToSurface5, 5), (.goToSurface6, 6), (.goToSurface7, 7), (.goToSurface8, 8),
            (.goToSurface9, 9)]
        for (cmd, n) in gotoCommands {
            let item = NSMenuItem(title: "Go to Tab \(n)", action: #selector(goToSurfaceAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = n
            apply(cmd, to: item)
            surfaceMenu.addItem(item)
        }
        surfaceItem.submenu = surfaceMenu
```

Add the `@objc` actions (near the other `@objc` actions):

```swift
    @objc private func newSurfaceAction() { newSurface() }
    @objc private func closeSurfaceAction() { closeSurface() }
    @objc private func nextSurfaceAction() { nextSurface() }
    @objc private func prevSurfaceAction() { prevSurface() }
    @objc private func goToSurfaceAction(_ sender: NSMenuItem) { goToSurface(sender.tag) }
    /// Reserved for PR B (splits). No-op in PR A.
    @objc private func splitSurfaceAction() { /* PR B */ }
```

- [ ] **Step 7: Give `TerminalSurface` a live title via the SwiftTerm process delegate**

SwiftTerm reports the title through `LocalProcessTerminalViewDelegate.setTerminalTitle(source:title:)` (verified at `.build/checkouts/SwiftTerm/Sources/SwiftTerm/Mac/MacLocalTerminalView.swift:29`). It is a **delegate method**, not an overridable view method — so `TerminalSurface` must become the terminal's `processDelegate`. The spike does exactly this (`spike/swiftterm-spike/Sources/Spike/AppDelegate.swift:255`).

In `Sources/Conductor/TerminalSurface.swift`, add the stored title + callback near `onOpenFile`:

```swift
    /// The live terminal title (OSC 0/2, set by the shell/claude), used for the tab label.
    private(set) var terminalTitle: String = ""
    /// Fired when the terminal title changes, so the tab bar can relabel.
    var onTitleChange: ((String) -> Void)?
```

In `TerminalSurface.loadView()`, after `terminal.onOpenFile = …` and before `view = terminal`, set the process delegate:

```swift
        terminal.processDelegate = self
```

Add the delegate conformance at the bottom of the file (the empty methods are required by the protocol; `hostCurrentDirectoryUpdate` also improves ⌘+click path resolution for free):

```swift
extension TerminalSurface: LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        terminalTitle = title
        onTitleChange?(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        terminal.currentDirectory = directory
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {}
}
```

> **Note:** `terminal.currentDirectory` is the existing `ClickableTerminalView.currentDirectory` property. Setting `processDelegate` is safe — it is currently nil, so nothing else depends on it. No `ClickableTerminalView` changes are needed for titles.

- [ ] **Step 8: Build, then run and verify in-app**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: clean build (no errors).

Run the app: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run`
Verify manually:
- Select a worktree → one tab appears in the tab bar; terminal works.
- ⌘T (and the `+` button) → a new tab appears, becomes active, focused; previous tab's shell still alive when you switch back.
- Click a tab → switches surfaces; the right one is visible.
- ⌘⇧] / ⌘⇧[ → cycle tabs with wraparound. **If these don't fire**, note it for review (the recorder can't bind shifted-symbols, but defaults should still fire as menu keyEquivalents per Safari/Terminal precedent) — capture the exact behavior.
- ⌘1 / ⌘2 / … → jump to that tab.
- ⌘W → closes the active tab; closing the last tab empties the pane; clicking the worktree again spawns a fresh shell.
- ⌘R (Launch Claude) → runs in the active tab.
- Switch worktrees → each worktree remembers its own tabs.
- Archive a worktree → its tabs/PTYs are torn down (no leak).

- [ ] **Step 9: Commit**

```bash
git add Sources/Conductor/AppDelegate.swift Sources/Conductor/TerminalSurface.swift
git commit -m "feat(app): per-worktree surface tabs (create/close/switch) + Surface menu + keybinds"
```

---

## Task 9: Shell — per-tab rename + color override + live chrome re-tint

**Files:**
- Modify: `Sources/Conductor/AppDelegate.swift`

Adds the right-click tab context menu (Rename…, Set Color ▸ via `ColorMenu`, Remove Color, Close Tab) and confirms the active tab's effective color drives the identity bar/sidebar accent live (the `refreshChromeForActiveSurface()` from Task 8 already paints the bar; this task adds the sidebar-accent pathway + the rename/color mutations).

**Interfaces:**
- Consumes: `ColorMenu.makeSetColorItem(...)`, `WorktreeSurfaces.rename/setColor`, `RGB(hex:)`.

- [ ] **Step 1: Add the tab context menu**

Add to `AppDelegate`:

```swift
    /// Right-click on a surface tab: rename, color, or close it.
    private func showSurfaceContextMenu(_ surfaceID: String, anchor: NSView) {
        let menu = NSMenu()
        let rename = NSMenuItem(title: "Rename…", action: #selector(renameSurfaceAction(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = surfaceID
        menu.addItem(rename)
        menu.addItem(ColorMenu.makeSetColorItem(
            targetID: surfaceID, target: self,
            setColor: #selector(setSurfaceColorAction(_:)),
            removeColor: #selector(removeSurfaceColorAction(_:))))
        menu.addItem(.separator())
        let close = NSMenuItem(title: "Close Tab", action: #selector(closeSurfaceMenuAction(_:)), keyEquivalent: "")
        close.target = self
        close.representedObject = surfaceID
        menu.addItem(close)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height), in: anchor)
    }

    @objc private func renameSurfaceAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let wtID = shownWorktreeID,
              let list = surfaces.existingSurfaces(for: wtID) else { return }
        let current = list.entry(for: id)?.surface.nameOverride ?? ""
        guard let input = promptForText(prompt: "Tab name:", defaultValue: current) else { return }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        list.rename(id: id, to: trimmed.isEmpty ? nil : trimmed)   // blank clears → auto-label
        refreshTabBar()
    }

    @objc private func setSurfaceColorAction(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let id = info["id"], let hex = info["hex"], let rgb = RGB(hex: hex),
              let wtID = shownWorktreeID, let list = surfaces.existingSurfaces(for: wtID) else { return }
        list.setColor(id: id, to: rgb)
        refreshTabBar()
        refreshChromeForActiveSurface()
        refreshSidebar(select: selectedWorktree?.id)
    }

    @objc private func removeSurfaceColorAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let wtID = shownWorktreeID,
              let list = surfaces.existingSurfaces(for: wtID) else { return }
        list.setColor(id: id, to: nil)
        refreshTabBar()
        refreshChromeForActiveSurface()
        refreshSidebar(select: selectedWorktree?.id)
    }

    @objc private func closeSurfaceMenuAction(_ sender: NSMenuItem) {
        (sender.representedObject as? String).map { closeSurface($0) }
    }
```

- [ ] **Step 2: Route the active surface's effective color to the sidebar accent**

The sidebar tints each worktree row's branch glyph by `worktree.color`. To reflect a per-tab override on the *selected* worktree's row, pass an effective color into the sidebar for the active worktree. Add a method on `SidebarController`:

```swift
    /// An optional per-worktree identity-color override (active surface's effective color),
    /// keyed by worktree id; falls back to the worktree's own color when absent.
    private var identityOverrides: [String: NSColor] = [:]
    func setIdentityOverride(_ color: NSColor?, forWorktree id: String) {
        let changed = identityOverrides[id] != color
        if let color { identityOverrides[id] = color } else { identityOverrides[id] = nil }
        if changed { outline.reloadData() }
    }
```

And in `SidebarController.outlineView(_:viewFor:…)` worktree branch, change the `applyIdentityColor` call to prefer the override:

```swift
            let identity = identityOverrides[wt.worktree.id]
                ?? wt.worktree.color.flatMap { NSColor(hex: $0) }
            cell.applyIdentityColor(identity, glyphTint: chrome?.color(.glyphTint).nsColor)
```

Then in `AppDelegate.refreshChromeForActiveSurface()`, after computing `effective`, push it to the sidebar:

```swift
        sidebar.setIdentityOverride(effective?.nsColor, forWorktree: wt.id)
```

- [ ] **Step 3: Build, run, verify**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run`
Verify:
- Right-click a tab → Rename… sets a custom label; blank reverts to the auto-label.
- Right-click a tab → Set Color (palette swatch) → that tab's label tints, and when it's the active tab the identity bar + sidebar glyph re-tint to the override; switching to a tab without an override reverts the bar to the worktree color.
- Remove Color clears it.
- Close Tab from the context menu works (with busy-confirm if a process is running).

- [ ] **Step 4: Commit**

```bash
git add Sources/Conductor/AppDelegate.swift Sources/Conductor/SidebarController.swift
git commit -m "feat(app): per-tab rename + color override with live chrome/sidebar re-tint"
```

---

## Task 10: Shell — per-tab agent badges + sidebar/notch rollup

**Files:**
- Modify: `Sources/Conductor/AppDelegate.swift`

Rewrites `pollAgentStates()` to snapshot **every** surface of every worktree, store per-surface states, drive per-tab badges (via `refreshTabBar`), and roll up to a per-worktree state for the sidebar + notch + identity bar.

**Interfaces:**
- Consumes: `rollup(_:)`, `WorktreeSurfaces.entries`, `TerminalSurface.outputSnapshot()`, `surfaceKey(_:_:)`.

- [ ] **Step 1: Change the agent-state storage to per-surface + per-worktree rollup**

Keep the existing `agentStates: [String: AgentState]` but now key it by **both** `surfaceKey(wt, surface)` (per tab) **and** plain `wt.id` (the rollup), so existing readers (`worktreeBar`, sidebar) that look up by `wt.id` keep working. Replace `pollAgentStates()`:

```swift
    private func pollAgentStates() {
        var states: [String: AgentState] = [:]
        var rollups: [String: AgentState] = [:]
        for wtID in surfaces.worktreeIDs {
            guard let list = surfaces.existingSurfaces(for: wtID) else { continue }
            var perSurface: [AgentState] = []
            for entry in list.entries {
                let snapshot = entry.handle.outputSnapshot()
                let state = agentState(fromOutput: snapshot)
                states[surfaceKey(wtID, entry.surface.id)] = state
                perSurface.append(state)
            }
            rollups[wtID] = rollup(perSurface)
        }
        // Merge: per-surface keys + per-worktree rollup keys in one map.
        for (k, v) in rollups { states[k] = v }
        agentStates = states
        sidebar.updateAgentStates(rollups)
        updateNotch()
        refreshChromeForActiveSurface()
        refreshTabBar()
    }
```

> `sidebar.updateAgentStates` receives only the rollups (keyed by worktree id) — its signature is unchanged. `refreshTabBar` reads `agentStates[surfaceKey(...)]` for per-tab dots (already wired in Task 8 Step 3). `refreshChromeForActiveSurface` reads `agentStates[wt.id]` for the identity bar dot (the rollup).

- [ ] **Step 2: Verify off-screen snapshots work**

`outputSnapshot()` reads the terminal buffer via `getLine` (Task context: `TerminalSurface.swift:76`). Background tabs are hidden-not-destroyed, so their `getTerminal()` buffer keeps updating. Confirm in-app (Step 3) that a background tab running `claude` shows a yellow dot while you sit on another tab. **If a hidden surface returns an empty/stale snapshot**, note it: the surface view may need to stay in the hierarchy (it does — we only `isHidden = true`), and `getLine` should still work; if not, the fallback is to poll only the active surface per worktree for the badge and document the limitation.

- [ ] **Step 3: Build, run, verify**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run`
Verify:
- A tab running `claude` shows 🟡 while working, 🔴 when it asks a question, 🟢 when done — **even when it's a background tab**.
- The sidebar row + notch show the rollup (🔴 if any tab needs you, else 🟡 if any working, else 🟢, else none).
- Switching tabs updates the identity-bar dot to the rollup.

- [ ] **Step 4: Run the full suite + final build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: all Core tests green (existing + new). 
Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/Conductor/AppDelegate.swift
git commit -m "feat(app): per-tab agent badges + sidebar/notch rollup across surfaces"
```

---

## Final Verification

- [ ] Full Core test suite green: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
- [ ] Clean build: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
- [ ] In-app smoke of every behavior in Tasks 8–10's verify steps.
- [ ] Confirm the flagged risks were resolved or documented:
  - ⌘⇧] / ⌘⇧[ fire as menu keyEquivalents (or a working default was substituted + spec/plan note added).
  - Off-screen surface snapshots produce live badges (or active-only fallback documented).
  - (Resolved during planning: SwiftTerm title arrives via `processDelegate.setTerminalTitle`, wired in Task 8 Step 7.)
- [ ] Request whole-branch review (`superpowers:requesting-code-review`), then open the PR.

## Notes / known limitations carried forward

- **Recorder can't bind shifted-symbol chords** (e.g. a user trying to rebind onto ⌘⇧]): pre-existing `KeyChordAppKit` limitation (`KeyChordAppKit.swift:32`), not in scope for PR A. The *defaults* ⌘⇧[/] still fire.
- **No restore:** tab names/colors/count are lost on quit by design.
- **Splits (⌘D) are a no-op**; scratch tabs unbuilt — PR B / PR C.
