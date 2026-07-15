# Settings Sidebar Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Coda's toolbar-tab Settings window with a macOS System Settings / Supacode style sidebar + grouped-cards layout, re-sorting the existing settings into five categories without changing any persisted behaviour.

**Architecture:** An `NSSplitViewController` hosts a source-list sidebar (`SettingsSidebarViewController`) and a detail container that swaps one of five pane view controllers on selection. Panes are assembled from a reusable card kit (`SettingsCard`, `SettingsRow`, `SettingsPane`). All initial values and `onChange` closures are bundled into one `SettingsContext` struct built by `AppDelegate`, replacing the 20+-parameter `SettingsTabController` initializer. No settings are added or removed; persistence is untouched.

**Tech Stack:** Swift 6 (language mode 5), AppKit only (zero SwiftUI in the repo), programmatic Auto Layout with `NSStackView`, XCTest (target `CodaCoreTests`).

## Global Constraints

- **Platform floor:** macOS 13 (`Package.swift`). `NSSwitch` (10.15+) and `.sourceList` selection are within floor.
- **No new/removed settings.** Every existing setting keeps its exact behaviour and persistence. `Preferences` → `~/.coda/preferences.json` write-through via `AppDelegate` setters is unchanged.
- **Callback-injection pattern:** controllers are pure UI. They receive initial values + `onChange` closures; `AppDelegate` owns persistence and live application. Keep it.
- **`SettingsCategory` is pure-data** (no AppKit import) so it lives in `CodaCore` and is unit-tested. The enum→pane-VC mapping lives in the Coda UI layer.
- **Build (release toolchain / CommandLineTools):** `swift build`
- **Tests (needs full Xcode + separate build path):** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest`
- **Keyboard-shortcut notation in prose/commits:** space out symbols (e.g. `⌘ ,`), per repo convention.
- **Notification subtitle copy** (use verbatim):
  - Needs-you: `Alerts you when an agent is waiting for your input.`
  - Finishes: `Alerts you when an agent completes its turn.`
  - Dock badge: `Shows a count on the Dock icon for agents awaiting you.`

---

## File Structure

**New — `Sources/CodaCore/`:**
- `SettingsCategory.swift` — pure-data enum (case, title, SF Symbol). Source of truth for sidebar rows + order.

**New — `Sources/Coda/`:**
- `SettingsContext.swift` — struct bundling all values + `onChange` closures.
- `SettingsCard.swift` — `SettingsCard` (rounded grouped container) + `SettingsRow` (row builders) + internal `FlippedView`.
- `SettingsPane.swift` — `SettingsPane.makeScrollView(title:cards:)` scaffold.
- `GeneralPaneViewController.swift` — Default Editor, Interface Size, App Icon.
- `AppearancePaneViewController.swift` — Theme list, Accent Colour.
- `TerminalPaneViewController.swift` — Font & Size, Shell, Command Completions.
- `NotificationsPaneViewController.swift` — three notification toggles.
- `SettingsSidebarViewController.swift` — source-list table, reports selection.
- `SettingsSplitViewController.swift` — split-view wiring + pane swapping + enum→pane mapping extension.

**Modified — `Sources/Coda/`:**
- `AppDelegate.swift` — `openSettings()` builds `SettingsContext` + `SettingsSplitViewController`.
- `KeybindingsViewController.swift` — add a large title header to match the other panes.

**Deleted — `Sources/Coda/`:**
- `SettingsTabController.swift`
- `GeneralSettingsViewController.swift` (content split across the three new panes)
- `ThemeSettingsViewController.swift` (content folded into `AppearancePaneViewController`)

**New tests — `Tests/CodaCoreTests/`:**
- `SettingsCategoryTests.swift`

**Note on testability:** The only test target is `CodaCoreTests` (`Package.swift:24-28`); there is no test target for the `Coda` executable. So `SettingsCategory` (pure data, in `CodaCore`) is the piece with real unit tests. The AppKit view code (card kit, panes, sidebar, split, `SettingsContext`) is verified by `swift build` succeeding plus the visual/functional check in the final task — AppKit layout is not meaningfully unit-testable and there is no UI test target. This is a deliberate, documented deviation from the spec line "`SettingsContext` wiring gets unit tests."

---

### Task 1: SettingsCategory enum (CodaCore, TDD)

**Files:**
- Create: `Sources/CodaCore/SettingsCategory.swift`
- Test: `Tests/CodaCoreTests/SettingsCategoryTests.swift`

**Interfaces:**
- Produces: `enum SettingsCategory: String, CaseIterable { case general, appearance, terminal, notifications, shortcuts }` with `var title: String` and `var symbolName: String`. Sidebar order == `allCases` order.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/CodaCoreTests/SettingsCategoryTests.swift
import XCTest
@testable import CodaCore

final class SettingsCategoryTests: XCTestCase {
    func testOrderMatchesSidebarLayout() {
        XCTAssertEqual(SettingsCategory.allCases,
                       [.general, .appearance, .terminal, .notifications, .shortcuts])
    }

    func testCountIsFive() {
        XCTAssertEqual(SettingsCategory.allCases.count, 5)
    }

    func testTitles() {
        XCTAssertEqual(SettingsCategory.general.title, "General")
        XCTAssertEqual(SettingsCategory.appearance.title, "Appearance")
        XCTAssertEqual(SettingsCategory.terminal.title, "Terminal")
        XCTAssertEqual(SettingsCategory.notifications.title, "Notifications")
        XCTAssertEqual(SettingsCategory.shortcuts.title, "Shortcuts")
    }

    func testEverySymbolIsNonEmpty() {
        for category in SettingsCategory.allCases {
            XCTAssertFalse(category.symbolName.isEmpty, "\(category) has no SF Symbol")
        }
    }

    func testSpecificSymbols() {
        XCTAssertEqual(SettingsCategory.general.symbolName, "gearshape")
        XCTAssertEqual(SettingsCategory.appearance.symbolName, "paintpalette")
        XCTAssertEqual(SettingsCategory.terminal.symbolName, "terminal")
        XCTAssertEqual(SettingsCategory.notifications.symbolName, "bell")
        XCTAssertEqual(SettingsCategory.shortcuts.symbolName, "keyboard")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter SettingsCategoryTests`
