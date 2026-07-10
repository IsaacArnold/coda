# Global Accent Colour Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users pick Coda's sidebar highlight colour from 8 curated swatches in Settings ▸ General, defaulting to Dracula purple.

**Architecture:** Pure logic (default + resolve + swatch list, plus the `Preferences.accentColor` field) lives in CodaCore and is unit-tested. The AppKit shell (settings swatch picker, sidebar row fill, contrast-aware text, wiring) consumes it and is verified by build + manual interaction, matching this codebase's split between tested CodaCore and untested AppKit UI.

**Tech Stack:** Swift, AppKit, SwiftPM, XCTest. Two targets: `CodaCore` (pure, no AppKit) and `Coda` (AppKit app).

## Global Constraints

- CodaCore must not import AppKit — colour→NSColor conversion happens only in the `Coda` target. Copy verbatim: default accent hex is `#BD93F9` (Dracula purple, the first `IdentityPalette.colors` entry).
- Swatch set is exactly `IdentityPalette.colors` (8 entries). No free colour picker, no "follow system accent" option.
- `Preferences` uses a hand-written `init(from:)` decoder; every new key MUST be added with `decodeIfPresent(...) ?? default` so existing `~/.coda/preferences.json` files keep loading.
- Run tests with the full-Xcode toolchain and a separate build path: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest`. Plain `swift build` (CommandLineTools) is used for build checks.
- Keyboard-shortcut notation, commit trailers: follow repo conventions. Commit trailer:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

## File Structure

- `Sources/CodaCore/AccentColor.swift` — **new.** Pure helper: default hex, swatch list, resolve.
- `Sources/CodaCore/Preferences.swift` — **modify.** Add `accentColor: String?` field + decoder.
- `Tests/CodaCoreTests/AccentColorTests.swift` — **new.** Unit tests for the helper + the `Preferences` decode/round-trip.
- `Sources/Coda/SidebarController.swift` — **modify.** Accent state + `setAccentColor`, `FocusHighlightRowView` accent fill, `WorktreeCellView` contrast text.
- `Sources/Coda/GeneralSettingsViewController.swift` — **modify.** Accent swatch section + `onChangeAccentColor`.
- `Sources/Coda/SettingsTabController.swift` — **modify.** Thread accent param + callback through to the General pane.
- `Sources/Coda/AppDelegate.swift` — **modify.** Resolve, wire settings, persist, seed sidebar.

---

## Task 1: `AccentColor` helper + `Preferences.accentColor` (CodaCore, TDD)

**Files:**
- Create: `Sources/CodaCore/AccentColor.swift`
- Modify: `Sources/CodaCore/Preferences.swift`
- Test: `Tests/CodaCoreTests/AccentColorTests.swift`

**Interfaces:**
- Produces:
  - `enum AccentColor { static let defaultHex: String; static var swatches: [String]; static func resolve(_ stored: String?) -> String }`
  - `Preferences.accentColor: String?` (new stored property; `init` default `nil`).

- [ ] **Step 1: Write the failing tests**

Create `Tests/CodaCoreTests/AccentColorTests.swift`:

```swift
import XCTest
@testable import CodaCore

final class AccentColorTests: XCTestCase {
    func testResolveNilGivesDefault() {
        XCTAssertEqual(AccentColor.resolve(nil), AccentColor.defaultHex)
    }

    func testResolveKeepsStoredValue() {
        XCTAssertEqual(AccentColor.resolve("#FF5555"), "#FF5555")
    }

    func testDefaultIsOneOfTheSwatches() {
        XCTAssertTrue(AccentColor.swatches.contains(AccentColor.defaultHex))
    }

    func testDefaultIsDraculaPurple() {
        XCTAssertEqual(AccentColor.defaultHex, "#BD93F9")
    }

    func testPreferencesDecodesMissingAccentToNil() throws {
        // A prefs blob written before this feature (no accentColor key) must still load.
        let json = """
        {"defaultEditor":{"name":"Visual Studio Code","bundleID":"com.microsoft.VSCode","urlScheme":"vscode"}}
        """.data(using: .utf8)!
        let prefs = try JSONDecoder().decode(Preferences.self, from: json)
        XCTAssertNil(prefs.accentColor)
    }

