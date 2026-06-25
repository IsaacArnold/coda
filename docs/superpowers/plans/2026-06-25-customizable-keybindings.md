# Customizable Keybindings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users rebind and enable/disable Conductor's menu-bar commands in a Keyboard Shortcuts settings pane, with conflict warnings, persisted across launches.

**Architecture:** All decision logic (chords, defaults, resolution, conflicts, persistence) lives in `ConductorCore` as pure, TDD'd types. The AppKit shell reads effective chords to build the menu, hosts a tabbed Settings window, and provides a key recorder. Mirrors existing `Preferences`/`PreferencesStore` and `terminalKeyAction` patterns.

**Tech Stack:** Swift, SwiftPM, AppKit, XCTest. Spec: `docs/superpowers/specs/2026-06-25-customizable-keybindings-design.md`.

## Global Constraints

- Prefix EVERY `swift build`/`run`/`test` with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Tests are XCTest, not Swift Testing.
- All pure logic goes in `ConductorCore`; only AppKit wiring in `Conductor`. No unit tests for the shell (verified in the running app).
- Follow existing file conventions (small focused files; `public` on Core API; custom Codable where it keeps JSON clean).
- The 8 bindable commands and their default chords are fixed: newWorktree ⌘N, launchClaude ⌘R, openInEditor ⌘O, revealInFinder ⌥⌘R, archiveWorktree ⌘⌫, addRepository ⇧⌘N, toggleSidebar ⌃⌘S, openSettings ⌘,.
- ⌘⌫ is NOT a reserved chord (intentional Archive/terminal coexistence). Reserved = ⌘K (Clear) + ⌘C/⌘V/⌘X/⌘A/⌘Q/⌘H/⌘W.

## File Structure

- Create `Sources/ConductorCore/Keybindings.swift` — `KeyModifiers`, `KeyChord`, `ShortcutCategory`, `ShortcutCommand`, `ShortcutOverride`, `Keybindings`, `normalizedKeyEquivalent`.
- Create `Sources/ConductorCore/KeybindingConflicts.swift` — `ReservedChord`, `ConflictReason`, `ShortcutConflict`, `Keybindings.reservedChords`, `keybindingConflicts`.
- Create `Sources/ConductorCore/KeybindingsStore.swift` — `KeybindingsStore`.
- Create `Sources/Conductor/KeyChordAppKit.swift` — `KeyModifiers.eventModifierFlags`, `KeyChord(event:)`.
- Create `Sources/Conductor/SettingsTabController.swift` — `SettingsTabController` (NSTabViewController).
- Create `Sources/Conductor/KeybindingsViewController.swift` — the pane + row views.
- Create `Sources/Conductor/HotkeyRecorderView.swift` — `HotkeyRecorderView`.
- Rename `Sources/Conductor/SettingsController.swift` → `Sources/Conductor/GeneralSettingsViewController.swift` (class `SettingsController` → `GeneralSettingsViewController`).
- Modify `Sources/Conductor/AppDelegate.swift` — load keybindings, apply to menu, tabbed Settings, rebuild on change.
- Tests: `Tests/ConductorCoreTests/KeybindingsTests.swift`, `KeybindingConflictsTests.swift`, `KeybindingsStoreTests.swift`.

---

### Task 1: KeyChord + KeyModifiers

**Files:**
- Create: `Sources/ConductorCore/Keybindings.swift`
- Test: `Tests/ConductorCoreTests/KeybindingsTests.swift`

**Interfaces:**
- Produces: `KeyModifiers: OptionSet` (`.command/.shift/.option/.control`); `KeyChord { key: String; modifiers: KeyModifiers; var display: String }` with inits `KeyChord(key:modifiers:)` and `KeyChord(_ key:command:shift:option:control:)`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ConductorCoreTests/KeybindingsTests.swift
import XCTest
@testable import ConductorCore

final class KeyChordTests: XCTestCase {
    func testDisplayUsesCanonicalModifierOrderAndUppercaseKey() {
        XCTAssertEqual(KeyChord("n", command: true).display, "⌘N")
        XCTAssertEqual(KeyChord("r", command: true, option: true).display, "⌥⌘R")
        XCTAssertEqual(KeyChord("s", command: true, control: true).display, "⌃⌘S")
    }

    func testDisplayMapsSpecialKeys() {
        XCTAssertEqual(KeyChord("\u{8}", command: true).display, "⌘⌫")
        XCTAssertEqual(KeyChord(",", command: true).display, "⌘,")
    }