Expected: FAIL — compile error, `cannot find 'SettingsCategory' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/CodaCore/SettingsCategory.swift
import Foundation

/// The categories shown in the Settings sidebar. Pure data (no AppKit) so it can be
/// unit-tested; the mapping to each category's AppKit pane view controller lives in the
/// Coda UI layer. Sidebar order == `allCases` order.
public enum SettingsCategory: String, CaseIterable, Sendable {
    case general
    case appearance
    case terminal
    case notifications
    case shortcuts

    /// The sidebar row label.
    public var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .terminal: return "Terminal"
        case .notifications: return "Notifications"
        case .shortcuts: return "Shortcuts"
        }
    }

    /// SF Symbol name for the sidebar row icon.
    public var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .terminal: return "terminal"
        case .notifications: return "bell"
        case .shortcuts: return "keyboard"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter SettingsCategoryTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CodaCore/SettingsCategory.swift Tests/CodaCoreTests/SettingsCategoryTests.swift
git commit -m "feat(core): SettingsCategory enum for the settings sidebar"
```

---

### Task 2: Card kit — SettingsCard + SettingsRow

**Files:**
- Create: `Sources/Coda/SettingsCard.swift`

**Interfaces:**
- Produces:
  - `final class SettingsCard: NSView` — `init(rows: [NSView])`. Stacks rows full-width with a hairline separator between each; rounded translucent fill.
  - `enum SettingsRow` with `static func make(title: String, subtitle: String?, control: NSView) -> NSView` and `static func padded(_ content: NSView, insets: NSEdgeInsets) -> NSView`.
  - `final class FlippedView: NSView` (internal) — top-left origin document view.

- [ ] **Step 1: Write the implementation**

```swift
// Sources/Coda/SettingsCard.swift
import AppKit

/// A top-left-origin view so a scroll view's document scrolls down from the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A rounded grouped container that stacks rows full-width with a hairline separator
/// between each — the macOS System Settings "grouped box". Fill/corner are tunable.
final class SettingsCard: NSView {
    init(rows: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        // Subtle translucent fill so the themed window background shows through.
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        var arranged: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 { arranged.append(Self.separator()) }
            arranged.append(row)
        }
        for view in arranged {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// A 1pt hairline the full width of the card.
    private static func separator() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }
}

/// Row builders for the content inside a SettingsCard.
enum SettingsRow {
    /// A standard row: leading title (+ optional grey subtitle), trailing control.
    static func make(title: String, subtitle: String? = nil, control: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)

        let textStack = NSStackView(views: [titleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        if let subtitle {
            let sub = NSTextField(wrappingLabelWithString: subtitle)
            sub.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            sub.textColor = .secondaryLabelColor
            sub.isSelectable = false
            textStack.addArrangedSubview(sub)
        }

        control.translatesAutoresizingMaskIntoConstraints = false
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [textStack, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        return row
    }

    /// Wrap arbitrary content (a gallery, a table, a swatch row) with card padding so it
    /// can be dropped into a SettingsCard as a single row.
    static func padded(_ content: NSView,
                       insets: NSEdgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)) -> NSView {
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -insets.right),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets.bottom),
        ])
        return container
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: `Build complete!` (the new types compile; nothing references them yet — that is fine).

- [ ] **Step 3: Commit**

```bash
git add Sources/Coda/SettingsCard.swift
git commit -m "feat(settings): reusable SettingsCard + SettingsRow card kit"
```

---

### Task 3: SettingsPane scaffold

**Files:**
- Create: `Sources/Coda/SettingsPane.swift`

**Interfaces:**
- Consumes: `FlippedView` (Task 2).
- Produces: `enum SettingsPane { static func makeScrollView(title: String, cards: [NSView]) -> NSScrollView }` — a themed, non-drawing-background vertical scroll view with a large bold title header above a stack of cards; cards fill the pane width.

- [ ] **Step 1: Write the implementation**

```swift
// Sources/Coda/SettingsPane.swift
import AppKit

/// Builds the standard scaffold for a settings detail pane: a vertical scroll view with a
/// large title header above a stack of cards. Cards stretch to the pane width; content
/// scrolls when it exceeds the pane height. Insets/spacing are tunable.
enum SettingsPane {
    static let horizontalInset: CGFloat = 24

    static func makeScrollView(title: String, cards: [NSView]) -> NSScrollView {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 22, weight: .bold)

        let stack = NSStackView(views: [header] + cards)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 24, left: horizontalInset, bottom: 24, right: horizontalInset)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = FlippedView()
        content.addSubview(stack)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.documentView = content
        content.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            // Pin the stack to the document view.
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            // Document view width tracks the clip view so cards fill the pane (no h-scroll).
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
        ])
        // Cards fill the width between the stack's horizontal insets.
        for card in cards {
            card.widthAnchor.constraint(equalTo: content.widthAnchor,
                                        constant: -2 * horizontalInset).isActive = true
        }
        return scroll
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/Coda/SettingsPane.swift
git commit -m "feat(settings): SettingsPane scroll-scaffold for detail panes"
```

---

### Task 4: SettingsContext bundle

**Files:**
- Create: `Sources/Coda/SettingsContext.swift`

**Interfaces:**
- Consumes: `Editor`, `Keybindings`, `UIScale`, `ShellChoice`, `TerminalTheme`, `TerminalFontPref` (all in `CodaCore`), `NSFont` (AppKit).
- Produces: `struct SettingsContext` with the fields + closures below. Every pane VC and the split controller take one `SettingsContext`.

- [ ] **Step 1: Write the implementation**

```swift
// Sources/Coda/SettingsContext.swift
import AppKit
import CodaCore

/// All values + change callbacks the Settings panes need, bundled so panes and the split
/// controller take a single parameter instead of 20+. AppDelegate builds one of these; each
/// pane reads only the fields it uses. This replaces SettingsTabController's giant init.
struct SettingsContext {
    // General
    let editor: Editor
    let onChangeEditor: (Editor) -> Void
    let uiScale: UIScale
    let onChangeUIScale: (UIScale) -> Void
    let appIconName: String?
    let onChangeAppIcon: (String) -> Void

    // Appearance
    let themeNames: [String]
    let activeThemeName: String?
    let onApplyTheme: (String) -> Void
    let onImportTheme: (URL) -> Void
    let accentValue: String            // serialized IdentityColorValue
    let accentTheme: TerminalTheme     // paints the hue swatches
    let onChangeAccentColor: (String) -> Void