    func testPreferencesRoundTripsAccent() throws {
        var prefs = Preferences()
        prefs.accentColor = "#50FA7B"
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertEqual(decoded.accentColor, "#50FA7B")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter AccentColorTests`
Expected: FAIL — compile error, `cannot find 'AccentColor' in scope` / `value of type 'Preferences' has no member 'accentColor'`.

- [ ] **Step 3: Create the `AccentColor` helper**

Create `Sources/CodaCore/AccentColor.swift`:

```swift
import Foundation

/// The app accent colour used to highlight the focused worktree/branch row in the sidebar.
/// Pure/UI-free (Core never imports AppKit); the AppKit shell converts the hex to NSColor.
public enum AccentColor {
    /// Default accent — Dracula purple, the first identity-palette swatch.
    public static let defaultHex = "#BD93F9"

    /// The swatches offered in Settings — the curated identity palette.
    public static var swatches: [String] { IdentityPalette.colors }

    /// Resolve a stored preference (nil → default) to a concrete hex.
    public static func resolve(_ stored: String?) -> String { stored ?? defaultHex }
}
```

- [ ] **Step 4: Add the `accentColor` field to `Preferences`**

In `Sources/CodaCore/Preferences.swift`, add the stored property (place it after `askedCompletionsConsent`, around line 104):

```swift
    /// The app accent colour (hex) for the sidebar's focused-worktree highlight. nil → the
    /// app default (`AccentColor.defaultHex`). Older prefs files without the key decode to nil
    /// via the custom decoder below.
    public var accentColor: String?
```

Add the `init` parameter (extend the existing `init(...)` signature and body):

```swift
    public init(defaultEditor: Editor = .vsCode, activeTheme: String? = nil,
                terminalFont: TerminalFontPref? = nil, uiScale: UIScale = .medium,
                declinedHookInstall: Bool = false, notifyOnNeedsYou: Bool = true,
                notifyOnDone: Bool = true, shell: ShellChoice = .automatic,
                completionsEnabled: Bool = false, askedCompletionsConsent: Bool = false,
                accentColor: String? = nil) {
        self.defaultEditor = defaultEditor
        self.activeTheme = activeTheme
        self.terminalFont = terminalFont
        self.uiScale = uiScale
        self.declinedHookInstall = declinedHookInstall
        self.notifyOnNeedsYou = notifyOnNeedsYou
        self.notifyOnDone = notifyOnDone
        self.shell = shell
        self.completionsEnabled = completionsEnabled
        self.askedCompletionsConsent = askedCompletionsConsent
        self.accentColor = accentColor
    }
```

Add `accentColor` to `CodingKeys`:

```swift
    private enum CodingKeys: String, CodingKey {
        case defaultEditor, activeTheme, terminalFont, uiScale, declinedHookInstall
        case notifyOnNeedsYou, notifyOnDone, shell, completionsEnabled, askedCompletionsConsent
        case accentColor
    }
```

Add the decode line at the end of `init(from:)`:

```swift
        self.accentColor = try c.decodeIfPresent(String.self, forKey: .accentColor)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter AccentColorTests`
Expected: PASS (6 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/CodaCore/AccentColor.swift Sources/CodaCore/Preferences.swift Tests/CodaCoreTests/AccentColorTests.swift
git commit -m "feat(accent): AccentColor helper + Preferences.accentColor field

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Sidebar renders the accent fill (Coda UI)

Makes the focused-worktree highlight use the accent colour (defaulting to purple) instead of the borrowed system accent, with contrast-aware text so light swatches stay legible. Independently testable: launch → the selected worktree row is purple.

**Files:**
- Modify: `Sources/Coda/SidebarController.swift`

**Interfaces:**
- Consumes: `AccentColor.defaultHex` (Task 1); `NSColor(hex:)` (`ThemeAppKit.swift`); `RGB(hex:).contrastingText.nsColor` (`RGB.swift` + `ThemeAppKit.swift`).
- Produces: `SidebarController.setAccentColor(_ hex: String)` (Task 4 calls it).

- [ ] **Step 1: Add accent state + `setAccentColor` to `SidebarController`**

In `Sources/Coda/SidebarController.swift`, inside `final class SidebarController`, add near the other private state (e.g. just after the `identityOverrides` block, ~line 123):

```swift
    /// The app accent, used to fill the focused worktree/branch row. Seeded to the default;
    /// AppDelegate pushes the user's choice via `setAccentColor(_:)`.
    private var accentFill: NSColor = NSColor(hex: AccentColor.defaultHex) ?? .controlAccentColor
    /// The accent's contrasting text colour (black/white), applied to the selected row's labels
    /// so light accents (yellow/cyan/green) stay legible.
    private var accentTextColor: NSColor = RGB(hex: AccentColor.defaultHex)?.contrastingText.nsColor ?? .white

    /// Set the accent colour used for the focused-row highlight and repaint. Reloads (matching
    /// `setIdentityOverride`/`applyChrome`), which preserves the current selection since the
    /// items are unchanged.
    func setAccentColor(_ hex: String) {
        accentFill = NSColor(hex: hex) ?? .controlAccentColor
        accentTextColor = RGB(hex: hex)?.contrastingText.nsColor ?? .white
        outline.reloadData()
    }
```

- [ ] **Step 2: Replace `FocusHighlightRowView` to draw the accent fill**

In the same file, replace the existing `FocusHighlightRowView` definition:

```swift
private final class FocusHighlightRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set { }
    }
}
```

with:

```swift
/// The sidebar keeps a visible, accent-coloured fill on the selected worktree/branch even when
/// the outline view isn't first responder (focus normally lives in the terminal). A stock
/// source-list row dims its selection to muted grey when it loses first-responder status, and
/// its fill colour is the fixed system accent — so we force emphasis (keeps the fill vivid and
/// drives the cell's `.emphasized` backgroundStyle for contrast-aware text) and draw the fill
/// ourselves in the chosen accent colour.
private final class FocusHighlightRowView: NSTableRowView {
    /// The fill colour for the selected row (the app accent). Set by the sidebar per row.
    var accentColor: NSColor = NSColor(hex: AccentColor.defaultHex) ?? .controlAccentColor

