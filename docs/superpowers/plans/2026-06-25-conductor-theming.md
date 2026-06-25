# Conductor Theming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply imported `.itermcolors` themes to the terminal grid, blend the app chrome into the terminal background (iTerm2-style), and give each worktree an identity color shown in a full-width bar + sidebar accent.

**Architecture:** All color math stays **pure in `ConductorCore`** as plain `RGB` (0–1 doubles) — `TerminalTheme` (`.itermcolors` parser), `ChromeTheme` (derives chrome roles from the terminal theme, behind a single override-aware seam), `IdentityPalette` (worktree colors), and `ThemeStore` (theme files on disk). The AppKit shell adds thin adapters (`RGB → NSColor` / `SwiftTerm.Color` / `NSAppearance`) and wires the live UI. One global active terminal theme app-wide; per-worktree differs only by the chrome identity color.

**Tech Stack:** Swift 6 package (`swiftLanguageModes: [.v5]`), AppKit, SwiftTerm 1.x, XCTest. Two targets: `ConductorCore` (pure, tested) and `Conductor` (executable AppKit shell).

## Global Constraints

- Every `swift build`/`run`/`test` MUST be prefixed `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (Command Line Tools ship no XCTest).
- Tests are **XCTest**, never Swift Testing.
- Package stays at `.macOS(.v13)`; no linker hacks; `swiftLanguageModes: [.v5]`.
- `ConductorCore` MUST NOT import AppKit or SwiftTerm — it stays pure and headless-testable. All `NSColor`/`SwiftTerm.Color`/`NSAppearance` conversion lives in the `Conductor` target.
- Portable config (`~/.conductor/themes/`, `preferences.json`) MUST NOT contain absolute machine paths. Machine-local state (`local.json`, holding `Worktree`) is the only place paths are allowed.
- Terminology (per `CONTEXT.md`): **Worktree**, **Surface**, **Repository** — never "Session"/"project"/"pane" in identifiers or user-facing copy.
- Identity color drives chrome ONLY (full-width bar + sidebar accent). It MUST NOT alter terminal grid colors. Agent-state badge colors stay separate from identity color.

---

## File Structure

**ConductorCore (pure, new):**
- `Sources/ConductorCore/RGB.swift` — `RGB` value type (0–1 doubles), hex parse/format, luminance, contrasting-text.
- `Sources/ConductorCore/TerminalTheme.swift` — `TerminalTheme` + `load(from:)` `.itermcolors` parser; `ThemeError`.
- `Sources/ConductorCore/ChromeTheme.swift` — `ThemeAppearance`, `ChromeRole`, `ChromeTheme` (derive + override-aware fallback).
- `Sources/ConductorCore/IdentityPalette.swift` — curated worktree color palette + cycling.
- `Sources/ConductorCore/ThemeStore.swift` — list/import/seed `.itermcolors` files in a directory.

**ConductorCore (modified):**
- `Sources/ConductorCore/Models.swift` — add `Worktree.color: String?` (hex) with backward-compat decode.
- `Sources/ConductorCore/WorktreeStore.swift` — auto-assign color on create; `setWorktreeColor`.
- `Sources/ConductorCore/Preferences.swift` — add `activeTheme: String?`.

**Conductor shell (new):**
- `Sources/Conductor/ThemeAppKit.swift` — `RGB → NSColor`, `RGB → SwiftTerm.Color`, `ThemeAppearance → NSAppearance`.
- `Sources/Conductor/WorktreeBar.swift` — full-width identity bar (color fill + title + branch + agent badge).
- `Sources/Conductor/ThemeSettingsViewController.swift` — Settings "Themes" tab (list + import + apply).
- `Sources/Conductor/Themes/*.itermcolors` — 3 bundled starter themes (package resources).

**Conductor shell (modified):**
- `Sources/Conductor/TerminalSurface.swift` — `applyTheme(_:)`.
- `Sources/Conductor/SettingsTabController.swift` — add Themes tab.
- `Sources/Conductor/SidebarController.swift` — identity-accent on worktree rows; chrome colors via `ChromeTheme`; "Set Color…" menu.
- `Sources/Conductor/AppDelegate.swift` — load/seed/apply theme; chrome repaint; mount `WorktreeBar`; demote notch; wire "Set Color…".
- `Package.swift` — declare `Themes` resources on the `Conductor` target.

---

## Task 1: `RGB` value type (Core)

**Files:**
- Create: `Sources/ConductorCore/RGB.swift`
- Test: `Tests/ConductorCoreTests/RGBTests.swift`

**Interfaces:**
- Produces: `struct RGB: Equatable, Codable { var r, g, b: Double }`, `init(r:g:b:)`, `init?(hex: String)`, `var hexString: String`, `var luminance: Double`, `var contrastingText: RGB` (black/white), `static let black`, `static let white`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ConductorCoreTests/RGBTests.swift
import XCTest
@testable import ConductorCore

final class RGBTests: XCTestCase {
    func testParsesSixDigitHexWithHash() {
        let c = RGB(hex: "#282A36")
        XCTAssertNotNil(c)
        XCTAssertEqual(c!.r, 40.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(c!.g, 42.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(c!.b, 54.0 / 255.0, accuracy: 0.0001)
    }

    func testParsesHexWithoutHash() {
        XCTAssertEqual(RGB(hex: "ffffff"), RGB(r: 1, g: 1, b: 1))
    }

    func testRejectsBadHex() {
        XCTAssertNil(RGB(hex: "xyz"))
        XCTAssertNil(RGB(hex: "#12"))
    }

    func testHexStringRoundTrips() {
        XCTAssertEqual(RGB(hex: "#1E90FF")!.hexString, "#1E90FF")
    }

    func testLuminanceDarkIsLowLightIsHigh() {
        XCTAssertLessThan(RGB(r: 0, g: 0, b: 0).luminance, 0.1)
        XCTAssertGreaterThan(RGB(r: 1, g: 1, b: 1).luminance, 0.9)
    }

    func testContrastingTextIsWhiteOnDarkBlackOnLight() {
        XCTAssertEqual(RGB(hex: "#222222")!.contrastingText, .white)
        XCTAssertEqual(RGB(hex: "#EEEEEE")!.contrastingText, .black)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RGBTests`
Expected: FAIL — `cannot find 'RGB' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/ConductorCore/RGB.swift
import Foundation

/// A color as sRGB components in 0...1. Pure value type — the AppKit shell
/// converts it to NSColor / SwiftTerm.Color. Core never imports AppKit.
public struct RGB: Equatable, Codable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    /// Parse `#RRGGBB` or `RRGGBB`. Returns nil for anything else.
    public init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        r = Double((v >> 16) & 0xFF) / 255.0
        g = Double((v >> 8) & 0xFF) / 255.0
        b = Double(v & 0xFF) / 255.0
    }

    /// Uppercase `#RRGGBB`.
    public var hexString: String {
        func byte(_ x: Double) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    /// Perceptual relative luminance (0 dark … 1 light).
    public var luminance: Double { 0.299 * r + 0.587 * g + 0.114 * b }

    /// Black or white, whichever reads better on top of this color.
    public var contrastingText: RGB { luminance < 0.5 ? .white : .black }

    public static let black = RGB(r: 0, g: 0, b: 0)
    public static let white = RGB(r: 1, g: 1, b: 1)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RGBTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ConductorCore/RGB.swift Tests/ConductorCoreTests/RGBTests.swift
git commit -m "feat(core): RGB value type with hex, luminance, contrasting-text"
```

---

## Task 2: `TerminalTheme` + `.itermcolors` parser (Core)

**Files:**
- Create: `Sources/ConductorCore/TerminalTheme.swift`
- Test: `Tests/ConductorCoreTests/TerminalThemeTests.swift`

**Interfaces:**
- Consumes: `RGB` (Task 1).
- Produces: `struct TerminalTheme: Equatable { let name: String; let ansi: [RGB] /*16*/; let foreground, background, cursor: RGB }`, `static func load(from url: URL) throws -> TerminalTheme`, `enum ThemeError: Error, CustomStringConvertible { case notAPlist(String); case missingKey(String) }`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ConductorCoreTests/TerminalThemeTests.swift
import XCTest
@testable import ConductorCore

final class TerminalThemeTests: XCTestCase {
    /// Write a minimal valid `.itermcolors` plist to a temp file and return its URL.
    private func writeITermColors(name: String) throws -> URL {
        func comp(_ r: Double, _ g: Double, _ b: Double) -> [String: Any] {
            ["Red Component": r, "Green Component": g, "Blue Component": b]
        }
        var dict: [String: Any] = [
            "Foreground Color": comp(1, 1, 1),
            "Background Color": comp(0, 0, 0),
            "Cursor Color": comp(0.5, 0.5, 0.5),
        ]
        for i in 0..<16 { dict["Ansi \(i) Color"] = comp(Double(i) / 15.0, 0, 0) }
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + name + "-" + UUID().uuidString + ".itermcolors")
        try data.write(to: url)
        return url
    }

    func testParsesSixteenAnsiPlusFgBgCursor() throws {
        let url = try writeITermColors(name: "Test")
        let theme = try TerminalTheme.load(from: url)
        XCTAssertEqual(theme.ansi.count, 16)
        XCTAssertEqual(theme.foreground, RGB(r: 1, g: 1, b: 1))
        XCTAssertEqual(theme.background, RGB(r: 0, g: 0, b: 0))
        XCTAssertEqual(theme.cursor, RGB(r: 0.5, g: 0.5, b: 0.5))
        XCTAssertEqual(theme.ansi[15].r, 1, accuracy: 0.0001)
    }

    func testNameComesFromFilename() throws {
        let url = try writeITermColors(name: "Dracula")
        let theme = try TerminalTheme.load(from: url)
        XCTAssertTrue(theme.name.hasPrefix("Dracula"))
    }

    func testThrowsOnNonPlist() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "junk-" + UUID().uuidString + ".itermcolors")
        try "not a plist".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try TerminalTheme.load(from: url))
    }

    func testThrowsOnMissingKey() throws {
        let dict: [String: Any] = ["Foreground Color": ["Red Component": 1.0]]  // missing the rest
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "partial-" + UUID().uuidString + ".itermcolors")
        try data.write(to: url)
        XCTAssertThrowsError(try TerminalTheme.load(from: url))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TerminalThemeTests`