    // Terminal
    let terminalFont: NSFont
    let onChangeFont: (TerminalFontPref) -> Void
    let shell: ShellChoice
    let onChangeShell: (ShellChoice) -> Void
    let completionsEnabled: Bool
    let onChangeCompletionsEnabled: (Bool) -> Void

    // Notifications
    let notifyOnNeedsYou: Bool
    let onChangeNotifyOnNeedsYou: (Bool) -> Void
    let notifyOnDone: Bool
    let onChangeNotifyOnDone: (Bool) -> Void
    let showDockBadge: Bool
    let onChangeShowDockBadge: (Bool) -> Void

    // Shortcuts
    let keybindings: Keybindings
    let onChangeKeybindings: (Keybindings) -> Void
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/Coda/SettingsContext.swift
git commit -m "feat(settings): SettingsContext bundle for pane wiring"
```

---

### Task 5: NotificationsPaneViewController

Done first among the panes because it is the clearest demonstration of the card kit (three toggle rows with subtitles).

**Files:**
- Create: `Sources/Coda/NotificationsPaneViewController.swift`

**Interfaces:**
- Consumes: `SettingsContext` (Task 4), `SettingsCard` / `SettingsRow` (Task 2), `SettingsPane` (Task 3).
- Produces: `final class NotificationsPaneViewController: NSViewController { init(context: SettingsContext) }`.

- [ ] **Step 1: Write the implementation**

```swift
// Sources/Coda/NotificationsPaneViewController.swift
import AppKit
import CodaCore

/// Settings → Notifications. Three independent opt-in toggles, each with a grey subtitle.
/// Edits report via the context's callbacks; AppDelegate persists.
final class NotificationsPaneViewController: NSViewController {
    private let context: SettingsContext
    private let needsYouSwitch = NSSwitch()
    private let doneSwitch = NSSwitch()
    private let dockBadgeSwitch = NSSwitch()

    init(context: SettingsContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        needsYouSwitch.state = context.notifyOnNeedsYou ? .on : .off
        needsYouSwitch.target = self
        needsYouSwitch.action = #selector(needsYouChanged)

        doneSwitch.state = context.notifyOnDone ? .on : .off
        doneSwitch.target = self
        doneSwitch.action = #selector(doneChanged)

        dockBadgeSwitch.state = context.showDockBadge ? .on : .off
        dockBadgeSwitch.target = self
        dockBadgeSwitch.action = #selector(dockBadgeChanged)

        let card = SettingsCard(rows: [
            SettingsRow.make(title: "Notify when an agent needs you",
                             subtitle: "Alerts you when an agent is waiting for your input.",
                             control: needsYouSwitch),
            SettingsRow.make(title: "Notify when an agent finishes",
                             subtitle: "Alerts you when an agent completes its turn.",
                             control: doneSwitch),
            SettingsRow.make(title: "Show a Dock badge when agents need you",
                             subtitle: "Shows a count on the Dock icon for agents awaiting you.",
                             control: dockBadgeSwitch),
        ])
        view = SettingsPane.makeScrollView(title: "Notifications", cards: [card])
    }