    override var isEmphasized: Bool {
        get { true }
        set { }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        accentColor.setFill()
        let rect = bounds.insetBy(dx: 4, dy: 1)
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
    }
}
```

- [ ] **Step 3: Hand the accent colour to each row view**

Replace the existing `rowViewForItem` delegate method:

```swift
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("focusRow")
        if let reused = outline.makeView(withIdentifier: id, owner: self) as? FocusHighlightRowView {
            return reused
        }
        let row = FocusHighlightRowView()
        row.identifier = id
        return row
    }
```

with (sets `accentColor` on both reused and fresh rows):

```swift
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("focusRow")
        let row = (outline.makeView(withIdentifier: id, owner: self) as? FocusHighlightRowView)
            ?? { let r = FocusHighlightRowView(); r.identifier = id; return r }()
        row.accentColor = accentFill
        return row
    }
```

- [ ] **Step 4: Make `WorktreeCellView` text contrast-aware**

Replace the interim `backgroundStyle` override in `WorktreeCellView`:

```swift
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            subtitleLabel.textColor = backgroundStyle == .emphasized
                ? .white.withAlphaComponent(0.75)
                : .secondaryLabelColor
        }
    }
```

with a stored `selectedTextColor` plus a didSet that uses it for both title and subtitle (this didSet runs after `NSTableCellView`'s own recolour, so it overrides the default white for light accents):

```swift
    /// The colour the title/subtitle take when this is the selected (accent-filled) row — the
    /// accent's contrasting colour, so light accents get dark text. Set by the sidebar in
    /// `viewFor`; defaults to white for the (dark) default purple accent.
    var selectedTextColor: NSColor = .white

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let selected = backgroundStyle == .emphasized
            textField?.textColor = selected ? selectedTextColor : .labelColor
            subtitleLabel.textColor = selected
                ? selectedTextColor.withAlphaComponent(0.75)
                : .secondaryLabelColor
        }
    }
```

- [ ] **Step 5: Seed `selectedTextColor` when building each worktree cell**

In `outlineView(_:viewFor:item:)`, in the `if let wt = item as? WorktreeNode` branch, after `let cell = makeWorktreeCell()` (around line 363), add:

```swift
            cell.selectedTextColor = accentTextColor
```

- [ ] **Step 6: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!` (the pre-existing `AppDelegate.swift:526` `try?` warning is unrelated).

- [ ] **Step 7: Manual check**

Run the app (`.build/debug/Coda`), add/open a repo with worktrees, select a worktree. Expected: the selected row's fill is **purple** (not system blue), and stays purple after clicking into the terminal. Title/subtitle remain legible.

- [ ] **Step 8: Commit**