Expected: FAIL — `cannot find 'TerminalTheme' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/ConductorCore/TerminalTheme.swift
import Foundation

public enum ThemeError: Error, CustomStringConvertible {
    case notAPlist(String)
    case missingKey(String)
    public var description: String {
        switch self {
        case .notAPlist(let f): return "Not a valid .itermcolors plist: \(f)"
        case .missingKey(let k): return "Missing color key: \(k)"
        }
    }
}

/// A terminal color scheme parsed from an iTerm2 `.itermcolors` file (an XML plist
/// mapping `Ansi 0 Color`…`Ansi 15 Color`, `Foreground/Background/Cursor Color` to
/// dicts of `Red/Green/Blue Component` floats in 0...1). Pure — no AppKit.
public struct TerminalTheme: Equatable {
    public let name: String
    public let ansi: [RGB]            // 16 entries, indices 0...15
    public let foreground: RGB
    public let background: RGB
    public let cursor: RGB

    public init(name: String, ansi: [RGB], foreground: RGB, background: RGB, cursor: RGB) {
        self.name = name; self.ansi = ansi
        self.foreground = foreground; self.background = background; self.cursor = cursor
    }

    public static func load(from url: URL) throws -> TerminalTheme {
        let data = try Data(contentsOf: url)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any] else {
            throw ThemeError.notAPlist(url.lastPathComponent)
        }

        func component(_ d: [String: Any], _ key: String) -> Double {
            (d[key] as? Double) ?? (d[key] as? NSNumber)?.doubleValue ?? 0
        }
        func color(_ key: String) throws -> RGB {
            guard let d = dict[key] as? [String: Any],
                  d["Red Component"] != nil, d["Green Component"] != nil, d["Blue Component"] != nil else {
                throw ThemeError.missingKey(key)
            }
            return RGB(r: component(d, "Red Component"),
                       g: component(d, "Green Component"),
                       b: component(d, "Blue Component"))
        }

        var ansi: [RGB] = []
        for i in 0..<16 { ansi.append(try color("Ansi \(i) Color")) }
        return TerminalTheme(
            name: url.deletingPathExtension().lastPathComponent,
            ansi: ansi,
            foreground: try color("Foreground Color"),
            background: try color("Background Color"),
            cursor: try color("Cursor Color"))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TerminalThemeTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ConductorCore/TerminalTheme.swift Tests/ConductorCoreTests/TerminalThemeTests.swift
git commit -m "feat(core): parse .itermcolors into pure TerminalTheme (RGB)"
```

---

## Task 3: `ChromeTheme` resolver (Core)

**Files:**
- Create: `Sources/ConductorCore/ChromeTheme.swift`
- Test: `Tests/ConductorCoreTests/ChromeThemeTests.swift`

**Interfaces:**
- Consumes: `RGB` (Task 1), `TerminalTheme` (Task 2).
- Produces: `enum ThemeAppearance { case light, dark }`, `enum ChromeRole: CaseIterable { case windowBackground, primaryText, secondaryText, accent, glyphTint }`, `struct ChromeTheme { init(terminal: TerminalTheme, overrides: [ChromeRole: RGB] = [:]); var appearance: ThemeAppearance; func color(_ role: ChromeRole) -> RGB }`.
- Note for later tasks: chrome is **derived** today (`overrides` empty); the override-aware `color(_:)` is the seam for the future granular-chrome milestone. Do not scatter `terminal.background`-based math into views — always read through `ChromeTheme.color(_:)`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ConductorCoreTests/ChromeThemeTests.swift
import XCTest
@testable import ConductorCore

final class ChromeThemeTests: XCTestCase {
    private func theme(bg: RGB, fg: RGB = .white, accent: RGB = RGB(hex: "#5599FF")!) -> TerminalTheme {
        var ansi = Array(repeating: RGB.black, count: 16)
        ansi[4] = accent   // ANSI 4 = blue, used as the derived accent
        return TerminalTheme(name: "t", ansi: ansi, foreground: fg, background: bg, cursor: fg)
    }

    func testDarkBackgroundYieldsDarkAppearance() {
        let chrome = ChromeTheme(terminal: theme(bg: RGB(hex: "#282A36")!))
        XCTAssertEqual(chrome.appearance, .dark)
    }

    func testLightBackgroundYieldsLightAppearance() {
        let chrome = ChromeTheme(terminal: theme(bg: RGB(hex: "#FDF6E3")!))
        XCTAssertEqual(chrome.appearance, .light)
    }

    func testWindowBackgroundIsTerminalBackground() {
        let bg = RGB(hex: "#1E1E2E")!
        XCTAssertEqual(ChromeTheme(terminal: theme(bg: bg)).color(.windowBackground), bg)
    }

    func testAccentIsAnsiFour() {
        let accent = RGB(hex: "#89B4FA")!
        XCTAssertEqual(ChromeTheme(terminal: theme(bg: .black, accent: accent)).color(.accent), accent)
    }

    func testPrimaryTextIsForeground() {
        let fg = RGB(hex: "#CDD6F4")!
        XCTAssertEqual(ChromeTheme(terminal: theme(bg: .black, fg: fg)).color(.primaryText), fg)
    }