    func testCodableRoundTripWithCompactModifiers() throws {
        let chord = KeyChord("r", command: true, option: true)
        let data = try JSONEncoder().encode(chord)
        XCTAssertEqual(try JSONDecoder().decode(KeyChord.self, from: data), chord)
        // modifiers encode as a bare int, not a {rawValue:…} object
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("rawValue"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter KeyChordTests`
Expected: FAIL — `cannot find 'KeyChord' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/ConductorCore/Keybindings.swift
import Foundation

public struct KeyModifiers: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let shift   = KeyModifiers(rawValue: 1 << 1)
    public static let option  = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)

    // Encode as a bare int so keybindings.json stays compact.
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(Int.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// A keyboard chord: the keyEquivalent character (lowercased) plus modifier flags.
/// Maps 1:1 onto NSMenuItem.keyEquivalent + keyEquivalentModifierMask.
public struct KeyChord: Codable, Equatable, Hashable, Sendable {
    public var key: String
    public var modifiers: KeyModifiers

    public init(key: String, modifiers: KeyModifiers) {
        self.key = key; self.modifiers = modifiers
    }

    public init(_ key: String, command: Bool = false, shift: Bool = false,
                option: Bool = false, control: Bool = false) {
        var m = KeyModifiers()
        if command { m.insert(.command) }
        if shift { m.insert(.shift) }
        if option { m.insert(.option) }
        if control { m.insert(.control) }
        self.init(key: key, modifiers: m)
    }

    /// Human-readable form, e.g. "⌥⌘R". Modifier order is the macOS canonical ⌃⌥⇧⌘.
    public var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option)  { s += "⌥" }
        if modifiers.contains(.shift)   { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + KeyChord.keySymbol(key)
    }

    static func keySymbol(_ key: String) -> String {
        switch key {
        case "\u{8}", "\u{7f}": return "⌫"
        case "\r": return "↩"
        case "\u{1b}": return "⎋"
        case " ": return "Space"
        case "\u{f700}": return "↑"
        case "\u{f701}": return "↓"
        case "\u{f702}": return "←"
        case "\u{f703}": return "→"
        case ",": return ","
        default: return key.uppercased()
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter KeyChordTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ConductorCore/Keybindings.swift Tests/ConductorCoreTests/KeybindingsTests.swift
git commit -m "feat(core): KeyChord + KeyModifiers with compact Codable and display"
```

---

### Task 2: ShortcutCommand + ShortcutCategory

**Files:**
- Modify: `Sources/ConductorCore/Keybindings.swift`
- Test: `Tests/ConductorCoreTests/KeybindingsTests.swift`

**Interfaces:**
- Consumes: `KeyChord` (Task 1).
- Produces: `ShortcutCategory: String, CaseIterable` (`.worktree/.repository/.view/.app`, `displayName`, `order`); `ShortcutCommand: String, Codable, CaseIterable` (8 cases) with `displayName`, `category`, `defaultChord`.

- [ ] **Step 1: Write the failing test**

```swift
// append to Tests/ConductorCoreTests/KeybindingsTests.swift
final class ShortcutCommandTests: XCTestCase {
    func testEveryCommandHasDisplayNameAndCategory() {
        for command in ShortcutCommand.allCases {
            XCTAssertFalse(command.displayName.isEmpty)
            XCTAssertFalse(command.category.displayName.isEmpty)
        }
    }

    func testDefaultChordsMatchTheMenu() {
        XCTAssertEqual(ShortcutCommand.newWorktree.defaultChord, KeyChord("n", command: true))
        XCTAssertEqual(ShortcutCommand.revealInFinder.defaultChord, KeyChord("r", command: true, option: true))
        XCTAssertEqual(ShortcutCommand.archiveWorktree.defaultChord, KeyChord("\u{8}", command: true))
        XCTAssertEqual(ShortcutCommand.toggleSidebar.defaultChord, KeyChord("s", command: true, control: true))
    }

    func testThereAreEightBindableCommands() {
        XCTAssertEqual(ShortcutCommand.allCases.count, 8)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ShortcutCommandTests`
Expected: FAIL — `cannot find 'ShortcutCommand' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// append to Sources/ConductorCore/Keybindings.swift
public enum ShortcutCategory: String, CaseIterable, Sendable {
    case worktree, repository, view, app
    public var displayName: String {
        switch self {
        case .worktree: return "Worktree"
        case .repository: return "Repository"
        case .view: return "View"
        case .app: return "App"
        }
    }
    public var order: Int {
        switch self {
        case .worktree: return 0
        case .repository: return 1
        case .view: return 2
        case .app: return 3
        }
    }
}

public enum ShortcutCommand: String, Codable, CaseIterable, Sendable {
    case newWorktree, launchClaude, openInEditor, revealInFinder, archiveWorktree
    case addRepository, toggleSidebar, openSettings

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
        }
    }

    public var category: ShortcutCategory {
        switch self {
        case .newWorktree, .launchClaude, .openInEditor, .revealInFinder, .archiveWorktree:
            return .worktree
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
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ShortcutCommandTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ConductorCore/Keybindings.swift Tests/ConductorCoreTests/KeybindingsTests.swift
git commit -m "feat(core): ShortcutCommand registry with categories and default chords"
```

---

### Task 3: ShortcutOverride + Keybindings resolution

**Files:**
- Modify: `Sources/ConductorCore/Keybindings.swift`
- Test: `Tests/ConductorCoreTests/KeybindingsTests.swift`

**Interfaces:**
- Consumes: `KeyChord`, `ShortcutCommand` (Tasks 1–2).
- Produces: `ShortcutOverride { chord: KeyChord; isEnabled: Bool }`; `Keybindings { overrides: [String: ShortcutOverride] }` with `effectiveChord(for:) -> KeyChord?`, `isEnabled(_:)`, `chord(for:)`, and mutating `setChord(_:for:)`, `setEnabled(_:for:)`, `reset(_:)`, `resetAll()`.

- [ ] **Step 1: Write the failing test**

```swift
// append to Tests/ConductorCoreTests/KeybindingsTests.swift
final class KeybindingsResolutionTests: XCTestCase {
    func testEffectiveChordFallsBackToDefault() {
        let bindings = Keybindings()
        XCTAssertEqual(bindings.effectiveChord(for: .newWorktree), KeyChord("n", command: true))
        XCTAssertTrue(bindings.isEnabled(.newWorktree))
    }

    func testOverrideReplacesChord() {
        var bindings = Keybindings()
        bindings.setChord(KeyChord("j", command: true), for: .newWorktree)
        XCTAssertEqual(bindings.effectiveChord(for: .newWorktree), KeyChord("j", command: true))
    }

    func testDisabledCommandHasNoEffectiveChordButKeepsItsChord() {
        var bindings = Keybindings()
        bindings.setEnabled(false, for: .archiveWorktree)
        XCTAssertNil(bindings.effectiveChord(for: .archiveWorktree))
        XCTAssertFalse(bindings.isEnabled(.archiveWorktree))
        XCTAssertEqual(bindings.chord(for: .archiveWorktree), KeyChord("\u{8}", command: true))
    }

    func testResetRemovesOverride() {
        var bindings = Keybindings()
        bindings.setChord(KeyChord("j", command: true), for: .newWorktree)
        bindings.reset(.newWorktree)
        XCTAssertEqual(bindings.effectiveChord(for: .newWorktree), KeyChord("n", command: true))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter KeybindingsResolutionTests`
Expected: FAIL — `cannot find 'Keybindings' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// append to Sources/ConductorCore/Keybindings.swift
public struct ShortcutOverride: Codable, Equatable, Sendable {
    public var chord: KeyChord
    public var isEnabled: Bool
    public init(chord: KeyChord, isEnabled: Bool = true) {
        self.chord = chord; self.isEnabled = isEnabled
    }
}

/// User overrides keyed by `ShortcutCommand.rawValue`. A command with no override uses its
/// default chord; an override may change the chord and/or disable it entirely.
public struct Keybindings: Codable, Equatable, Sendable {
    public var overrides: [String: ShortcutOverride]
    public init(overrides: [String: ShortcutOverride] = [:]) { self.overrides = overrides }

    public func effectiveChord(for command: ShortcutCommand) -> KeyChord? {
        if let o = overrides[command.rawValue] { return o.isEnabled ? o.chord : nil }
        return command.defaultChord
    }

    public func isEnabled(_ command: ShortcutCommand) -> Bool {
        overrides[command.rawValue]?.isEnabled ?? true
    }

    public func chord(for command: ShortcutCommand) -> KeyChord {
        overrides[command.rawValue]?.chord ?? command.defaultChord
    }

    public mutating func setChord(_ chord: KeyChord, for command: ShortcutCommand) {
        let enabled = overrides[command.rawValue]?.isEnabled ?? true
        overrides[command.rawValue] = ShortcutOverride(chord: chord, isEnabled: enabled)
    }

    public mutating func setEnabled(_ enabled: Bool, for command: ShortcutCommand) {
        let chord = overrides[command.rawValue]?.chord ?? command.defaultChord
        overrides[command.rawValue] = ShortcutOverride(chord: chord, isEnabled: enabled)
    }

    public mutating func reset(_ command: ShortcutCommand) { overrides[command.rawValue] = nil }
    public mutating func resetAll() { overrides = [:] }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter KeybindingsResolutionTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ConductorCore/Keybindings.swift Tests/ConductorCoreTests/KeybindingsTests.swift
git commit -m "feat(core): Keybindings overrides with effective-chord resolution"
```

---

### Task 4: normalizedKeyEquivalent

**Files:**
- Modify: `Sources/ConductorCore/Keybindings.swift`
- Test: `Tests/ConductorCoreTests/KeybindingsTests.swift`

**Interfaces:**
- Produces: `func normalizedKeyEquivalent(charactersIgnoringModifiers chars: String) -> String?`.

- [ ] **Step 1: Write the failing test**

```swift
// append to Tests/ConductorCoreTests/KeybindingsTests.swift
final class NormalizedKeyEquivalentTests: XCTestCase {
    func testMapsDeleteToBackspaceEquivalent() {
        XCTAssertEqual(normalizedKeyEquivalent(charactersIgnoringModifiers: "\u{7f}"), "\u{8}")
    }
    func testLowercasesOrdinaryKeys() {
        XCTAssertEqual(normalizedKeyEquivalent(charactersIgnoringModifiers: "A"), "a")
        XCTAssertEqual(normalizedKeyEquivalent(charactersIgnoringModifiers: ","), ",")
    }
    func testPassesThroughArrowsAndSpace() {
        XCTAssertEqual(normalizedKeyEquivalent(charactersIgnoringModifiers: " "), " ")
        XCTAssertEqual(normalizedKeyEquivalent(charactersIgnoringModifiers: "\u{f702}"), "\u{f702}")
    }
    func testRejectsEmptyAndControlChars() {
        XCTAssertNil(normalizedKeyEquivalent(charactersIgnoringModifiers: ""))
        XCTAssertNil(normalizedKeyEquivalent(charactersIgnoringModifiers: "\u{1}"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter NormalizedKeyEquivalentTests`
Expected: FAIL — `cannot find 'normalizedKeyEquivalent' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// append to Sources/ConductorCore/Keybindings.swift
/// Maps a recorded event's `charactersIgnoringModifiers` to the keyEquivalent form an
/// NSMenuItem expects, or nil for keys we don't allow binding (empty / control chars).
public func normalizedKeyEquivalent(charactersIgnoringModifiers chars: String) -> String? {
    guard let first = chars.first else { return nil }
    switch first {
    case "\u{7f}", "\u{8}": return "\u{8}"     // Delete → backspace (⌫)
    case "\r", "\u{3}": return "\r"            // Return / Enter
    case "\u{1b}": return "\u{1b}"             // Escape
    case " ": return " "
    case "\u{f700}", "\u{f701}", "\u{f702}", "\u{f703}": return String(first)  // arrows
    default:
        let lower = String(first).lowercased()
        guard lower.unicodeScalars.count == 1,
              let scalar = lower.unicodeScalars.first, scalar.value >= 0x20 else { return nil }
        return lower
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter NormalizedKeyEquivalentTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ConductorCore/Keybindings.swift Tests/ConductorCoreTests/KeybindingsTests.swift
git commit -m "feat(core): normalizedKeyEquivalent for recorder → keyEquivalent mapping"
```

---

### Task 5: Conflict detection

**Files:**
- Create: `Sources/ConductorCore/KeybindingConflicts.swift`
- Test: `Tests/ConductorCoreTests/KeybindingConflictsTests.swift`

**Interfaces:**
- Consumes: `Keybindings`, `ShortcutCommand`, `KeyChord` (Tasks 1–3).
- Produces: `ReservedChord { chord: KeyChord; label: String }`; `enum ConflictReason { case command(ShortcutCommand); case reserved(String) }`; `ShortcutConflict { command; reason }`; `Keybindings.reservedChords: [ReservedChord]`; `func keybindingConflicts(_:reserved:) -> [ShortcutCommand: ShortcutConflict]`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ConductorCoreTests/KeybindingConflictsTests.swift
import XCTest
@testable import ConductorCore

final class KeybindingConflictsTests: XCTestCase {
    func testDefaultsAreConflictFree() {
        XCTAssertTrue(keybindingConflicts(Keybindings()).isEmpty)
    }

    func testTwoCommandsOnSameChordConflictMutually() {
        var bindings = Keybindings()
        bindings.setChord(KeyChord("o", command: true), for: .newWorktree)  // == openInEditor default
        let conflicts = keybindingConflicts(bindings)
        XCTAssertEqual(conflicts[.newWorktree]?.reason, .command(.openInEditor))
        XCTAssertEqual(conflicts[.openInEditor]?.reason, .command(.newWorktree))
    }

    func testReservedTerminalChordIsFlagged() {
        var bindings = Keybindings()
        bindings.setChord(KeyChord("k", command: true), for: .launchClaude)
        XCTAssertEqual(keybindingConflicts(bindings)[.launchClaude]?.reason, .reserved("Clear"))
    }

    func testDisabledCommandNeverConflicts() {
        var bindings = Keybindings()
        bindings.setChord(KeyChord("o", command: true), for: .newWorktree)
        bindings.setEnabled(false, for: .newWorktree)
        let conflicts = keybindingConflicts(bindings)
        XCTAssertNil(conflicts[.newWorktree])
        XCTAssertNil(conflicts[.openInEditor])  // its only rival is now disabled
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter KeybindingConflictsTests`
Expected: FAIL — `cannot find 'keybindingConflicts' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/ConductorCore/KeybindingConflicts.swift
import Foundation

public struct ReservedChord: Equatable, Sendable {
    public let chord: KeyChord
    public let label: String
    public init(chord: KeyChord, label: String) { self.chord = chord; self.label = label }
}

public enum ConflictReason: Equatable, Sendable {
    case command(ShortcutCommand)
    case reserved(String)
}

public struct ShortcutConflict: Equatable, Sendable {
    public let command: ShortcutCommand
    public let reason: ConflictReason
    public init(command: ShortcutCommand, reason: ConflictReason) {
        self.command = command; self.reason = reason
    }
}

public extension Keybindings {
    /// Chords a focused terminal or the standard menus shadow. ⌘⌫ is intentionally absent:
    /// it's Archive's default and coexists with the terminal's delete-to-line-start via
    /// focus-gating, so it must not raise a (permanent) warning.
    static let reservedChords: [ReservedChord] = [
        ReservedChord(chord: KeyChord("k", command: true), label: "Clear"),
        ReservedChord(chord: KeyChord("c", command: true), label: "Copy"),
        ReservedChord(chord: KeyChord("v", command: true), label: "Paste"),
        ReservedChord(chord: KeyChord("x", command: true), label: "Cut"),
        ReservedChord(chord: KeyChord("a", command: true), label: "Select All"),
        ReservedChord(chord: KeyChord("q", command: true), label: "Quit"),
        ReservedChord(chord: KeyChord("h", command: true), label: "Hide"),
        ReservedChord(chord: KeyChord("w", command: true), label: "Close"),
    ]
}

/// Conflicts among enabled commands and against reserved chords. A command conflicts when
/// its effective chord equals a reserved chord, or another enabled command's chord.
/// Disabled commands (nil effective chord) never participate.
public func keybindingConflicts(_ bindings: Keybindings,
                                reserved: [ReservedChord] = Keybindings.reservedChords)
    -> [ShortcutCommand: ShortcutConflict] {
    let enabled: [(ShortcutCommand, KeyChord)] = ShortcutCommand.allCases.compactMap { cmd in
        bindings.effectiveChord(for: cmd).map { (cmd, $0) }
    }
    var result: [ShortcutCommand: ShortcutConflict] = [:]
    for (cmd, chord) in enabled {
        if let r = reserved.first(where: { $0.chord == chord }) {
            result[cmd] = ShortcutConflict(command: cmd, reason: .reserved(r.label))
        } else if let other = enabled.first(where: { $0.0 != cmd && $0.1 == chord }) {
            result[cmd] = ShortcutConflict(command: cmd, reason: .command(other.0))
        }
    }
    return result
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter KeybindingConflictsTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ConductorCore/KeybindingConflicts.swift Tests/ConductorCoreTests/KeybindingConflictsTests.swift
git commit -m "feat(core): keybinding conflict detection (command + reserved chords)"
```

---

### Task 6: KeybindingsStore

**Files:**
- Create: `Sources/ConductorCore/KeybindingsStore.swift`
- Test: `Tests/ConductorCoreTests/KeybindingsStoreTests.swift`

**Interfaces:**
- Consumes: `Keybindings`, `ShortcutOverride`, `KeyChord` (Tasks 1–3).
- Produces: `final class KeybindingsStore { init(url:); func load() -> Keybindings; func save(_:) throws }`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ConductorCoreTests/KeybindingsStoreTests.swift
import XCTest
import Foundation
@testable import ConductorCore

final class KeybindingsStoreTests: XCTestCase {
    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory() + "kb-" + UUID().uuidString + ".json")
    }

    func testMissingFileLoadsEmptyOverrides() {
        XCTAssertEqual(KeybindingsStore(url: tempURL()).load(), Keybindings())
    }

    func testSaveThenLoadRoundTrips() throws {
        let url = tempURL()
        var bindings = Keybindings()
        bindings.setChord(KeyChord("j", command: true), for: .newWorktree)
        bindings.setEnabled(false, for: .archiveWorktree)
        try KeybindingsStore(url: url).save(bindings)
        // A fresh store on the same URL must read it from disk.
        XCTAssertEqual(KeybindingsStore(url: url).load(), bindings)
    }

    func testJSONIsKeyedByCommandRawValue() throws {
        let url = tempURL()
        var bindings = Keybindings()
        bindings.setChord(KeyChord("j", command: true), for: .toggleSidebar)
        try KeybindingsStore(url: url).save(bindings)
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(json.contains("\"toggleSidebar\""), "overrides must be a keyed object: \(json)")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter KeybindingsStoreTests`
Expected: FAIL — `cannot find 'KeybindingsStore' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/ConductorCore/KeybindingsStore.swift
import Foundation

/// Loads/saves user keybinding overrides at a JSON file. Mirrors PreferencesStore: a
/// missing or unreadable file yields empty overrides (everything at its default).
public final class KeybindingsStore {
    private let url: URL
    public init(url: URL) { self.url = url }

    public func load() -> Keybindings {
        guard let data = try? Data(contentsOf: url),
              let bindings = try? JSONDecoder().decode(Keybindings.self, from: data) else {
            return Keybindings()
        }
        return bindings
    }

    public func save(_ bindings: Keybindings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(bindings).write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: PASS — full suite green (80 prior + new Keybindings tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ConductorCore/KeybindingsStore.swift Tests/ConductorCoreTests/KeybindingsStoreTests.swift
git commit -m "feat(core): KeybindingsStore JSON persistence"
```

---

### Task 7: Menu reads effective chords (shell)

**Files:**
- Create: `Sources/Conductor/KeyChordAppKit.swift`
- Modify: `Sources/Conductor/AppDelegate.swift`

**Interfaces:**
- Consumes: `Keybindings`, `KeybindingsStore`, `ShortcutCommand`, `KeyModifiers` (Core).
- Produces: `KeyModifiers.eventModifierFlags: NSEvent.ModifierFlags`; `KeyChord(event: NSEvent)?`; `AppDelegate.applyKeybindings(_:)`, `rebuildMenu()`. The menu's 8 commands now derive key equivalents from `keybindings`.

- [ ] **Step 1: Create the AppKit bridge**

```swift
// Sources/Conductor/KeyChordAppKit.swift
import AppKit
import ConductorCore

extension KeyModifiers {
    /// The AppKit modifier mask for an NSMenuItem / recorder.
    var eventModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift)   { flags.insert(.shift) }
        if contains(.option)  { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }
}

extension KeyChord {
    /// Build a chord from a recorded key event. Requires at least one modifier and a
    /// bindable key; returns nil otherwise (caller keeps waiting).
    init?(event: NSEvent) {
        guard let key = normalizedKeyEquivalent(
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "") else { return nil }
        var m = KeyModifiers()
        let f = event.modifierFlags
        if f.contains(.command) { m.insert(.command) }
        if f.contains(.shift)   { m.insert(.shift) }
        if f.contains(.option)  { m.insert(.option) }
        if f.contains(.control) { m.insert(.control) }
        guard !m.isEmpty else { return nil }
        self.init(key: key, modifiers: m)
    }
}
```

- [ ] **Step 2: Load keybindings at launch and add the apply helpers**

In `AppDelegate.swift`, add stored properties near `prefsStore`:

```swift
    private var kbStore: KeybindingsStore!
    private var keybindings = Keybindings()
```

In `applicationDidFinishLaunching`, immediately after the `preferences = prefsStore.load()` line and BEFORE `buildMenu()`:

```swift
        kbStore = KeybindingsStore(url: home.appendingPathComponent(".conductor/keybindings.json"))
        keybindings = kbStore.load()
```

Add these methods to `AppDelegate` (near `buildMenu`):

```swift
    /// Set an NSMenuItem's key equivalent from the command's effective chord (none if disabled).
    private func apply(_ command: ShortcutCommand, to item: NSMenuItem) {
        if let chord = keybindings.effectiveChord(for: command) {
            item.keyEquivalent = chord.key
            item.keyEquivalentModifierMask = chord.modifiers.eventModifierFlags
        } else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }

    /// Persist new bindings and rebuild the menu so shortcuts update live.
    func applyKeybindings(_ bindings: Keybindings) {
        keybindings = bindings
        do { try kbStore.save(bindings) } catch { presentError(error) }
        rebuildMenu()
    }

    private func rebuildMenu() { buildMenu() }
```

- [ ] **Step 3: Make buildMenu use the chords for the 8 commands**

Add a command-based item helper next to the existing `addItem`:

```swift
    @discardableResult
    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector,
                         command: ShortcutCommand) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        apply(command, to: item)
        menu.addItem(item)
        return item
    }
```

Replace the 8 command items in `buildMenu()`:

- Settings — replace the `settingsItem` block with:
```swift
        let settingsItem = addItem(to: appMenu, "Settings…", #selector(openSettingsAction),
                                   command: .openSettings)
        _ = settingsItem
```
(Remove the old `NSMenuItem(title: "Settings…", … keyEquivalent: ",")` + its `target`/`addItem` lines. Note Settings sits between the two separators — keep that order: add the leading separator, then this item, then the trailing separator.)

- Add Repository (File menu) — replace `addItem(to: fileMenu, "Add Repository…", #selector(addRepoAction), "n", modifiers: [.command, .shift])` with:
```swift
        addItem(to: fileMenu, "Add Repository…", #selector(addRepoAction), command: .addRepository)
```

- Toggle Sidebar (View menu) — replace the `viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")` + its `.keyEquivalentModifierMask` line with:
```swift
        addItem(to: viewMenu, "Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)),
                command: .toggleSidebar)
```
(The toggleSidebar action targets the responder chain, not self; setting `item.target = self` is harmless because NSSplitViewController.toggleSidebar is dispatched via the responder chain when the menu item's target doesn't implement it — but to be safe, after this call set its target to nil: `viewMenu.items.last?.target = nil`.)

- Worktree menu — replace the four `addItem(to: wtMenu, …, "n"/"r"/"o"/…)` calls with:
```swift
        addItem(to: wtMenu, "New Worktree", #selector(newWorktreeAction), command: .newWorktree)
        addItem(to: wtMenu, "Launch Claude", #selector(launchClaudeAction), command: .launchClaude)
        addItem(to: wtMenu, "Open in Editor", #selector(openInAction), command: .openInEditor)
        addItem(to: wtMenu, "Reveal in Finder", #selector(revealInFinderAction), command: .revealInFinder)
        wtMenu.addItem(.separator())
        addItem(to: wtMenu, "Archive Worktree", #selector(archiveSelectedAction), command: .archiveWorktree)
```

Keep the old `addItem(to:_:_:_:modifiers:)` helper (still used by nothing else now, but harmless) OR delete it if unused. If the compiler warns it's unused, leave it — it's private and may warn but not error.

- [ ] **Step 4: Build and verify menu shortcuts still work**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: `Build complete!`

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run`
Verify in-app: the menu shows the same shortcuts as before (⌘N, ⌘R, ⌘O, ⌥⌘R, ⌘⌫, ⇧⌘N, ⌃⌘S, ⌘,) and they all fire. Quit the app.

- [ ] **Step 5: Commit**

```bash
git add Sources/Conductor/KeyChordAppKit.swift Sources/Conductor/AppDelegate.swift
git commit -m "feat(app): build menu key equivalents from Keybindings (effective chords)"
```

---

### Task 8: Tabbed Settings window (shell)

**Files:**
- Rename: `Sources/Conductor/SettingsController.swift` → `Sources/Conductor/GeneralSettingsViewController.swift` (class `SettingsController` → `GeneralSettingsViewController`)
- Create: `Sources/Conductor/SettingsTabController.swift`
- Modify: `Sources/Conductor/AppDelegate.swift` (`openSettings`)

**Interfaces:**
- Consumes: `Editor`, `Keybindings` (Core); `AppDelegate.applyKeybindings(_:)` (Task 7).
- Produces: `GeneralSettingsViewController` (was `SettingsController`); `SettingsTabController(editor:onChangeEditor:keybindings:onChange:)`.

- [ ] **Step 1: Rename the existing pane**

```bash
git mv Sources/Conductor/SettingsController.swift Sources/Conductor/GeneralSettingsViewController.swift
```
Then in that file change `final class SettingsController: NSViewController {` to `final class GeneralSettingsViewController: NSViewController {`. No other change.

- [ ] **Step 2: Create the tab controller**

```swift
// Sources/Conductor/SettingsTabController.swift
import AppKit
import ConductorCore

/// The Settings window content: a toolbar-style tab view with General (editor picker) and
/// Keyboard Shortcuts panes.
final class SettingsTabController: NSTabViewController {
    init(editor: Editor,
         onChangeEditor: @escaping (Editor) -> Void,
         keybindings: Keybindings,
         onChange: @escaping (Keybindings) -> Void) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar

        let general = GeneralSettingsViewController(editor: editor)
        general.onChangeEditor = onChangeEditor
        let generalItem = NSTabViewItem(viewController: general)
        generalItem.label = "General"
        generalItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")
        addTabViewItem(generalItem)

        let keys = KeybindingsViewController(bindings: keybindings)
        keys.onChange = onChange
        let keysItem = NSTabViewItem(viewController: keys)
        keysItem.label = "Keyboard Shortcuts"
        keysItem.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keyboard Shortcuts")
        addTabViewItem(keysItem)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}
```

(NOTE: this references `KeybindingsViewController`, built in Task 9. This task will not compile until Task 9 is done — implement Task 9 before building. The two are split only for review; commit them together if executing inline.)

- [ ] **Step 3: Rewrite openSettings to use the tab controller**

In `AppDelegate.swift`, replace the body of `openSettings()` (the part that builds `SettingsController`) with:

```swift
    private func openSettings() {
        if settingsWC == nil {
            let tab = SettingsTabController(
                editor: preferences.defaultEditor,
                onChangeEditor: { [weak self] editor in self?.setDefaultEditor(editor) },
                keybindings: keybindings,
                onChange: { [weak self] bindings in self?.applyKeybindings(bindings) })
            let win = NSWindow(contentViewController: tab)
            win.title = "Settings"
            win.styleMask = [.titled, .closable]
            win.toolbarStyle = .preference
            win.isReleasedWhenClosed = false
            settingsWC = NSWindowController(window: win)
        }
        settingsWC?.window?.center()
        settingsWC?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
```

- [ ] **Step 4: Build (after Task 9) and verify**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: `Build complete!` (once Task 9 exists).
Verify in-app: ⌘, opens a Settings window with two toolbar tabs — General (editor picker, unchanged) and Keyboard Shortcuts.

- [ ] **Step 5: Commit**

```bash
git add Sources/Conductor/GeneralSettingsViewController.swift Sources/Conductor/SettingsTabController.swift Sources/Conductor/AppDelegate.swift
git commit -m "feat(app): tabbed Settings window (General + Keyboard Shortcuts)"
```

---

### Task 9: Keybindings pane + recorder (shell)

**Files:**
- Create: `Sources/Conductor/HotkeyRecorderView.swift`
- Create: `Sources/Conductor/KeybindingsViewController.swift`

**Interfaces:**
- Consumes: `Keybindings`, `ShortcutCommand`, `ShortcutCategory`, `KeyChord`, `keybindingConflicts`, `ConflictReason` (Core); `KeyChord(event:)` (Task 7).
- Produces: `HotkeyRecorderView` (NSView, `onRecorded`/`onCancel`); `KeybindingsViewController(bindings:)` with `var onChange: ((Keybindings) -> Void)?`.

- [ ] **Step 1: Build the recorder view**

```swift
// Sources/Conductor/HotkeyRecorderView.swift
import AppKit
import ConductorCore

/// Captures the next key chord the user presses. Overrides performKeyEquivalent so the
/// chord doesn't trigger a menu item; requires ≥1 modifier (handled by KeyChord(event:));
/// Esc cancels.
final class HotkeyRecorderView: NSView {
    var onRecorded: ((KeyChord) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }   // Esc
        if let chord = KeyChord(event: event) { onRecorded?(chord) }
        // otherwise (no modifier / unsupported key): keep waiting
    }
}
```

- [ ] **Step 2: Build the pane**

```swift
// Sources/Conductor/KeybindingsViewController.swift
import AppKit
import ConductorCore

/// The Keyboard Shortcuts settings pane: commands grouped by category, each with a chord
/// button (opens a recorder popover), an enable checkbox, and a conflict warning. Edits
/// mutate an in-memory Keybindings and report via onChange (the app persists + rebuilds).
final class KeybindingsViewController: NSViewController {
    private var bindings: Keybindings
    var onChange: ((Keybindings) -> Void)?

    private let stack = NSStackView()
    private var rows: [ShortcutCommand: RowViews] = [:]
    private var recorderPopover: NSPopover?

    private struct RowViews {
        let chordButton: NSButton
        let enableCheckbox: NSButton
        let warning: NSImageView
    }

    init(bindings: Keybindings) {
        self.bindings = bindings
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        for category in ShortcutCategory.allCases.sorted(by: { $0.order < $1.order }) {
            let commands = ShortcutCommand.allCases.filter { $0.category == category }
            guard !commands.isEmpty else { continue }
            let header = NSTextField(labelWithString: category.displayName)
            header.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            header.textColor = .secondaryLabelColor
            stack.addArrangedSubview(header)
            for command in commands { stack.addArrangedSubview(makeRow(command)) }
        }

        let reset = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
        reset.bezelStyle = .rounded
        stack.addArrangedSubview(reset)

        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 460),
        ])
        view = container
        refresh()
    }

    private func makeRow(_ command: ShortcutCommand) -> NSView {
        let name = NSTextField(labelWithString: command.displayName)
        name.widthAnchor.constraint(equalToConstant: 160).isActive = true

        let chordButton = NSButton(title: "", target: self, action: #selector(recordChord(_:)))
        chordButton.bezelStyle = .rounded
        chordButton.tag = ShortcutCommand.allCases.firstIndex(of: command)!
        chordButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true

        let warning = NSImageView()
        warning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Conflict")
        warning.contentTintColor = .systemYellow
        warning.isHidden = true

        let enable = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleEnabled(_:)))
        enable.tag = chordButton.tag

        let row = NSStackView(views: [name, chordButton, warning, enable])
        row.orientation = .horizontal
        row.spacing = 8
        rows[command] = RowViews(chordButton: chordButton, enableCheckbox: enable, warning: warning)

        // Per-row reset via context menu.
        let menu = NSMenu()
        let resetItem = NSMenuItem(title: "Reset to Default", action: #selector(resetOne(_:)), keyEquivalent: "")
        resetItem.target = self
        resetItem.tag = chordButton.tag
        menu.addItem(resetItem)
        row.menu = menu
        return row
    }

    private func command(for tag: Int) -> ShortcutCommand { ShortcutCommand.allCases[tag] }

    /// Refresh every row's chord title, enabled state, and conflict warning.
    private func refresh() {
        let conflicts = keybindingConflicts(bindings)
        for (command, views) in rows {
            let enabled = bindings.isEnabled(command)
            views.chordButton.title = bindings.chord(for: command).display
            views.chordButton.isEnabled = enabled
            // Bold when overridden from the default.
            views.chordButton.font = bindings.overrides[command.rawValue] != nil
                ? .boldSystemFont(ofSize: NSFont.systemFontSize)
                : .systemFont(ofSize: NSFont.systemFontSize)
            views.enableCheckbox.state = enabled ? .on : .off
            if let conflict = conflicts[command] {
                views.warning.isHidden = false
                views.warning.toolTip = Self.message(for: conflict)
            } else {
                views.warning.isHidden = true
            }
        }
    }

    private static func message(for conflict: ShortcutConflict) -> String {
        switch conflict.reason {
        case .command(let other): return "Conflicts with “\(other.displayName)”."
        case .reserved(let label): return "Conflicts with “\(label)” (system/terminal)."
        }
    }

    private func commit() { onChange?(bindings); refresh() }

    @objc private func toggleEnabled(_ sender: NSButton) {
        bindings.setEnabled(sender.state == .on, for: command(for: sender.tag))
        commit()
    }

    @objc private func resetOne(_ sender: NSMenuItem) {
        bindings.reset(command(for: sender.tag))
        commit()
    }

    @objc private func restoreDefaults() {
        bindings.resetAll()
        commit()
    }

    @objc private func recordChord(_ sender: NSButton) {
        let command = command(for: sender.tag)
        let recorder = HotkeyRecorderView(frame: NSRect(x: 0, y: 0, width: 220, height: 64))
        let label = NSTextField(labelWithString: "Press a shortcut…  (Esc to cancel)")
        label.frame = NSRect(x: 12, y: 22, width: 196, height: 20)
        recorder.addSubview(label)

        let popover = NSPopover()
        let vc = NSViewController()
        vc.view = recorder
        popover.contentViewController = vc
        popover.behavior = .transient
        recorderPopover = popover

        recorder.onCancel = { [weak self] in self?.recorderPopover?.close() }
        recorder.onRecorded = { [weak self] chord in
            guard let self else { return }
            self.bindings.setChord(chord, for: command)
            self.recorderPopover?.close()
            self.commit()   // conflicts shown via warning; binding committed regardless
        }

        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        recorder.window?.makeFirstResponder(recorder)
    }
}
```

- [ ] **Step 3: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: `Build complete!`

- [ ] **Step 4: Verify in the running app**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run`
Verify:
1. ⌘, → Keyboard Shortcuts tab lists 8 commands grouped (Worktree / Repository / View / App) with current chords.
2. Click a chord button → popover; press e.g. ⌥⌘N → the menu's New Worktree shortcut changes to ⌥⌘N and fires.
3. Set a command to ⌘O (matching Open in Editor) → both rows show the ⚠️ with a tooltip.
4. Set a command to ⌘K → ⚠️ "Conflicts with Clear (system/terminal)".
5. Uncheck a command → its menu shortcut disappears but the menu item still works on click.
6. Restore Defaults → chords revert; relaunch → overrides persisted (set one, quit, relaunch, confirm it stuck).

- [ ] **Step 5: Commit**

```bash
git add Sources/Conductor/HotkeyRecorderView.swift Sources/Conductor/KeybindingsViewController.swift
git commit -m "feat(app): Keyboard Shortcuts pane with key recorder, enable/disable, conflicts"
```

---

## Final verification

- [ ] Run full suite: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` → all green.
- [ ] `swift run` and exercise the full flow from Task 9 Step 4 once more, plus confirm the terminal still owns ⌘K/⌘⌫ (focused) and Archive still confirms.
- [ ] Open a PR; pause for in-app verification before merge (per project norm).