```bash
git add Sources/Coda/SidebarController.swift
git commit -m "feat(accent): sidebar highlight uses the accent colour with contrast-aware text

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Accent swatch picker in Settings ▸ General + full wiring (Coda UI)

Adds the 8-swatch picker to the General pane, threads it through `SettingsTabController`, and wires it in `AppDelegate` (persist + apply + seed on launch). The settings UI and its wiring are done together so the build is never left broken and the deliverable is end-to-end testable: pick a swatch → sidebar updates live and persists.

**Files:**
- Modify: `Sources/Coda/GeneralSettingsViewController.swift`
- Modify: `Sources/Coda/SettingsTabController.swift`
- Modify: `Sources/Coda/AppDelegate.swift`

**Interfaces:**
- Consumes: `AccentColor.swatches` / `AccentColor.resolve` (Task 1); `SidebarController.setAccentColor` (Task 2); `NSColor(hex:)`.
- Produces:
  - `GeneralSettingsViewController.init(..., accentColor: String)` + `var onChangeAccentColor: ((String) -> Void)?`.
  - `SettingsTabController.init(..., accentColor: String, onChangeAccentColor: @escaping (String) -> Void)`.
  - `AppDelegate.setAccentColor(_ hex: String)` (persist + apply).

- [ ] **Step 1: Add accent state, callback, and a circle-swatch helper to `GeneralSettingsViewController`**

In `Sources/Coda/GeneralSettingsViewController.swift`, add stored properties near the other UI state (after the `completionsCheckbox` block, ~line 32):

```swift
    private var accentColor: String
    private let accentSwatchRow = NSStackView()
    private var accentButtons: [NSButton] = []
```

Add the callback alongside the other `onChange…` properties (~line 40):

```swift
    var onChangeAccentColor: ((String) -> Void)?
```

- [ ] **Step 2: Accept `accentColor` in the initializer**

Extend the `init` signature and body. Change the signature line and add the assignment (place `accentColor` last):

```swift
    init(editor: Editor, terminalFont: NSFont, uiScale: UIScale,
         notifyOnNeedsYou: Bool, notifyOnDone: Bool, shell: ShellChoice,
         completionsEnabled: Bool, accentColor: String) {
        self.editor = editor
        self.terminalFont = terminalFont
        self.uiScale = uiScale
        self.notifyOnNeedsYou = notifyOnNeedsYou
        self.notifyOnDone = notifyOnDone
        self.shell = shell
        self.completionsEnabled = completionsEnabled
        self.accentColor = accentColor
        super.init(nibName: nil, bundle: nil)
    }
```

- [ ] **Step 3: Build the swatch section and add it to the stack**

In `loadView()`, before the `let stack = NSStackView(views: [...])` line (~line 157), build the accent section:

```swift
        // Accent colour — the sidebar's focused-worktree highlight. Curated swatches only.
        let accentTitle = NSTextField(labelWithString: "Accent Colour")
        accentTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        accentSwatchRow.orientation = .horizontal
        accentSwatchRow.spacing = 8
        accentButtons = AccentColor.swatches.enumerated().map { index, hex in
            let button = NSButton()
            button.title = ""
            button.isBordered = false
            button.image = Self.circleImage(NSColor(hex: hex) ?? .gray, diameter: 20)
            button.imageScaling = .scaleNone
            button.target = self
            button.action = #selector(accentSwatchClicked(_:))
            button.tag = index
            button.wantsLayer = true
            button.layer?.cornerRadius = 13
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
            accentSwatchRow.addArrangedSubview(button)
            return button
        }
        let accentHint = NSTextField(labelWithString: "Colour of the selected worktree/branch in the sidebar.")
        accentHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        accentHint.textColor = .secondaryLabelColor
```

Then add these three views to the `stack` initializer list, at the end (after the completions rows):

```swift
        let stack = NSStackView(views: [
            title, row, hint,
            fontTitle, fontRow, fontHint,
            scaleTitle, scaleRow, scaleHint,
            notifyTitle, notifyStack,
            shellTitle, shellRow, shellHint,
            completionsTitle, completionsCheckbox, completionsHint,
            accentTitle, accentSwatchRow, accentHint,
        ])
```

After the `view = container` line at the end of `loadView()`, seed the selection ring:

```swift
        updateAccentSelection()