    @objc private func needsYouChanged() {
        context.onChangeNotifyOnNeedsYou(needsYouSwitch.state == .on)
    }
    @objc private func doneChanged() {
        context.onChangeNotifyOnDone(doneSwitch.state == .on)
    }
    @objc private func dockBadgeChanged() {
        context.onChangeShowDockBadge(dockBadgeSwitch.state == .on)
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/Coda/NotificationsPaneViewController.swift
git commit -m "feat(settings): Notifications pane with toggle rows"
```

---

### Task 6: TerminalPaneViewController

Moves the Terminal-font/size row, Shell popup, and Command-Completions control out of the old `GeneralSettingsViewController`. Font/shell handlers are reproduced from the current controller (behaviour unchanged); the completions checkbox becomes an `NSSwitch`.

**Files:**
- Create: `Sources/Coda/TerminalPaneViewController.swift`

**Interfaces:**
- Consumes: `SettingsContext`, card kit, `SettingsPane`, `TerminalFontPref`, `ShellChoice`.
- Produces: `final class TerminalPaneViewController: NSViewController { init(context: SettingsContext) }`.

- [ ] **Step 1: Write the implementation**

```swift
// Sources/Coda/TerminalPaneViewController.swift
import AppKit
import CodaCore

/// Settings → Terminal: font & size, shell, and command completions. Font/shell logic is
/// carried over verbatim from the former GeneralSettingsViewController; the completions
/// control is now an NSSwitch. Edits report via the context.
final class TerminalPaneViewController: NSViewController {
    private let context: SettingsContext
    private var terminalFont: NSFont
    private var shell: ShellChoice

    private let fontValueLabel = NSTextField(labelWithString: "")
    private let sizeStepper = NSStepper()
    private let sizeField = NSTextField()
    private let shellPopup = NSPopUpButton()
    private let completionsSwitch = NSSwitch()

    init(context: SettingsContext) {
        self.context = context
        self.terminalFont = context.terminalFont
        self.shell = context.shell
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    override func loadView() {
        // --- Font & size row ---
        updateFontLabel()
        let changeFontButton = NSButton(title: "Change…", target: self, action: #selector(chooseFont))

        sizeStepper.minValue = 8
        sizeStepper.maxValue = 48
        sizeStepper.increment = 1
        sizeStepper.valueWraps = false
        sizeStepper.integerValue = Int(terminalFont.pointSize.rounded())
        sizeStepper.target = self
        sizeStepper.action = #selector(sizeStepperChanged)
        sizeField.stringValue = "\(Int(terminalFont.pointSize.rounded()))"
        sizeField.alignment = .right
        sizeField.target = self
        sizeField.action = #selector(sizeFieldChanged)
        sizeField.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let fontControls = NSStackView(views: [
            fontValueLabel, changeFontButton,
            NSTextField(labelWithString: "Size:"), sizeField, sizeStepper,
        ])
        fontControls.orientation = .horizontal
        fontControls.spacing = 8
        let fontRow = SettingsRow.make(title: "Font",
                                       subtitle: "Powerline / Nerd-Font glyphs render only if the chosen font includes them.",
                                       control: fontControls)

        // --- Shell row ---
        for choice in ShellChoice.allCases { shellPopup.addItem(withTitle: choice.displayName) }
        shellPopup.selectItem(at: ShellChoice.allCases.firstIndex(of: shell) ?? 0)
        shellPopup.target = self
        shellPopup.action = #selector(shellChanged)
        let shellRow = SettingsRow.make(title: "Shell",
                                        subtitle: "Automatic uses your login shell. Applies to new terminals.",
                                        control: shellPopup)

        // --- Command completions row ---
        completionsSwitch.state = context.completionsEnabled ? .on : .off
        completionsSwitch.target = self
        completionsSwitch.action = #selector(completionsChanged)
        let completionsRow = SettingsRow.make(title: "Command Completions",
                                              subtitle: "Adds an opt-in zsh integration to Coda terminals. Applies to newly-opened terminals.",
                                              control: completionsSwitch)

        let card = SettingsCard(rows: [fontRow, shellRow, completionsRow])
        view = SettingsPane.makeScrollView(title: "Terminal", cards: [card])
    }

    // MARK: Font (carried over from GeneralSettingsViewController)

    private func updateFontLabel() {
        let name = terminalFont.displayName ?? terminalFont.fontName
        fontValueLabel.stringValue = "\(name) \(Int(terminalFont.pointSize))"
    }

    /// The system monospaced font is abstract; NSFontManager.convert cannot convert from it.
    /// Seed with a concrete equivalent (Menlo ships on every macOS).
    private func fontPanelBase() -> NSFont {
        guard terminalFont.fontName.hasPrefix(".") else { return terminalFont }
        return NSFont(name: "Menlo", size: terminalFont.pointSize) ?? terminalFont
    }

    @objc private func chooseFont() {
        view.window?.makeKeyAndOrderFront(nil)
        view.window?.makeFirstResponder(self)
        NSFontManager.shared.target = self
        NSFontManager.shared.action = #selector(changeFont(_:))
        NSFontManager.shared.setSelectedFont(fontPanelBase(), isMultiple: false)
        NSFontManager.shared.orderFrontFontPanel(self)
    }

    @objc func changeFont(_ sender: NSFontManager?) {
        guard let sender else { return }
        terminalFont = sender.convert(fontPanelBase())
        updateFontLabel()
        sizeStepper.integerValue = Int(terminalFont.pointSize.rounded())
        sizeField.stringValue = "\(Int(terminalFont.pointSize.rounded()))"
        context.onChangeFont(TerminalFontPref(name: terminalFont.fontName, size: Double(terminalFont.pointSize)))
    }

    private func commitSize(_ newSize: Int) {
        let clamped = max(8, min(48, newSize))
        sizeStepper.integerValue = clamped
        sizeField.stringValue = "\(clamped)"
        if let resized = NSFont(name: terminalFont.fontName, size: CGFloat(clamped)) {
            terminalFont = resized
        }
        updateFontLabel()
        context.onChangeFont(TerminalFontPref(name: terminalFont.fontName, size: Double(clamped)))
    }

    @objc private func sizeStepperChanged() { commitSize(sizeStepper.integerValue) }
    @objc private func sizeFieldChanged() {
        commitSize(Int(sizeField.stringValue) ?? Int(terminalFont.pointSize.rounded()))
    }

    // MARK: Shell / completions

    @objc private func shellChanged() {
        let idx = shellPopup.indexOfSelectedItem
        guard ShellChoice.allCases.indices.contains(idx) else { return }
        shell = ShellChoice.allCases[idx]
        context.onChangeShell(shell)
    }

    @objc private func completionsChanged() {
        context.onChangeCompletionsEnabled(completionsSwitch.state == .on)
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/Coda/TerminalPaneViewController.swift
git commit -m "feat(settings): Terminal pane (font, shell, completions)"
```

---

### Task 7: GeneralPaneViewController

Moves Default Editor, Interface Size, and the App-Icon gallery out of the old `GeneralSettingsViewController`. Editor-popup and app-icon logic are reproduced verbatim (behaviour unchanged).

**Files:**
- Create: `Sources/Coda/GeneralPaneViewController.swift`

**Interfaces:**
- Consumes: `SettingsContext`, card kit, `SettingsPane`, `Editor`, `UIScale`, `AppIconCatalog`.
- Produces: `final class GeneralPaneViewController: NSViewController { init(context: SettingsContext) }`.

- [ ] **Step 1: Write the implementation**

```swift
// Sources/Coda/GeneralPaneViewController.swift
import AppKit
import CodaCore

/// Settings → General: default editor, interface size, and the app-icon gallery. Editor and
/// app-icon logic are carried over from the former GeneralSettingsViewController.
final class GeneralPaneViewController: NSViewController {
    private let context: SettingsContext
    private var editor: Editor
    private var appIconName: String?

    private let editorPopup = NSPopUpButton()
    private let scalePopup = NSPopUpButton()
    private let appIconRow = NSStackView()
    private var appIconButtons: [NSButton] = []
    private let appIcons = AppIconCatalog.all()

    private static let otherTitle = "Other…"

    init(context: SettingsContext) {
        self.context = context
        self.editor = context.editor
        self.appIconName = context.appIconName
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        // --- Default editor ---
        editorPopup.target = self
        editorPopup.action = #selector(editorChanged)
        rebuildPopup()
        let editorRow = SettingsRow.make(title: "Default Editor",
                                         subtitle: "Used by “Open in…” and ⌘-click in the terminal.",
                                         control: editorPopup)

        // --- Interface size ---
        for scale in UIScale.allCases { scalePopup.addItem(withTitle: scale.displayName) }
        scalePopup.selectItem(at: UIScale.allCases.firstIndex(of: context.uiScale) ?? 1)
        scalePopup.target = self
        scalePopup.action = #selector(scaleChanged)
        let scaleRow = SettingsRow.make(title: "Interface Size",
                                        subtitle: "Scales the sidebar, tabs, and labels. Applies immediately.",
                                        control: scalePopup)

        let editorCard = SettingsCard(rows: [editorRow, scaleRow])

        // --- App icon gallery ---
        appIconRow.orientation = .horizontal
        appIconRow.spacing = 10
        appIconButtons = appIcons.enumerated().map { index, icon in
            let button = NSButton()
            button.title = ""
            button.isBordered = false
            button.image = Self.iconThumbnail(icon.image, side: 48)
            button.imageScaling = .scaleProportionallyUpOrDown
            button.toolTip = icon.displayName
            button.target = self
            button.action = #selector(appIconClicked(_:))
            button.tag = index
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            button.widthAnchor.constraint(equalToConstant: 56).isActive = true
            button.heightAnchor.constraint(equalToConstant: 56).isActive = true
            appIconRow.addArrangedSubview(button)
            return button
        }
        let appIconTitle = NSTextField(labelWithString: "App Icon")
        appIconTitle.font = .systemFont(ofSize: NSFont.systemFontSize)
        let appIconHint = NSTextField(labelWithString: "Changes the Dock icon. Applies immediately.")
        appIconHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        appIconHint.textColor = .secondaryLabelColor
        let appIconContent = NSStackView(views: [appIconTitle, appIconRow, appIconHint])
        appIconContent.orientation = .vertical
        appIconContent.alignment = .leading
        appIconContent.spacing = 8
        let appIconCard = SettingsCard(rows: [SettingsRow.padded(appIconContent)])

        view = SettingsPane.makeScrollView(title: "General", cards: [editorCard, appIconCard])
        updateAppIconSelection()
    }

    // MARK: Editor (carried over)

    private func rebuildPopup() {
        editorPopup.removeAllItems()
        for e in Editor.knownEditors { editorPopup.addItem(withTitle: e.name) }
        if !Editor.knownEditors.contains(where: { $0.bundleID == editor.bundleID }) {
            editorPopup.addItem(withTitle: editor.name)
        }
        editorPopup.menu?.addItem(.separator())
        editorPopup.addItem(withTitle: Self.otherTitle)
        selectCurrent()
    }

    private func selectCurrent() {
        if let i = Editor.knownEditors.firstIndex(where: { $0.bundleID == editor.bundleID }) {
            editorPopup.selectItem(at: i)
        } else {
            editorPopup.selectItem(withTitle: editor.name)
        }
    }

    @objc private func editorChanged() {
        let title = editorPopup.titleOfSelectedItem ?? ""
        if title == Self.otherTitle {
            pickOtherApp()
        } else if let chosen = Editor.knownEditors.first(where: { $0.name == title }) {
            editor = chosen
            context.onChangeEditor(chosen)
        }
    }

    private func pickOtherApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else {
            selectCurrent()
            return
        }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        let custom = Editor(name: name, bundleID: bundleID, urlScheme: "")
        editor = custom
        context.onChangeEditor(custom)
        rebuildPopup()
    }

    // MARK: Interface size

    @objc private func scaleChanged() {
        let idx = scalePopup.indexOfSelectedItem
        guard UIScale.allCases.indices.contains(idx) else { return }
        context.onChangeUIScale(UIScale.allCases[idx])
    }

    // MARK: App icon (carried over)

    @objc private func appIconClicked(_ sender: NSButton) {
        guard appIcons.indices.contains(sender.tag) else { return }
        appIconName = appIcons[sender.tag].id
        updateAppIconSelection()
        context.onChangeAppIcon(appIcons[sender.tag].id)
    }

    private func updateAppIconSelection() {
        let selectedID = appIconName ?? AppIconCatalog.defaultID
        for (index, button) in appIconButtons.enumerated() {
            let isSelected = appIcons[index].id == selectedID
            button.layer?.borderWidth = isSelected ? 2 : 0
            button.layer?.borderColor = isSelected ? NSColor.controlAccentColor.cgColor : nil
        }
    }

    private static func iconThumbnail(_ image: NSImage, side: CGFloat) -> NSImage {
        let copy = image.copy() as! NSImage
        copy.size = NSSize(width: side, height: side)
        return copy
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/Coda/GeneralPaneViewController.swift
git commit -m "feat(settings): General pane (editor, interface size, app icon)"
```

---

### Task 8: AppearancePaneViewController

Folds the theme list (from `ThemeSettingsViewController`) and the accent-colour swatches (from the old `GeneralSettingsViewController`) into one pane.

**Files:**
- Create: `Sources/Coda/AppearancePaneViewController.swift`

**Interfaces:**
- Consumes: `SettingsContext`, card kit, `SettingsPane`, `TerminalTheme`, `IdentityHue`, `IdentityColorValue`, `PinColorPanel`.
- Produces: `final class AppearancePaneViewController: NSViewController { init(context: SettingsContext) }`.

- [ ] **Step 1: Write the implementation**

```swift
// Sources/Coda/AppearancePaneViewController.swift
import AppKit
import CodaCore

/// Settings → Appearance: the installed-theme list (with Import/Apply) and the sidebar
/// accent-colour swatches. Theme logic is carried over from ThemeSettingsViewController;
/// accent logic from the former GeneralSettingsViewController.
final class AppearancePaneViewController: NSViewController {
    private let context: SettingsContext
    private var themeNames: [String]
    private var activeTheme: String?
    private var accentValue: String
    private let accentTheme: TerminalTheme

    private let tableView = NSTableView()
    private let accentSwatchRow = NSStackView()
    private var accentButtons: [NSButton] = []

    init(context: SettingsContext) {
        self.context = context
        self.themeNames = context.themeNames
        self.activeTheme = context.activeThemeName
        self.accentValue = context.accentValue
        self.accentTheme = context.accentTheme
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        // --- Theme card ---
        let column = NSTableColumn(identifier: .init("theme"))
        column.title = "Theme"
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(applySelectedTheme)
        tableView.target = self
        tableView.backgroundColor = .clear

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 200).isActive = true

        let applyButton = NSButton(title: "Apply", target: self, action: #selector(applySelectedTheme))
        let importButton = NSButton(title: "Import .itermcolors…", target: self, action: #selector(importTheme))
        let buttons = NSStackView(views: [importButton, NSView(), applyButton])
        buttons.orientation = .horizontal

        let themeContent = NSStackView(views: [scroll, buttons])
        themeContent.orientation = .vertical
        themeContent.alignment = .leading
        themeContent.spacing = 10
        // Let the scroll view stretch to the card width.
        scroll.widthAnchor.constraint(equalTo: themeContent.widthAnchor).isActive = true
        buttons.widthAnchor.constraint(equalTo: themeContent.widthAnchor).isActive = true
        let themeCard = SettingsCard(rows: [SettingsRow.padded(themeContent)])

        // --- Accent card ---
        accentSwatchRow.orientation = .horizontal
        accentSwatchRow.spacing = 8
        accentButtons = IdentityHue.allCases.enumerated().map { index, hue in
            let button = NSButton()
            button.title = ""
            button.isBordered = false
            button.image = Self.circleImage(accentTheme.color(for: hue).nsColor, diameter: 20)
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
        let customButton = NSButton(title: "Custom…", target: self, action: #selector(accentCustomClicked))
        customButton.bezelStyle = .rounded
        accentSwatchRow.addArrangedSubview(customButton)

        let accentTitle = NSTextField(labelWithString: "Accent Colour")
        accentTitle.font = .systemFont(ofSize: NSFont.systemFontSize)
        let accentHint = NSTextField(labelWithString: "Colour of the selected worktree/branch in the sidebar. Follows the theme.")
        accentHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        accentHint.textColor = .secondaryLabelColor
        let accentContent = NSStackView(views: [accentTitle, accentSwatchRow, accentHint])
        accentContent.orientation = .vertical
        accentContent.alignment = .leading
        accentContent.spacing = 8
        let accentCard = SettingsCard(rows: [SettingsRow.padded(accentContent)])

        view = SettingsPane.makeScrollView(title: "Appearance", cards: [themeCard, accentCard])
        selectActiveThemeRow()
        updateAccentSelection()
    }

    // MARK: Theme (carried over from ThemeSettingsViewController)

    private func selectActiveThemeRow() {
        if let activeTheme, let idx = themeNames.firstIndex(of: activeTheme) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
    }

    @objc private func applySelectedTheme() {
        let row = tableView.selectedRow
        guard row >= 0, row < themeNames.count else { return }
        activeTheme = themeNames[row]
        context.onApplyTheme(themeNames[row])
    }

    @objc private func importTheme() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["itermcolors"]
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        context.onImportTheme(url)
        let name = url.deletingPathExtension().lastPathComponent
        if !themeNames.contains(name) { themeNames.append(name); themeNames.sort() }
        tableView.reloadData()
        if let idx = themeNames.firstIndex(of: name) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
    }

    // MARK: Accent (carried over from GeneralSettingsViewController)

    @objc private func accentSwatchClicked(_ sender: NSButton) {
        let hues = IdentityHue.allCases
        guard hues.indices.contains(sender.tag) else { return }
        accentValue = IdentityColorValue.hue(hues[sender.tag]).serialized
        updateAccentSelection()
        context.onChangeAccentColor(accentValue)
    }

    @objc private func accentCustomClicked() {
        let current = IdentityColorValue.migrating(from: accentValue)?.resolved(accentTheme).nsColor
        PinColorPanel.shared.begin(initial: current) { [weak self] rgb in
            guard let self else { return }
            self.accentValue = IdentityColorValue.pinned(rgb).serialized
            self.updateAccentSelection()
            self.context.onChangeAccentColor(self.accentValue)
        }
    }

    private func updateAccentSelection() {
        let selectedHue: IdentityHue?
        if case .hue(let h) = IdentityColorValue.migrating(from: accentValue) { selectedHue = h }
        else { selectedHue = nil }
        for (index, button) in accentButtons.enumerated() {
            let isSelected = IdentityHue.allCases[index] == selectedHue
            button.layer?.borderWidth = isSelected ? 2 : 0
            button.layer?.borderColor = isSelected ? NSColor.labelColor.cgColor : nil
        }
    }

    private static func circleImage(_ color: NSColor, diameter: CGFloat) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }
}

extension AppearancePaneViewController: NSTableViewDataSource, NSTableViewDelegate {
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

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/Coda/AppearancePaneViewController.swift
git commit -m "feat(settings): Appearance pane (theme list + accent colour)"
```

---

### Task 9: SettingsSidebarViewController

**Files:**
- Create: `Sources/Coda/SettingsSidebarViewController.swift`

**Interfaces:**
- Consumes: `SettingsCategory` (Task 1).
- Produces: `final class SettingsSidebarViewController: NSViewController { var onSelect: ((SettingsCategory) -> Void)?; func selectFirst() }`.

- [ ] **Step 1: Write the implementation**

```swift
// Sources/Coda/SettingsSidebarViewController.swift
import AppKit
import CodaCore

/// The Settings source-list sidebar: one row per SettingsCategory (SF Symbol + label).
/// Reports the chosen category via onSelect.
final class SettingsSidebarViewController: NSViewController {
    private let categories = SettingsCategory.allCases
    private let tableView = NSTableView()
    var onSelect: ((SettingsCategory) -> Void)?

    override func loadView() {
        let column = NSTableColumn(identifier: .init("category"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.selectionHighlightStyle = .sourceList
        tableView.backgroundColor = .clear
        tableView.rowHeight = 30
        tableView.rowSizeStyle = .medium

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        view = scroll
    }

    /// Select the first category and notify. Call once after the view loads.
    func selectFirst() {
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        onSelect?(categories[0])
    }
}

extension SettingsSidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { categories.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let category = categories[row]
        let id = NSUserInterfaceItemIdentifier("categoryCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let c = NSTableCellView()
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(image); c.addSubview(tf)
            c.imageView = image; c.textField = tf
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                image.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 18),
                tf.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            c.identifier = id
            return c
        }()
        cell.imageView?.image = NSImage(systemSymbolName: category.symbolName,
                                        accessibilityDescription: category.title)
        cell.textField?.stringValue = category.title
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard categories.indices.contains(row) else { return }
        onSelect?(categories[row])
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/Coda/SettingsSidebarViewController.swift
git commit -m "feat(settings): source-list sidebar for the settings window"
```

---

### Task 10: SettingsSplitViewController + enum→pane mapping

**Files:**
- Create: `Sources/Coda/SettingsSplitViewController.swift`

**Interfaces:**
- Consumes: `SettingsSidebarViewController` (Task 9), `SettingsContext` (Task 4), the four pane VCs (Tasks 5–8), `KeybindingsViewController`.
- Produces: `final class SettingsSplitViewController: NSSplitViewController { init(context: SettingsContext) }` and `extension SettingsCategory { func makePane(context: SettingsContext) -> NSViewController }`.

- [ ] **Step 1: Write the implementation**

```swift
// Sources/Coda/SettingsSplitViewController.swift
import AppKit
import CodaCore

/// The Settings window content: a source-list sidebar on the left and a detail pane on the
/// right that swaps view controllers as the selection changes (macOS System Settings style).
final class SettingsSplitViewController: NSSplitViewController {
    private let context: SettingsContext
    private let sidebar = SettingsSidebarViewController()
    private let detailContainer = NSViewController()
    private var currentPane: NSViewController?

    init(context: SettingsContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        // A plain container that hosts the current pane as its only child.
        detailContainer.view = NSView()
        detailContainer.view.translatesAutoresizingMaskIntoConstraints = true
        super.loadView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 240
        sidebarItem.canCollapse = false
        addSplitViewItem(sidebarItem)

        let detailItem = NSSplitViewItem(viewController: detailContainer)
        detailItem.minimumThickness = 460
        addSplitViewItem(detailItem)

        sidebar.onSelect = { [weak self] category in self?.show(category) }
        sidebar.selectFirst()
    }

    private func show(_ category: SettingsCategory) {
        currentPane?.view.removeFromSuperview()
        currentPane?.removeFromParent()

        let pane = category.makePane(context: context)
        addChild(pane)
        pane.view.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.view.addSubview(pane.view)
        NSLayoutConstraint.activate([
            pane.view.topAnchor.constraint(equalTo: detailContainer.view.topAnchor),
            pane.view.leadingAnchor.constraint(equalTo: detailContainer.view.leadingAnchor),
            pane.view.trailingAnchor.constraint(equalTo: detailContainer.view.trailingAnchor),
            pane.view.bottomAnchor.constraint(equalTo: detailContainer.view.bottomAnchor),
        ])
        currentPane = pane
    }
}

/// The Coda-layer mapping from a (pure-data) SettingsCategory to its AppKit pane VC. Kept
/// out of CodaCore so the enum stays framework-free.
extension SettingsCategory {
    func makePane(context: SettingsContext) -> NSViewController {
        switch self {
        case .general:       return GeneralPaneViewController(context: context)
        case .appearance:    return AppearancePaneViewController(context: context)
        case .terminal:      return TerminalPaneViewController(context: context)
        case .notifications: return NotificationsPaneViewController(context: context)
        case .shortcuts:
            let vc = KeybindingsViewController(bindings: context.keybindings)
            vc.onChange = context.onChangeKeybindings
            return vc
        }
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/Coda/SettingsSplitViewController.swift
git commit -m "feat(settings): split-view controller + category-to-pane mapping"
```

---

### Task 11: Wire into AppDelegate, restyle Shortcuts header, delete old controllers

Swaps `openSettings()` to build the new split controller, adds a matching title header to the reused `KeybindingsViewController`, and deletes the three now-dead files. All in one task because Swift compiles the whole module: the deletions and the rewire must land together or the build breaks.

**Files:**
- Modify: `Sources/Coda/AppDelegate.swift:550-595` (`openSettings()`)
- Modify: `Sources/Coda/KeybindingsViewController.swift:28-74` (`loadView`)
- Delete: `Sources/Coda/SettingsTabController.swift`
- Delete: `Sources/Coda/GeneralSettingsViewController.swift`
- Delete: `Sources/Coda/ThemeSettingsViewController.swift`

**Interfaces:**
- Consumes: `SettingsContext` (Task 4), `SettingsSplitViewController` (Task 10). All existing `AppDelegate` setters (`setDefaultEditor`, `setUIScale`, `setAppIcon`, `setActiveTheme(named:)`, `setTerminalFont`, `setShell`, `setCompletionsEnabled`, `setAccentColor`, `setNotifyOnNeedsYou`, `setNotifyOnDone`, `setShowDockBadge`, `applyKeybindings`) are unchanged and are wired into the context closures.

- [ ] **Step 1: Add a title header to KeybindingsViewController**

In `Sources/Coda/KeybindingsViewController.swift`, in `loadView()`, insert a large title as the first arranged subview so the Shortcuts pane matches the others. Change the start of the category loop (currently `Sources/Coda/KeybindingsViewController.swift:34`) by inserting these three lines immediately **before** `for category in ShortcutCategory.allCases...`:

```swift
        let paneTitle = NSTextField(labelWithString: "Keyboard Shortcuts")
        paneTitle.font = .systemFont(ofSize: 22, weight: .bold)
        stack.addArrangedSubview(paneTitle)

```

(Leave everything else in `KeybindingsViewController` as-is: it already returns a scroll view as its `view`, which drops straight into the detail container.)

- [ ] **Step 2: Rewrite `openSettings()` in AppDelegate**

Replace the body of `openSettings()` (`Sources/Coda/AppDelegate.swift:550-595`) with:

```swift
    private func openSettings() {
        if settingsWC == nil {
            let context = SettingsContext(
                editor: preferences.defaultEditor,
                onChangeEditor: { [weak self] editor in self?.setDefaultEditor(editor) },
                uiScale: preferences.uiScale,
                onChangeUIScale: { [weak self] scale in self?.setUIScale(scale) },
                appIconName: preferences.appIconName,
                onChangeAppIcon: { [weak self] id in self?.setAppIcon(id) },
                themeNames: themeStore.themeNames(),
                activeThemeName: preferences.activeTheme ?? defaultThemeName,
                onApplyTheme: { [weak self] name in self?.setActiveTheme(named: name) },
                onImportTheme: { [weak self] url in _ = try? self?.themeStore.importTheme(from: url) },
                accentValue: preferences.accentColor ?? AccentColor.defaultValue.serialized,
                accentTheme: activeTheme,
                onChangeAccentColor: { [weak self] value in self?.setAccentColor(value) },
                terminalFont: resolvedTerminalFont(),
                onChangeFont: { [weak self] pref in self?.setTerminalFont(pref) },
                shell: preferences.shell,
                onChangeShell: { [weak self] choice in self?.setShell(choice) },
                completionsEnabled: preferences.completionsEnabled,
                onChangeCompletionsEnabled: { [weak self] on in self?.setCompletionsEnabled(on) },
                notifyOnNeedsYou: preferences.notifyOnNeedsYou,
                onChangeNotifyOnNeedsYou: { [weak self] on in self?.setNotifyOnNeedsYou(on) },
                notifyOnDone: preferences.notifyOnDone,
                onChangeNotifyOnDone: { [weak self] on in self?.setNotifyOnDone(on) },
                showDockBadge: preferences.showDockBadge,
                onChangeShowDockBadge: { [weak self] on in self?.setShowDockBadge(on) },
                keybindings: keybindings,
                onChangeKeybindings: { [weak self] bindings in self?.applyKeybindings(bindings) })

            let split = SettingsSplitViewController(context: context)
            let win = NSWindow(contentViewController: split)
            win.title = "Settings"
            win.styleMask = [.titled, .closable, .resizable]
            win.titlebarAppearsTransparent = true
            win.isReleasedWhenClosed = false
            win.setContentSize(NSSize(width: 760, height: 560))
            win.contentMinSize = NSSize(width: 720, height: 480)
            settingsWC = NSWindowController(window: win)
        }
        // Match the active theme each time it opens (the window is cached, so re-apply here).
        if let win = settingsWC?.window {
            applyWindowChrome(ChromeTheme(terminal: activeTheme), to: win)
        }
        settingsWC?.window?.center()
        settingsWC?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
```

- [ ] **Step 3: Delete the three dead controllers**

```bash
git rm Sources/Coda/SettingsTabController.swift \
       Sources/Coda/GeneralSettingsViewController.swift \
       Sources/Coda/ThemeSettingsViewController.swift
```

- [ ] **Step 4: Verify it builds**

Run: `swift build`
Expected: `Build complete!` with no reference to the deleted types. If the compiler reports `cannot find 'SettingsTabController' / 'GeneralSettingsViewController' / 'ThemeSettingsViewController'`, grep for stragglers: `grep -rn "SettingsTabController\|GeneralSettingsViewController\|ThemeSettingsViewController" Sources/` and remove them.

- [ ] **Step 5: Run the full test suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest`
Expected: PASS (existing suite + `SettingsCategoryTests`). Nothing behavioural changed, so no existing test should regress.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(settings): switch Settings window to sidebar split layout

Replace the toolbar-tab SettingsTabController with SettingsSplitViewController
(sidebar + grouped cards). Delete GeneralSettingsViewController and
ThemeSettingsViewController; their controls move into the General/Appearance/
Terminal/Notifications panes. Reuse KeybindingsViewController as the Shortcuts
pane with a matching title header. Persistence unchanged."
```

---

### Task 12: Visual + functional verification

No new code unless a defect is found. AppKit Auto Layout is fiddly; this task confirms the panes actually lay out and every setting still works, and tunes constraints if needed.

**Files:**
- Modify (only if a defect is found): the relevant pane / card-kit file.

- [ ] **Step 1: Launch the app and open Settings**

Run: `swift build && .build/debug/Coda` (or the repo's usual run path via the `run` skill). Open Settings with `⌘ ,`.

- [ ] **Step 2: Snapshot each pane**

Follow the repo's GUI-inspection technique (see the `debugging-terminal-rendering` memory): render each pane to a PNG in-app and inspect it. Click through all five sidebar rows (General, Appearance, Terminal, Notifications, Shortcuts) and confirm for each:
  - The sidebar shows five rows with the correct SF Symbols and the selected row highlights (`.sourceList` style).
  - The detail pane shows a large bold title and grouped rounded cards with hairline separators.
  - Rows are not clipped; long subtitles wrap; the pane scrolls when taller than the window.
  - Notifications rows show `NSSwitch` toggles with the three subtitles verbatim from Global Constraints.

- [ ] **Step 3: Exercise every setting end-to-end**

Confirm each still reads its saved value and writes through (spot-check `~/.coda/preferences.json` after toggling):
  - General: change Default Editor (and "Other…"), Interface Size (applies live), App Icon (Dock icon changes).
  - Appearance: apply a theme (chrome + terminals repaint), Import a `.itermcolors`, pick an accent hue and a Custom… pin (sidebar highlight changes).
  - Terminal: Change… font, size stepper/field, Shell popup, Command Completions toggle.
  - Notifications: toggle all three; verify banners/badge behaviour matches the toggles.
  - Shortcuts: record a chord, toggle enable, Restore Defaults.

- [ ] **Step 4: Confirm window chrome + entry points**

  - `⌘ ,` and the App menu → "Settings…" both open the window; it is resizable; reopening reuses the cached window and re-applies the active theme chrome.

- [ ] **Step 5: If any layout defect is found, fix and re-verify**

Tune the offending constraint in the card kit / pane, `swift build`, and repeat Steps 2–4. Commit fixes:

```bash
git add -A
git commit -m "fix(settings): tune <pane> layout after visual verification"
```

- [ ] **Step 6: Final full build + test**

Run: `swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest`
Expected: `Build complete!` and all tests PASS.

---

## Self-Review

**1. Spec coverage:**
- Sidebar + detail-pane structure → Tasks 9, 10. ✅
- Five categories (General/Appearance/Terminal/Notifications/Shortcuts) with the exact setting placement → Task 1 (enum) + Tasks 5–8, 11 (panes/mapping). ✅
- Reusable card kit (`SettingsCard`, `SettingsRow`, `SettingsPane`) → Tasks 2, 3. ✅
- Checkboxes → `NSSwitch`; notification subtitles → Tasks 5 (notifications), 6 (completions). ✅
- `SettingsContext` bundle replacing the 20+-param init → Task 4, wired in Task 11. ✅
- `SettingsCategory` pure-data in `CodaCore`, mapping in UI layer → Task 1 + Task 10 extension. ✅
- Resizable window, sidebar ~200pt, min size, preserved `⌘ ,` / menu / chrome re-apply → Task 11. ✅
- Delete `SettingsTabController` / `GeneralSettingsViewController` / `ThemeSettingsViewController`; reuse `KeybindingsViewController` → Task 11. ✅
- Persistence unchanged → no `Preferences`/store files touched; verified in Task 12 Step 3. ✅
- Verification: unit-test `SettingsCategory`, visual-verify the rest → Task 1 + Task 12. ✅ (Documented deviation: `SettingsContext` is not unit-tested because there is no `Coda` test target — see the "Note on testability" above.)

**2. Placeholder scan:** No TBD/TODO/"add error handling"/"similar to Task N". Carried-over handlers are reproduced in full. ✅

**3. Type consistency:** `SettingsContext` field/closure names are identical across Task 4 (definition), Tasks 5–8 (consumers), Task 10 (`makePane`), and Task 11 (construction) — note the callback is `onChangeKeybindings` everywhere (not the old `onChange`). `SettingsCategory` cases/`title`/`symbolName` match across Tasks 1, 9, 10. Card-kit signatures (`SettingsCard(rows:)`, `SettingsRow.make(title:subtitle:control:)`, `SettingsRow.padded(_:insets:)`, `SettingsPane.makeScrollView(title:cards:)`) match across all consumers. ✅