    func testOverrideTakesPrecedenceOverDerived() {
        let override = RGB(hex: "#FF0000")!
        let chrome = ChromeTheme(terminal: theme(bg: .black), overrides: [.accent: override])
        XCTAssertEqual(chrome.color(.accent), override, "override must win over the derived value")
        // Non-overridden roles still derive.
        XCTAssertEqual(chrome.color(.windowBackground), RGB.black)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ChromeThemeTests`
Expected: FAIL — `cannot find 'ChromeTheme' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/ConductorCore/ChromeTheme.swift
import Foundation

public enum ThemeAppearance: Equatable { case light, dark }

/// Named chrome color slots. Views read these via `ChromeTheme.color(_:)` — never a
/// raw color literal — so the future granular-chrome milestone only fills in overrides.
public enum ChromeRole: CaseIterable {
    case windowBackground, primaryText, secondaryText, accent, glyphTint
}

/// Chrome colors derived from the active terminal theme (iTerm2-style: the window
/// blends into the terminal background). `overrides` is the seam for future
/// user-customizable chrome — empty today, so every role derives.
public struct ChromeTheme {
    private let terminal: TerminalTheme
    private let overrides: [ChromeRole: RGB]

    public init(terminal: TerminalTheme, overrides: [ChromeRole: RGB] = [:]) {
        self.terminal = terminal
        self.overrides = overrides
    }

    public var appearance: ThemeAppearance {
        terminal.background.luminance < 0.5 ? .dark : .light
    }

    public func color(_ role: ChromeRole) -> RGB {
        if let override = overrides[role] { return override }
        return derived(role)
    }

    private func derived(_ role: ChromeRole) -> RGB {
        switch role {
        case .windowBackground: return terminal.background
        case .primaryText:      return terminal.foreground
        case .secondaryText:    return blend(terminal.foreground, terminal.background, 0.45)
        case .accent:           return terminal.ansi.indices.contains(4) ? terminal.ansi[4] : terminal.foreground
        case .glyphTint:        return blend(terminal.foreground, terminal.background, 0.35)
        }
    }

    /// Linear interpolation: `t = 0` → a, `t = 1` → b.
    private func blend(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        RGB(r: a.r + (b.r - a.r) * t,
            g: a.g + (b.g - a.g) * t,
            b: a.b + (b.b - a.b) * t)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ChromeThemeTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ConductorCore/ChromeTheme.swift Tests/ConductorCoreTests/ChromeThemeTests.swift
git commit -m "feat(core): ChromeTheme derives chrome roles from terminal theme behind override seam"
```

---

## Task 4: `IdentityPalette` (Core)

**Files:**
- Create: `Sources/ConductorCore/IdentityPalette.swift`
- Test: `Tests/ConductorCoreTests/IdentityPaletteTests.swift`

**Interfaces:**
- Consumes: `RGB` (Task 1).
- Produces: `enum IdentityPalette { static let colors: [String] /*hex*/; static func color(at index: Int) -> String }`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ConductorCoreTests/IdentityPaletteTests.swift
import XCTest
@testable import ConductorCore

final class IdentityPaletteTests: XCTestCase {
    func testPaletteIsNonEmptyValidHex() {
        XCTAssertFalse(IdentityPalette.colors.isEmpty)
        for hex in IdentityPalette.colors {
            XCTAssertNotNil(RGB(hex: hex), "\(hex) is not valid hex")
        }
    }

    func testColorAtCyclesByIndex() {
        XCTAssertEqual(IdentityPalette.color(at: 0), IdentityPalette.colors[0])
        let n = IdentityPalette.colors.count
        XCTAssertEqual(IdentityPalette.color(at: n), IdentityPalette.colors[0], "wraps around")
        XCTAssertEqual(IdentityPalette.color(at: n + 1), IdentityPalette.colors[1])
    }

    func testConsecutiveColorsDiffer() {
        XCTAssertNotEqual(IdentityPalette.color(at: 0), IdentityPalette.color(at: 1))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter IdentityPaletteTests`
Expected: FAIL — `cannot find 'IdentityPalette' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/ConductorCore/IdentityPalette.swift
import Foundation

/// Curated worktree identity colors, auto-assigned by creation order (cycling so
/// neighbors differ). Hex strings — the shell converts to NSColor. The contrasting
/// text color for a bar fill comes from `RGB(hex:)?.contrastingText`.
public enum IdentityPalette {
    public static let colors: [String] = [
        "#4CAF50", // green
        "#2196F3", // blue
        "#FF9800", // orange
        "#9C27B0", // purple
        "#009688", // teal
        "#E91E63", // pink
        "#FFC107", // amber
        "#3F51B5", // indigo
    ]

    /// The palette color for a zero-based creation index, cycling past the end.
    public static func color(at index: Int) -> String {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter IdentityPaletteTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ConductorCore/IdentityPalette.swift Tests/ConductorCoreTests/IdentityPaletteTests.swift
git commit -m "feat(core): IdentityPalette of cycling worktree colors"
```

---

## Task 5: `Worktree.color` + auto-assign + `setWorktreeColor` (Core)

**Files:**
- Modify: `Sources/ConductorCore/Models.swift:35-45`
- Modify: `Sources/ConductorCore/WorktreeStore.swift:39-59` (createWorktree) and add `setWorktreeColor`
- Test: `Tests/ConductorCoreTests/ModelsCodableTests.swift` (append) and `Tests/ConductorCoreTests/WorktreeStoreTests.swift` (append)

**Interfaces:**
- Consumes: `IdentityPalette` (Task 4).
- Produces: `Worktree.color: String?` (hex); `WorktreeStore.setWorktreeColor(id: String, color: String?) throws -> Worktree`. `createWorktree` now sets `color = IdentityPalette.color(at: <count of existing worktrees>)`.

- [ ] **Step 1: Write the failing tests**

```swift
// Append to Tests/ConductorCoreTests/ModelsCodableTests.swift (inside ModelsCodableTests)
    func testWorktreeDecodesOldJSONWithoutColor() throws {
        let json = #"{"id":"w1","repoID":"r1","title":"T","branch":"t","worktreePath":"/tmp/wt"}"#
        let wt = try JSONDecoder().decode(Worktree.self, from: Data(json.utf8))
        XCTAssertNil(wt.color)
    }

    func testWorktreeRoundTripsColor() throws {
        var wt = Worktree(id: "w1", repoID: "r1", title: "T", branch: "t", worktreePath: "/tmp/wt")
        wt.color = "#4CAF50"
        let back = try JSONDecoder().decode(Worktree.self, from: JSONEncoder().encode(wt))
        XCTAssertEqual(back.color, "#4CAF50")
        XCTAssertEqual(back, wt)
    }
```

```swift
// Append to Tests/ConductorCoreTests/WorktreeStoreTests.swift (inside the existing XCTestCase)
    func testCreateWorktreeAutoAssignsFirstPaletteColor() throws {
        let repoPath = try makeTempRepo()
        let store = WorktreeStore(config: Config(url: tmpConfigURL()),
                                  git: GitWorktree(gitPath: "/usr/bin/git"),
                                  worktreeRoot: NSTemporaryDirectory() + "wt-" + UUID().uuidString)
        let repo = try store.addRepository(path: repoPath)
        let wt = try store.createWorktree(repoID: repo.id, title: "First")
        XCTAssertEqual(wt.color, IdentityPalette.color(at: 0))
    }

    func testSecondWorktreeGetsNextPaletteColor() throws {
        let repoPath = try makeTempRepo()
        let store = WorktreeStore(config: Config(url: tmpConfigURL()),
                                  git: GitWorktree(gitPath: "/usr/bin/git"),
                                  worktreeRoot: NSTemporaryDirectory() + "wt-" + UUID().uuidString)
        let repo = try store.addRepository(path: repoPath)
        _ = try store.createWorktree(repoID: repo.id, title: "First")
        let second = try store.createWorktree(repoID: repo.id, title: "Second")
        XCTAssertEqual(second.color, IdentityPalette.color(at: 1))
    }

    func testSetWorktreeColorPersists() throws {
        let repoPath = try makeTempRepo()
        let url = tmpConfigURL()
        let store = WorktreeStore(config: Config(url: url),
                                  git: GitWorktree(gitPath: "/usr/bin/git"),
                                  worktreeRoot: NSTemporaryDirectory() + "wt-" + UUID().uuidString)
        let repo = try store.addRepository(path: repoPath)
        let wt = try store.createWorktree(repoID: repo.id, title: "First")
        _ = try store.setWorktreeColor(id: wt.id, color: "#E91E63")
        // A fresh store reading the same config sees the override.
        let reloaded = WorktreeStore(config: Config(url: url),
                                     git: GitWorktree(gitPath: "/usr/bin/git"),
                                     worktreeRoot: NSTemporaryDirectory())
        XCTAssertEqual(reloaded.state.worktrees.first(where: { $0.id == wt.id })?.color, "#E91E63")
    }
```

> If `WorktreeStoreTests` has no `tmpConfigURL()` helper, add this private method to the test class:
> ```swift
> private func tmpConfigURL() -> URL {
>     URL(fileURLWithPath: NSTemporaryDirectory() + "cfg-" + UUID().uuidString + ".json")
> }
> ```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ModelsCodableTests`
then `... --filter WorktreeStoreTests`
Expected: FAIL — `value of type 'Worktree' has no member 'color'` / `no member 'setWorktreeColor'`.

- [ ] **Step 3: Write the implementation**

Replace `Worktree` in `Sources/ConductorCore/Models.swift:35-45` with:

```swift
public struct Worktree: Codable, Equatable, Identifiable {
    public var id: String
    public var repoID: String
    public var title: String
    public var branch: String
    public var worktreePath: String
    /// Identity color (hex, e.g. "#4CAF50") driving the full-width bar + sidebar accent.
    /// Chrome only — never the terminal grid. Auto-assigned at creation, manually overridable.
    public var color: String?

    public init(id: String, repoID: String, title: String, branch: String,
                worktreePath: String, color: String? = nil) {
        self.id = id; self.repoID = repoID; self.title = title
        self.branch = branch; self.worktreePath = worktreePath; self.color = color
    }

    private enum CodingKeys: String, CodingKey { case id, repoID, title, branch, worktreePath, color }

    // Custom decode so worktrees written before identity colors still load (color → nil).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        repoID = try c.decode(String.self, forKey: .repoID)
        title = try c.decode(String.self, forKey: .title)
        branch = try c.decode(String.self, forKey: .branch)
        worktreePath = try c.decode(String.self, forKey: .worktreePath)
        color = try c.decodeIfPresent(String.self, forKey: .color)
    }
}
```

In `Sources/ConductorCore/WorktreeStore.swift`, change the `Worktree(...)` construction inside `createWorktree` (currently at lines 54-55) to assign a palette color by creation order:

```swift
        let worktree = Worktree(id: UUID().uuidString, repoID: repoID,
                                title: title, branch: branch, worktreePath: worktreePath,
                                color: IdentityPalette.color(at: state.worktrees.count))
```

Add this method to `WorktreeStore` (e.g. after `archiveWorktree`):

```swift
    /// Override a worktree's identity color (chrome only). Pass nil to clear.
    @discardableResult
    public func setWorktreeColor(id: String, color: String?) throws -> Worktree {
        guard let idx = state.worktrees.firstIndex(where: { $0.id == id }) else {
            throw WorktreeStoreError.worktreeNotFound(id)
        }
        state.worktrees[idx].color = color
        try config.save(state)
        return state.worktrees[idx]
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ModelsCodableTests`
then `... --filter WorktreeStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ConductorCore/Models.swift Sources/ConductorCore/WorktreeStore.swift Tests/ConductorCoreTests/ModelsCodableTests.swift Tests/ConductorCoreTests/WorktreeStoreTests.swift
git commit -m "feat(core): Worktree identity color — auto-assign on create + setWorktreeColor"
```

---

## Task 6: `Preferences.activeTheme` (Core)

**Files:**
- Modify: `Sources/ConductorCore/Preferences.swift:30-35`
- Test: `Tests/ConductorCoreTests/PreferencesTests.swift` (append)

**Interfaces:**
- Produces: `Preferences.activeTheme: String?` (theme name; nil → app picks the default bundled theme).

- [ ] **Step 1: Write the failing test**

```swift
// Append to Tests/ConductorCoreTests/PreferencesTests.swift (inside PreferencesTests)
    func testActiveThemeDefaultsNilForOldPrefs() throws {
        // Prefs written before theming carried only defaultEditor.
        let json = #"{"defaultEditor":{"name":"Visual Studio Code","bundleID":"com.microsoft.VSCode","urlScheme":"vscode"}}"#
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        XCTAssertNil(prefs.activeTheme)
    }

    func testActiveThemeRoundTrips() throws {
        var prefs = Preferences()
        prefs.activeTheme = "Dracula"
        let back = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(back.activeTheme, "Dracula")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PreferencesTests`
Expected: FAIL — `value of type 'Preferences' has no member 'activeTheme'`.

- [ ] **Step 3: Write minimal implementation**

Replace the `Preferences` struct in `Sources/ConductorCore/Preferences.swift:30-35` with:

```swift
public struct Preferences: Codable, Equatable {
    public var defaultEditor: Editor
    /// Name of the active terminal theme (a file in ~/.conductor/themes/). nil → the
    /// app falls back to its default bundled theme. Synthesized Codable decodes a
    /// missing key to nil, so older prefs files still load.
    public var activeTheme: String?
    public init(defaultEditor: Editor = .vsCode, activeTheme: String? = nil) {
        self.defaultEditor = defaultEditor
        self.activeTheme = activeTheme
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PreferencesTests`
Expected: PASS. (The existing `testPreferencesHoldsNoAbsolutePaths` still passes — a nil theme name encodes nothing path-like.)

- [ ] **Step 5: Commit**

```bash
git add Sources/ConductorCore/Preferences.swift Tests/ConductorCoreTests/PreferencesTests.swift
git commit -m "feat(core): Preferences.activeTheme (portable theme selection)"
```

---

## Task 7: `ThemeStore` — list / import / seed (Core)

**Files:**
- Create: `Sources/ConductorCore/ThemeStore.swift`
- Test: `Tests/ConductorCoreTests/ThemeStoreTests.swift`

**Interfaces:**
- Consumes: `TerminalTheme` (Task 2).
- Produces: `final class ThemeStore { init(directory: URL); func availableThemeURLs() -> [URL]; func themeNames() -> [String]; func loadTheme(named: String) -> TerminalTheme?; @discardableResult func importTheme(from source: URL) throws -> URL; func seedIfEmpty(from sources: [URL]) throws }`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ConductorCoreTests/ThemeStoreTests.swift
import XCTest
@testable import ConductorCore

final class ThemeStoreTests: XCTestCase {
    /// Write a minimal `.itermcolors` to `dir` and return its URL.
    private func writeTheme(_ name: String, in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func comp(_ v: Double) -> [String: Any] { ["Red Component": v, "Green Component": v, "Blue Component": v] }
        var dict: [String: Any] = ["Foreground Color": comp(1), "Background Color": comp(0), "Cursor Color": comp(0.5)]
        for i in 0..<16 { dict["Ansi \(i) Color"] = comp(0) }
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        let url = dir.appendingPathComponent("\(name).itermcolors")
        try data.write(to: url)
        return url
    }

    private func tmpDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory() + "themes-" + UUID().uuidString, isDirectory: true)
    }

    func testListsOnlyItermcolorsFiles() throws {
        let dir = tmpDir()
        _ = try writeTheme("Dracula", in: dir)
        try "noise".write(to: dir.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        let store = ThemeStore(directory: dir)
        XCTAssertEqual(store.themeNames(), ["Dracula"])
    }

    func testImportCopiesFileIn() throws {
        let dir = tmpDir()
        let source = try writeTheme("Nord", in: tmpDir())
        let store = ThemeStore(directory: dir)
        try store.importTheme(from: source)
        XCTAssertEqual(store.themeNames(), ["Nord"])
        XCTAssertNotNil(store.loadTheme(named: "Nord"))
    }

    func testSeedIfEmptyCopiesSourcesWhenDirEmpty() throws {
        let dir = tmpDir()
        let a = try writeTheme("A", in: tmpDir())
        let b = try writeTheme("B", in: tmpDir())
        let store = ThemeStore(directory: dir)
        try store.seedIfEmpty(from: [a, b])
        XCTAssertEqual(Set(store.themeNames()), ["A", "B"])
    }

    func testSeedIfEmptyDoesNothingWhenNotEmpty() throws {
        let dir = tmpDir()
        _ = try writeTheme("Existing", in: dir)
        let extra = try writeTheme("Extra", in: tmpDir())
        let store = ThemeStore(directory: dir)
        try store.seedIfEmpty(from: [extra])
        XCTAssertEqual(store.themeNames(), ["Existing"], "must not seed over a populated dir")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ThemeStoreTests`
Expected: FAIL — `cannot find 'ThemeStore' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/ConductorCore/ThemeStore.swift
import Foundation

/// Manages `.itermcolors` files in the portable themes directory (~/.conductor/themes/).
/// Import copies a file in; seed populates the dir from bundled starter themes on first run.
public final class ThemeStore {
    private let directory: URL
    private let fm = FileManager.default

    public init(directory: URL) { self.directory = directory }

    public func availableThemeURLs() -> [URL] {
        guard let urls = try? fm.contentsOfDirectory(at: directory,
                                                     includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension == "itermcolors" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func themeNames() -> [String] {
        availableThemeURLs().map { $0.deletingPathExtension().lastPathComponent }
    }

    public func loadTheme(named name: String) -> TerminalTheme? {
        let url = directory.appendingPathComponent("\(name).itermcolors")
        return try? TerminalTheme.load(from: url)
    }

    /// Copy a `.itermcolors` into the themes dir (overwriting a same-named one). Returns the destination.
    @discardableResult
    public func importTheme(from source: URL) throws -> URL {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(source.lastPathComponent)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: source, to: dest)
        return dest
    }

    /// Populate the themes dir from `sources` only if it currently has no themes.
    public func seedIfEmpty(from sources: [URL]) throws {
        guard availableThemeURLs().isEmpty else { return }
        for source in sources { try importTheme(from: source) }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ThemeStoreTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Run the full Core suite to confirm nothing regressed**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: PASS (all prior tests + the new ones).

- [ ] **Step 6: Commit**

```bash
git add Sources/ConductorCore/ThemeStore.swift Tests/ConductorCoreTests/ThemeStoreTests.swift
git commit -m "feat(core): ThemeStore — list/import/seed .itermcolors files"
```

---

## Task 8: Shell color adapters (`ThemeAppKit`)

**Files:**
- Create: `Sources/Conductor/ThemeAppKit.swift`

**Interfaces:**
- Consumes: `RGB`, `ThemeAppearance` (Core).
- Produces: `extension RGB { var nsColor: NSColor; var swiftTermColor: SwiftTerm.Color }`, `extension NSColor { convenience init?(hex: String) }`, `extension ThemeAppearance { var nsAppearance: NSAppearance? }`.

> Shell-only glue over AppKit/SwiftTerm; verified by compiling. The numeric conversions
> (0–1 → UInt16 0–65535) match the proven spike code.

- [ ] **Step 1: Write the implementation**

```swift
// Sources/Conductor/ThemeAppKit.swift
import AppKit
import SwiftTerm
import ConductorCore

extension RGB {
    /// sRGB NSColor for chrome.
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
    }

    /// SwiftTerm color (UInt16 0...65535 channels), matching the spike's conversion.
    var swiftTermColor: SwiftTerm.Color {
        func chan(_ x: Double) -> UInt16 { UInt16(min(max(x, 0), 1) * 65535) }
        return SwiftTerm.Color(red: chan(r), green: chan(g), blue: chan(b))
    }
}

extension NSColor {
    /// Convenience for hex strings stored on a worktree's identity color.
    convenience init?(hex: String) {
        guard let rgb = RGB(hex: hex) else { return nil }
        self.init(srgbRed: CGFloat(rgb.r), green: CGFloat(rgb.g), blue: CGFloat(rgb.b), alpha: 1)
    }
}

extension ThemeAppearance {
    var nsAppearance: NSAppearance? {
        switch self {
        case .dark:  return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/Conductor/ThemeAppKit.swift
git commit -m "feat(app): RGB→NSColor/SwiftTerm + ThemeAppearance→NSAppearance adapters"
```

---

## Task 9: Apply a `TerminalTheme` to a `TerminalSurface`

**Files:**
- Modify: `Sources/Conductor/TerminalSurface.swift`

**Interfaces:**
- Consumes: `TerminalTheme` (Core), `RGB.swiftTermColor` / `.nsColor` (Task 8).
- Produces: `TerminalSurface.applyTheme(_ theme: TerminalTheme)` — installs ANSI + native fg/bg/cursor on the live terminal. Also caches the theme so a not-yet-started terminal gets it on first layout.

- [ ] **Step 1: Write the implementation**

In `Sources/Conductor/TerminalSurface.swift`, add a stored property near the other `private var`s (after line 12 `private var terminal:`):

```swift
    private var pendingTheme: TerminalTheme?
```

Add this method (e.g. after `sendCommand`):

```swift
    /// Apply a terminal color scheme: 16 ANSI colors + native fg/bg/cursor. Safe to call
    /// before the PTY starts — the theme is cached and applied once the view lays out.
    func applyTheme(_ theme: TerminalTheme) {
        pendingTheme = theme
        guard terminal != nil else { return }
        terminal.installColors(theme.ansi.map { $0.swiftTermColor })
        terminal.nativeForegroundColor = theme.foreground.nsColor
        terminal.nativeBackgroundColor = theme.background.nsColor
        terminal.caretColor = theme.cursor.nsColor
    }
```

In `viewDidLayout()`, after the `terminal.startProcess(...)` call (after line 81), apply any cached theme so a freshly built surface is themed immediately:

```swift
        if let pendingTheme { applyTheme(pendingTheme) }
```

> `installColors`, `nativeForegroundColor`, `nativeBackgroundColor`, `caretColor` are the SwiftTerm APIs proven in the spike (DECISIONS.md "SwiftTerm 1.13.0 API notes").

- [ ] **Step 2: Verify it compiles**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/Conductor/TerminalSurface.swift
git commit -m "feat(app): TerminalSurface.applyTheme installs ANSI + native colors"
```

---

## Task 10: Bundle starter themes + load/seed/apply the active theme on launch

**Files:**
- Create: `Sources/Conductor/Themes/Dracula.itermcolors`, `Sources/Conductor/Themes/Solarized Light.itermcolors`, `Sources/Conductor/Themes/Nord.itermcolors`
- Modify: `Package.swift:12-18` (resources on the `Conductor` target)
- Modify: `Sources/Conductor/AppDelegate.swift` (properties + `applicationDidFinishLaunching` + new `loadActiveTheme`/`applyActiveTheme`)

**Interfaces:**
- Consumes: `ThemeStore`, `TerminalTheme`, `ChromeTheme`, `Preferences.activeTheme` (Core).
- Produces (AppDelegate, private): `themeStore: ThemeStore`, `activeTheme: TerminalTheme`, `bundledThemeURLs() -> [URL]`, `defaultThemeName = "Dracula"`, `loadActiveTheme() -> TerminalTheme`, `applyActiveTheme()`.

- [ ] **Step 1: Add the bundled theme files**

Obtain three real `.itermcolors` files and save them at the exact paths above. Get them from the iTerm2-Color-Schemes repo (each scheme's `schemes/<Name>.itermcolors`):
- `Dracula.itermcolors`, `Nord.itermcolors`, `Solarized Light.itermcolors`.

If fetching is unavailable, generate a valid file from a known palette with this one-off script (run once per theme, then delete the script — do NOT commit it):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift - <<'SWIFT'
import Foundation
// Dracula palette (background #282A36, foreground #F8F8F2, cursor #F8F8F0,
// ANSI 0..15 from the Dracula spec). Replace values per theme.
let bg = (40.0,42.0,54.0), fg = (248.0,248.0,242.0), cur = (248.0,248.0,240.0)
let ansi: [(Double,Double,Double)] = [
 (0,0,0),(255,85,85),(80,250,123),(241,250,140),(189,147,249),(255,121,198),(139,233,253),(191,191,191),
 (77,77,77),(255,110,103),(90,247,142),(244,249,157),(202,169,250),(255,146,208),(154,237,254),(230,230,230)]
func comp(_ t:(Double,Double,Double))->[String:Any]{["Red Component":t.0/255,"Green Component":t.1/255,"Blue Component":t.2/255]}
var d:[String:Any]=["Foreground Color":comp(fg),"Background Color":comp(bg),"Cursor Color":comp(cur)]
for (i,c) in ansi.enumerated(){ d["Ansi \(i) Color"]=comp(c) }
let data = try! PropertyListSerialization.data(fromPropertyList:d, format:.xml, options:0)
try! data.write(to: URL(fileURLWithPath:"Sources/Conductor/Themes/Dracula.itermcolors"))
print("wrote Dracula")
SWIFT
```

(Repeat with Nord and Solarized Light palettes / filenames. Solarized Light has a light background `#FDF6E3`, exercising the light-appearance path.)

- [ ] **Step 2: Declare the resources in `Package.swift`**

Change the `Conductor` executable target (lines 12-18) to:

```swift
        .executableTarget(
            name: "Conductor",
            dependencies: [
                "ConductorCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            resources: [.copy("Themes")]
        ),
```

- [ ] **Step 3: Verify resources bundle and `Bundle.module` resolves**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: Build succeeds (SwiftPM generates the resource accessor for `Bundle.module`).

- [ ] **Step 4: Wire load/seed/apply into AppDelegate**

Add properties near the other stores (after line 23 `private var preferences = Preferences()`):

```swift
    private var themeStore: ThemeStore!
    private var activeTheme: TerminalTheme!
    private let defaultThemeName = "Dracula"
```

In `applicationDidFinishLaunching`, after `preferences = prefsStore.load()` (line 36), insert:

```swift
        themeStore = ThemeStore(url: home.appendingPathComponent(".conductor/themes"))
        try? themeStore.seedIfEmpty(from: bundledThemeURLs())
        activeTheme = loadActiveTheme()
```

> Note: `ThemeStore`'s initializer parameter is named `directory:`. Call it as
> `ThemeStore(directory: home.appendingPathComponent(".conductor/themes"))`.

Add these methods to `AppDelegate` (e.g. near `makeStore`):

```swift
    /// The bundled starter `.itermcolors` shipped as app resources.
    private func bundledThemeURLs() -> [URL] {
        Bundle.module.urls(forResourcesWithExtension: "itermcolors", subdirectory: "Themes") ?? []
    }

    /// The active terminal theme: the user's chosen one, else the default, else a hard
    /// fallback so the app always has a theme to draw.
    private func loadActiveTheme() -> TerminalTheme {
        if let name = preferences.activeTheme, let theme = themeStore.loadTheme(named: name) { return theme }
        if let theme = themeStore.loadTheme(named: defaultThemeName) { return theme }
        // Last-resort fallback (themes dir empty / unreadable): plain black-on-white.
        return TerminalTheme(name: "Default",
                             ansi: Array(repeating: .black, count: 16),
                             foreground: .black, background: .white, cursor: .black)
    }
```

- [ ] **Step 5: Verify it compiles**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: Build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/Conductor/Themes Sources/Conductor/AppDelegate.swift
git commit -m "feat(app): bundle starter themes; seed + load active theme on launch"
```

---

## Task 11: Apply the active theme to all live terminals + chrome on launch and on change

**Files:**
- Modify: `Sources/Conductor/AppDelegate.swift` (`select`, new `applyActiveTheme` + `applyChromeTheme`; call on launch)

**Interfaces:**
- Consumes: `ChromeTheme`, `RGB.nsColor`, `ThemeAppearance.nsAppearance` (Tasks 3, 8), `activeTheme` (Task 10).
- Produces (AppDelegate, private): `applyActiveTheme()` (theme → all live surfaces + chrome), `applyChromeTheme()` (window appearance + bg). New surfaces in `select` get themed on creation.

- [ ] **Step 1: Implement `applyActiveTheme` + `applyChromeTheme`**

Add to `AppDelegate`:

```swift
    /// Push the active terminal theme to every live surface and repaint the chrome.
    private func applyActiveTheme() {
        for wt in store.state.worktrees {
            surfaces.handle(for: wt.id)?.applyTheme(activeTheme)
        }
        applyChromeTheme()
    }

    /// iTerm2-style: the window blends into the terminal background and flips
    /// light/dark by its luminance. All chrome colors read from ChromeTheme.
    private func applyChromeTheme() {
        let chrome = ChromeTheme(terminal: activeTheme)
        window.appearance = chrome.appearance.nsAppearance
        window.backgroundColor = chrome.color(.windowBackground).nsColor
        sidebar.applyChrome(chrome)
        updateNotch()
    }
```

In `select(_:)`, where a brand-new surface is built (right after `surfaces.register(surface, for: s.id)` at line 237), theme it immediately:

```swift
            surface.applyTheme(activeTheme)
```

In `applicationDidFinishLaunching`, after `refreshSidebar(...)` (line 42), apply chrome once at startup:

```swift
        applyChromeTheme()
```

> `sidebar.applyChrome(_:)` is added in Task 12. To keep this task building on its own,
> add a temporary no-op now and replace it in Task 12 — OR sequence Task 12 first. The
> recommended order is **Task 12 before Task 11's `sidebar.applyChrome` line**; if doing
> 11 first, stub `func applyChrome(_ chrome: ChromeTheme) {}` on `SidebarController`.

- [ ] **Step 2: Verify it compiles**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: Build succeeds (with the Task 12 method present or stubbed).

- [ ] **Step 3: Commit**

```bash
git add Sources/Conductor/AppDelegate.swift
git commit -m "feat(app): apply active theme to live terminals + chrome (window bg + appearance)"
```

---

## Task 12: Route sidebar chrome colors through `ChromeTheme`

**Files:**
- Modify: `Sources/Conductor/SidebarController.swift`

**Interfaces:**
- Consumes: `ChromeTheme`, `RGB.nsColor` (Tasks 3, 8), worktree `color` hex (Task 5), `NSColor(hex:)` (Task 8).
- Produces: `SidebarController.applyChrome(_ chrome: ChromeTheme)`; worktree rows show a small identity-color swatch; repo-header/glyph tints come from `ChromeTheme` instead of `.secondaryLabelColor`.

- [ ] **Step 1: Implement chrome application + identity swatch**

Add a stored property and method to `SidebarController` (after `private var agentStates` at line 53):

```swift
    private var chrome: ChromeTheme?

    /// Repaint chrome-derived colors (header/glyph tints). Triggers a reload so cells
    /// pick up the new tints. Identity-color swatches come from each worktree's own color.
    func applyChrome(_ chrome: ChromeTheme) {
        self.chrome = chrome
        outline.reloadData()
    }
```

In `outlineView(_:viewFor:item:)`, replace the repo-header tint line (line 178) `cell.textField?.textColor = .secondaryLabelColor` with:

```swift
            cell.textField?.textColor = (chrome?.color(.secondaryText).nsColor) ?? .secondaryLabelColor
```

In the same method, give worktree rows their identity swatch. The current `WorktreeNode` branch (lines 181-186) becomes:

```swift
        if let wt = item as? WorktreeNode {
            let cell = makeWorktreeCell()
            cell.textField?.stringValue = "\(wt.worktree.title)  [\(wt.worktree.branch)]"
            cell.applyBadge(agentStates[wt.worktree.id] ?? .idle)
            cell.applyIdentityColor(wt.worktree.color.flatMap { NSColor(hex: $0) },
                                    glyphTint: chrome?.color(.glyphTint).nsColor)
            return cell
        }
```

Update `WorktreeCellView` (lines 32-45) to draw the identity swatch on its branch glyph and accept the glyph tint:

```swift
private final class WorktreeCellView: NSTableCellView {
    let badge = NSView()

    func applyBadge(_ state: AgentState) {
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        if let color = agentBadgeColor(state) {
            badge.layer?.backgroundColor = color.cgColor
            badge.isHidden = false
        } else {
            badge.isHidden = true
        }
    }

    /// Tint the branch glyph with the worktree's identity color (chrome-only signal),
    /// falling back to the chrome glyph tint when the worktree has no color.
    func applyIdentityColor(_ identity: NSColor?, glyphTint: NSColor?) {
        imageView?.contentTintColor = identity ?? glyphTint ?? .secondaryLabelColor
    }
}
```

In `makeWorktreeCell()`, the glyph tint default (line 218 `icon.contentTintColor = .secondaryLabelColor`) is now set per-row by `applyIdentityColor`, so leave the initial value as a harmless default.

In `makeCell(identifier:symbol:)`, the header glyph tint (line 261) `image.contentTintColor = .secondaryLabelColor` may stay as-is (repo headers have no symbol in current use).

- [ ] **Step 2: Verify it compiles**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: Build succeeds. (If Task 11 used a stub `applyChrome`, this real method replaces it — remove the stub.)

- [ ] **Step 3: Commit**

```bash
git add Sources/Conductor/SidebarController.swift
git commit -m "feat(app): sidebar chrome tints via ChromeTheme + per-worktree identity swatch"
```

---

## Task 13: Full-width `WorktreeBar` + notch demotion

**Files:**
- Create: `Sources/Conductor/WorktreeBar.swift`
- Modify: `Sources/Conductor/AppDelegate.swift` (`buildWindow`/`select` layout, `updateNotch`)

**Interfaces:**
- Consumes: worktree `color` hex (Task 5), `NSColor(hex:)` + `RGB.contrastingText` via Core (Tasks 1, 8), `agentBadgeColor` (existing), `activeTheme` for fallback fill.
- Produces: `final class WorktreeBar: NSView { func update(title: String?, branch: String?, colorHex: String?, agentState: AgentState) }`; mounted between the toolbar and the terminal in the detail pane. Notch shows time-of-day glyph only (no worktree text/badge).

- [ ] **Step 1: Implement `WorktreeBar`**

```swift
// Sources/Conductor/WorktreeBar.swift
import AppKit
import ConductorCore

/// The full-width identity bar above the terminal: identity-color fill + worktree
/// title + branch + agent-state dot. The iTerm colored-tab analogue. Text auto-picks
/// black/white for contrast against the fill.
final class WorktreeBar: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    private let badge = NSView()
    static let height: CGFloat = 26

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        branchLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        titleLabel.lineBreakMode = .byTruncatingTail
        branchLabel.lineBreakMode = .byTruncatingMiddle

        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleLabel, branchLabel, NSView(), badge])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            badge.widthAnchor.constraint(equalToConstant: 8),
            badge.heightAnchor.constraint(equalToConstant: 8),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func update(title: String?, branch: String?, colorHex: String?, agentState: AgentState) {
        guard let title else { isHidden = true; return }
        isHidden = false
        let fill = colorHex.flatMap { RGB(hex: $0) } ?? RGB(r: 0.4, g: 0.4, b: 0.4)
        layer?.backgroundColor = fill.nsColor.cgColor
        let textColor = fill.contrastingText.nsColor
        titleLabel.stringValue = title
        titleLabel.textColor = textColor
        branchLabel.stringValue = branch.map { "[\($0)]" } ?? ""
        branchLabel.textColor = textColor.withAlphaComponent(0.85)
        if let dot = agentBadgeColor(agentState) {
            badge.layer?.backgroundColor = dot.cgColor
            badge.isHidden = false
        } else {
            badge.isHidden = true
        }
    }
}
```

- [ ] **Step 2: Mount the bar in the detail pane**

In `AppDelegate`, add a property (after line 11 `private let detail = ...`):

```swift
    private let worktreeBar = WorktreeBar()
```

The detail pane currently constrains each surface to fill `detail.view` (lines 241-246). Change `buildWindow` so the bar sits at the top and surfaces fill the space below it. After `detail.view = NSView()` (line 75) add:

```swift
        detail.view.addSubview(worktreeBar)
        NSLayoutConstraint.activate([
            worktreeBar.topAnchor.constraint(equalTo: detail.view.topAnchor),
            worktreeBar.leadingAnchor.constraint(equalTo: detail.view.leadingAnchor),
            worktreeBar.trailingAnchor.constraint(equalTo: detail.view.trailingAnchor),
        ])
        worktreeBar.isHidden = true
```

In `select(_:)`, change the surface top constraint (line 242) from pinning to `detail.view.topAnchor` to pinning below the bar:

```swift
                surface.view.topAnchor.constraint(equalTo: worktreeBar.bottomAnchor),
```

And at the end of `select(_:)` (after `currentSurface = surface`, line 248) update the bar:

```swift
        worktreeBar.update(title: s.title, branch: s.branch, colorHex: s.color,
                           agentState: agentStates[s.id] ?? .idle)
```

Also handle the cleared selection: in `select`, in the `guard let s else { return }` path (line 220), hide the bar first:

```swift
        guard let s else { worktreeBar.update(title: nil, branch: nil, colorHex: nil, agentState: .idle); return }
```

- [ ] **Step 3: Demote the notch to time-of-day only**

In `updateNotch()` (lines 449-465), drop the worktree focus text and the badge. Replace the body after the icon lines (lines 454-464) with:

```swift
        let time = Self.notchTimeFormatter.string(from: now).lowercased()
        notchLabel.stringValue = time
        notchLabel.textColor = (ChromeTheme(terminal: activeTheme).color(.secondaryText).nsColor)
        notchBadge.isHidden = true
```

Refresh the bar's badge as agent state polls in (so the bar stays live): at the end of `pollAgentStates()` (after `updateNotch()`, line 446) add:

```swift
        if let s = selectedWorktree {
            worktreeBar.update(title: s.title, branch: s.branch, colorHex: s.color,
                               agentState: agentStates[s.id] ?? .idle)
        }
```

- [ ] **Step 4: Verify it compiles**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/Conductor/WorktreeBar.swift Sources/Conductor/AppDelegate.swift
git commit -m "feat(app): full-width worktree identity bar; demote notch to time-of-day"
```

---

## Task 14: Settings "Themes" tab — list, import, apply live

**Files:**
- Create: `Sources/Conductor/ThemeSettingsViewController.swift`
- Modify: `Sources/Conductor/SettingsTabController.swift`
- Modify: `Sources/Conductor/AppDelegate.swift` (`openSettings` wiring + `setActiveTheme`)

**Interfaces:**
- Consumes: `ThemeStore` (Task 7), `Preferences.activeTheme` (Task 6), `applyActiveTheme` (Task 11).
- Produces: `ThemeSettingsViewController(themeNames: [String], active: String?, onApply: (String) -> Void, onImport: (URL) -> Void)`; `SettingsTabController` gains a `themeNames`/`activeTheme`/`onApplyTheme`/`onImportTheme` set of init params and a Themes tab; AppDelegate gains `setActiveTheme(named:)`.

- [ ] **Step 1: Implement the Themes pane**

```swift
// Sources/Conductor/ThemeSettingsViewController.swift
import AppKit
import ConductorCore

/// Settings → Themes: a list of installed `.itermcolors`, an Import button, and
/// click-to-apply. Applying repaints terminals + chrome live (handled by AppDelegate).
final class ThemeSettingsViewController: NSViewController {
    private var themeNames: [String]
    private var active: String?
    private let onApply: (String) -> Void
    private let onImport: (URL) -> Void

    private let tableView = NSTableView()
    private let scroll = NSScrollView()

    init(themeNames: [String], active: String?,
         onApply: @escaping (String) -> Void, onImport: @escaping (URL) -> Void) {
        self.themeNames = themeNames
        self.active = active
        self.onApply = onApply
        self.onImport = onImport
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))

        let column = NSTableColumn(identifier: .init("theme"))
        column.title = "Theme"
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(applySelected)
        tableView.target = self
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let applyButton = NSButton(title: "Apply", target: self, action: #selector(applySelected))
        let importButton = NSButton(title: "Import .itermcolors…", target: self, action: #selector(importTheme))
        let buttons = NSStackView(views: [importButton, NSView(), applyButton])
        buttons.orientation = .horizontal
        buttons.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scroll)
        container.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            buttons.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])
        view = container
        selectActiveRow()
    }

    private func selectActiveRow() {
        if let active, let idx = themeNames.firstIndex(of: active) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
    }

    @objc private func applySelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < themeNames.count else { return }
        active = themeNames[row]
        onApply(themeNames[row])
    }

    @objc private func importTheme() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["itermcolors"]
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onImport(url)
        // The store copied it in; refresh the list and select it.
        let name = url.deletingPathExtension().lastPathComponent
        if !themeNames.contains(name) { themeNames.append(name); themeNames.sort() }
        tableView.reloadData()
        if let idx = themeNames.firstIndex(of: name) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
    }
}

extension ThemeSettingsViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { themeNames.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("themeCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let c = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf); c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            c.identifier = id
            return c
        }()
        cell.textField?.stringValue = themeNames[row]
        return cell
    }
}
```

- [ ] **Step 2: Add the tab to `SettingsTabController`**

Extend the initializer in `Sources/Conductor/SettingsTabController.swift` to accept theme params and add the tab:

```swift
    init(editor: Editor,
         onChangeEditor: @escaping (Editor) -> Void,
         keybindings: Keybindings,
         onChange: @escaping (Keybindings) -> Void,
         themeNames: [String],
         activeTheme: String?,
         onApplyTheme: @escaping (String) -> Void,
         onImportTheme: @escaping (URL) -> Void) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar

        let general = GeneralSettingsViewController(editor: editor)
        general.onChangeEditor = onChangeEditor
        let generalItem = NSTabViewItem(viewController: general)
        generalItem.label = "General"
        generalItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")
        addTabViewItem(generalItem)

        let themes = ThemeSettingsViewController(themeNames: themeNames, active: activeTheme,
                                                 onApply: onApplyTheme, onImport: onImportTheme)
        let themesItem = NSTabViewItem(viewController: themes)
        themesItem.label = "Themes"
        themesItem.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "Themes")
        addTabViewItem(themesItem)

        let keys = KeybindingsViewController(bindings: keybindings)
        keys.onChange = onChange
        let keysItem = NSTabViewItem(viewController: keys)
        keysItem.label = "Keyboard Shortcuts"
        keysItem.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keyboard Shortcuts")
        addTabViewItem(keysItem)
    }
```

- [ ] **Step 3: Wire it in AppDelegate**

In `openSettings()` (lines 127-139), pass the new params to `SettingsTabController(...)`:

```swift
            let tab = SettingsTabController(
                editor: preferences.defaultEditor,
                onChangeEditor: { [weak self] editor in self?.setDefaultEditor(editor) },
                keybindings: keybindings,
                onChange: { [weak self] bindings in self?.applyKeybindings(bindings) },
                themeNames: themeStore.themeNames(),
                activeTheme: preferences.activeTheme ?? defaultThemeName,
                onApplyTheme: { [weak self] name in self?.setActiveTheme(named: name) },
                onImportTheme: { [weak self] url in try? self?.themeStore.importTheme(from: url) })
```

> The Settings window is cached (`settingsWC`) and rebuilt only when nil. That's fine: an
> imported theme is applied via `onApplyTheme`, and the list refreshes within the open
> pane (Step 1). No need to invalidate the cached window for this milestone.

Add `setActiveTheme(named:)` to `AppDelegate`:

```swift
    /// Switch the global terminal theme: persist the choice, reload it, re-theme
    /// every live terminal and the chrome.
    private func setActiveTheme(named name: String) {
        guard let theme = themeStore.loadTheme(named: name) else { return }
        activeTheme = theme
        preferences.activeTheme = name
        do { try prefsStore.save(preferences) } catch { presentError(error) }
        applyActiveTheme()
    }
```

- [ ] **Step 4: Verify it compiles**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/Conductor/ThemeSettingsViewController.swift Sources/Conductor/SettingsTabController.swift Sources/Conductor/AppDelegate.swift
git commit -m "feat(app): Settings Themes tab — list/import/apply terminal themes live"
```

---

## Task 15: Sidebar "Set Color…" — override a worktree's identity color

**Files:**
- Modify: `Sources/Conductor/SidebarController.swift` (context menu + new callback)
- Modify: `Sources/Conductor/AppDelegate.swift` (wire callback → `setWorktreeColor`)

**Interfaces:**
- Consumes: `IdentityPalette.colors` (Task 4), `WorktreeStore.setWorktreeColor` (Task 5), `NSColor(hex:)` (Task 8).
- Produces: `SidebarController.onSetWorktreeColor: ((_ worktreeID: String, _ hex: String) -> Void)?`; a "Set Color" submenu of palette swatches on a right-clicked worktree row.

- [ ] **Step 1: Add the callback + clicked-worktree lookup to `SidebarController`**

Add near the other callbacks (after line 62 `var onNewWorktree`):

```swift
    /// Right-click a worktree → pick a palette color for its identity bar/accent.
    var onSetWorktreeColor: ((String, String) -> Void)?
```

Add a helper next to `clickedRepoID()`:

```swift
    /// The worktree id of the right-clicked row, or nil if a repo header was clicked.
    private func clickedWorktreeID() -> String? {
        let row = outline.clickedRow
        guard row >= 0, let wt = outline.item(atRow: row) as? WorktreeNode else { return nil }
        return wt.worktree.id
    }

    @objc private func contextSetColor(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let id = info["id"], let hex = info["hex"] else { return }
        onSetWorktreeColor?(id, hex)
    }
```

- [ ] **Step 2: Add the "Set Color" submenu in `menuNeedsUpdate`**

In `menuNeedsUpdate(_:)` (lines 138-151), after the existing two items, append a color submenu when a worktree row was clicked:

```swift
        if let worktreeID = clickedWorktreeID() {
            menu.addItem(.separator())
            let colorItem = NSMenuItem(title: "Set Color", action: nil, keyEquivalent: "")
            let colorMenu = NSMenu()
            for hex in IdentityPalette.colors {
                let swatch = NSMenuItem(title: hex, action: #selector(contextSetColor(_:)), keyEquivalent: "")
                swatch.target = self
                swatch.representedObject = ["id": worktreeID, "hex": hex]
                if let color = NSColor(hex: hex) {
                    swatch.image = Self.swatchImage(color)
                }
                colorMenu.addItem(swatch)
            }
            colorItem.submenu = colorMenu
            menu.addItem(colorItem)
        }
```

Add the swatch-image helper to `SidebarController`:

```swift
    /// A small filled square for a color menu item.
    private static func swatchImage(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 2, yRadius: 2).fill()
        image.unlockFocus()
        return image
    }
```

- [ ] **Step 3: Wire the callback in AppDelegate**

In `wireSidebar()` (lines 101-105), add:

```swift
        sidebar.onSetWorktreeColor = { [weak self] worktreeID, hex in self?.setWorktreeColor(worktreeID, hex) }
```

Add the handler to `AppDelegate`:

```swift
    /// Override a worktree's identity color and repaint its bar + sidebar row.
    private func setWorktreeColor(_ worktreeID: String, _ hex: String) {
        do {
            _ = try store.setWorktreeColor(id: worktreeID, color: hex)
            refreshSidebar(select: selectedWorktree?.id)
            if let s = store.state.worktrees.first(where: { $0.id == worktreeID }), s.id == selectedWorktree?.id {
                selectedWorktree = s
                worktreeBar.update(title: s.title, branch: s.branch, colorHex: s.color,
                                   agentState: agentStates[s.id] ?? .idle)
            }
        } catch { presentError(error) }
    }
```

- [ ] **Step 4: Verify it compiles**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/Conductor/SidebarController.swift Sources/Conductor/AppDelegate.swift
git commit -m "feat(app): right-click worktree → Set Color (palette swatches)"
```

---

## Task 16: Full build + test + in-app verification (milestone gate)

**Files:** none (verification only).

- [ ] **Step 1: Full Core test suite green**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: All tests pass (101 prior + ~24 new). Note the exact count in the commit/PR.

- [ ] **Step 2: Release-mode build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: Build succeeds, no warnings about the new files.

- [ ] **Step 3: Launch and verify in-app (PAUSE for the user)**

Run the app (the project's run method) and confirm with the user:
1. First launch seeds `~/.conductor/themes/` with the 3 bundled themes; the terminal renders the default (Dracula) — dark grid.
2. The window chrome (sidebar, toolbar, window bg) is dark and blends into the terminal background; switching worktrees does NOT change the terminal/chrome (global theme).
3. A new worktree gets a distinct palette color; the **full-width bar** shows color + title + branch + agent badge; bar text is legible (black/white by contrast).
4. The **notch** shows only the time-of-day glyph (no worktree text/badge).
5. Settings → **Themes**: applying "Solarized Light" flips the terminal AND the chrome to light immediately, across all open terminals; the choice persists across relaunch.
6. **Import** a `.itermcolors` → it appears in the list and applies.
7. Right-click a worktree → **Set Color** → the bar + sidebar accent update immediately and persist.

**Do not merge until the user confirms the in-app behavior.** This is the milestone's review checkpoint.

- [ ] **Step 4: Request whole-branch review**

Use `superpowers:requesting-code-review` for the full `theming` branch diff, then address findings before opening the PR.

---

## Self-Review (against the spec)

**Spec coverage:**
- `.itermcolors` import + apply → Tasks 2 (parse), 7 (store/import), 9 (apply to terminal), 14 (import UI). ✅
- Global terminal theme → Tasks 10/11 (one `activeTheme`, applied to all surfaces). ✅
- iTerm2 derived chrome (blends into bg, luminance appearance) → Tasks 3 (ChromeTheme), 8 (NSAppearance), 11 (window), 12 (sidebar). ✅
- `ChromeTheme` seam (override-aware) → Task 3 (overrides param + `color(_:)`), used everywhere in 11/12. ✅
- Per-worktree identity color, auto-assign + manual → Tasks 4 (palette), 5 (model + auto-assign + set), 15 (Set Color UI). ✅
- Full-width bar + notch demotion → Task 13. ✅
- Storage: `.itermcolors` as-is in portable dir, `activeTheme` in prefs, `color` in local.json → Tasks 5, 6, 7, 10. ✅
- Bundled starter themes → Task 10. ✅
- Settings Themes tab → Task 14. ✅
- Live apply → Tasks 11 (applyActiveTheme), 14 (setActiveTheme), 15 (setWorktreeColor). ✅

**Type consistency check:** `ThemeStore.init(directory:)` is called as `directory:` in Task 10 (a callout flags the spike's `url:` mismatch). `applyTheme(_:)`, `applyChrome(_:)`, `applyActiveTheme()`, `setActiveTheme(named:)`, `setWorktreeColor(_:_:)`, `onSetWorktreeColor`, `WorktreeBar.update(title:branch:colorHex:agentState:)` are defined once and called with matching labels. `ChromeRole` cases match between Task 3 and their uses in 11/12/13.

**Placeholder scan:** none — every step has complete code or an exact command. The one-off theme-generation script in Task 10 is explicitly marked do-not-commit and is a fallback to fetching real files.

**Sequencing note:** Task 11 references `sidebar.applyChrome` (defined in Task 12) and `worktreeBar` (Task 13). Implement in numeric order; Task 11's callout says to stub `applyChrome` if building 11 before 12. Tasks 1–7 (Core) are independently testable and gate the shell tasks.