```

- [ ] **Step 4: Add the swatch action, selection-ring updater, and circle helper**

Add these to `GeneralSettingsViewController` (near the other `@objc` handlers):

```swift
    @objc private func accentSwatchClicked(_ sender: NSButton) {
        let swatches = AccentColor.swatches
        guard swatches.indices.contains(sender.tag) else { return }
        accentColor = swatches[sender.tag]
        updateAccentSelection()
        onChangeAccentColor?(accentColor)
    }

    /// Ring the button whose swatch matches the active accent.
    private func updateAccentSelection() {
        for (index, button) in accentButtons.enumerated() {
            let isSelected = AccentColor.swatches[index] == accentColor
            button.layer?.borderWidth = isSelected ? 2 : 0
            button.layer?.borderColor = isSelected ? NSColor.labelColor.cgColor : nil
        }
    }

    /// A filled circle image for a swatch button.
    private static func circleImage(_ color: NSColor, diameter: CGFloat) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }
```

- [ ] **Step 5: Thread the param + callback through `SettingsTabController`**

In `Sources/Coda/SettingsTabController.swift`, add to the `init` signature (after `onChangeCompletionsEnabled`):

```swift
         onChangeCompletionsEnabled: @escaping (Bool) -> Void,
         accentColor: String,
         onChangeAccentColor: @escaping (String) -> Void) {
```

Update the `GeneralSettingsViewController(...)` construction to pass `accentColor`:

```swift
        let general = GeneralSettingsViewController(editor: editor, terminalFont: terminalFont, uiScale: uiScale,
                                                    notifyOnNeedsYou: notifyOnNeedsYou, notifyOnDone: notifyOnDone,
                                                    shell: shell, completionsEnabled: completionsEnabled,
                                                    accentColor: accentColor)
```

And assign the callback alongside the others (after `general.onChangeCompletionsEnabled = ...`):

```swift
        general.onChangeAccentColor = onChangeAccentColor
```

- [ ] **Step 6: Pass accent + callback to `SettingsTabController` from `AppDelegate`**

In `Sources/Coda/AppDelegate.swift`, in `openSettings()`, extend the `SettingsTabController(...)` call — add after the `onChangeCompletionsEnabled:` argument (the closing `)` moves down):

```swift
                completionsEnabled: preferences.completionsEnabled,
                onChangeCompletionsEnabled: { [weak self] on in self?.setCompletionsEnabled(on) },
                accentColor: AccentColor.resolve(preferences.accentColor),
                onChangeAccentColor: { [weak self] hex in self?.setAccentColor(hex) })
```

- [ ] **Step 7: Add the persist-and-apply setter to `AppDelegate`**

Add a method near the other setters (e.g. after `setShell(_:)`, ~line 1131). Note this is `AppDelegate.setAccentColor` (persists + applies); it is distinct from `sidebar.setAccentColor` (view-only):

```swift
    private func setAccentColor(_ hex: String) {
        preferences.accentColor = hex
        do { try prefsStore.save(preferences) } catch { presentError(error) }
        sidebar.setAccentColor(hex)
    }
```

- [ ] **Step 8: Seed the sidebar from prefs on launch**

In `applicationDidFinishLaunching(_:)`, right after the existing `applyUIMetrics()` call (~line 105), add (calls the sidebar's view-only setter directly, so launch doesn't re-save prefs):

```swift
        sidebar.setAccentColor(AccentColor.resolve(preferences.accentColor))
```

- [ ] **Step 9: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!` (only the pre-existing `AppDelegate.swift:526` `try?` warning).

- [ ] **Step 10: Full test suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest`
Expected: all tests pass, including `AccentColorTests`.

- [ ] **Step 11: Manual end-to-end check**

Run `.build/debug/Coda`. Open Settings (⌘ + ,) ▸ General:
- The active swatch (purple on a fresh profile) is ringed.
- Click **yellow** (`#F1FA8C`): the sidebar's selected worktree fill turns yellow immediately and its title/subtitle switch to **dark** text (legible).
- Click **red** (`#FF5555`): fill turns red, text is white.
- Quit and relaunch: the last-picked colour persists.

- [ ] **Step 12: Commit**

```bash
git add Sources/Coda/GeneralSettingsViewController.swift Sources/Coda/SettingsTabController.swift Sources/Coda/AppDelegate.swift
git commit -m "feat(accent): swatch picker in Settings, wired to prefs + sidebar

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Notes on TDD scope

Task 1 is pure CodaCore logic and is done test-first (red → green). Tasks 2–3 are AppKit view code with no unit-test surface in this codebase (consistent with `GeneralSettingsViewController`, `SidebarController`, etc. having no tests) — they are verified by `swift build` plus the explicit manual checks. The behavioural contract that *can* be unit-tested (default resolution, backward-compatible decode) is fully covered in Task 1.
