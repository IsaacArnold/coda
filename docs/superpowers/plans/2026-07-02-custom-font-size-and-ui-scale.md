# Custom Terminal Font Size + Chrome UI Scale — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user set an arbitrary terminal font point size and a four-step interface (chrome) scale that applies live across the sidebar, tab bar, and worktree bar.

**Architecture:** A `UIScale` enum in `CodaCore` holds the four presets and their multipliers (pure, unit-tested). A `UIMetrics` value type in the app layer turns a `UIScale` into scaled AppKit fonts and lengths. Each chrome view gains `apply(metrics:)` and rebuilds; `AppDelegate` (which owns every chrome view) coordinates the live broadcast. The terminal size reuses the existing `TerminalFontPref.size` + `setTerminalFont` path, decoupled from the macOS font panel.

**Tech Stack:** Swift, AppKit, Swift Package Manager, XCTest. Two targets: `CodaCore` (pure, has tests) and `Coda` (AppKit app, no test target).

## Global Constraints

- `UIScale` multipliers are exactly: `small 0.9`, `medium 1.0`, `large 1.15`, `xlarge 1.3`.
- Default `UIScale` is `.medium` (= today's look). Older prefs files lacking the key MUST decode to `.medium`.
- `CodaCore` MUST NOT import AppKit — keep `UIScale` framework-free (use `Double`, not `CGFloat`).
- Preferences MUST NOT persist absolute paths (existing invariant, enforced by a test).
- Terminal size control range: integer 8–48, step 1. The font panel still chooses the typeface.
- Commit messages end with the Co-Authored-By trailer:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- Build with `swift build`; run tests with `swift test`.

## File Structure

- `Sources/CodaCore/Preferences.swift` — **modify**: add `UIScale` enum + `Preferences.uiScale`.
- `Tests/CodaCoreTests/PreferencesTests.swift` — **modify**: add `UIScale` + prefs tests.
- `Sources/Coda/UIMetrics.swift` — **create**: scale → fonts/lengths.
- `Sources/Coda/SidebarController.swift` — **modify**: metric-driven fonts + row heights + `apply(metrics:)`.
- `Sources/Coda/SurfaceTabBar.swift` — **modify**: metric-driven label/height + `apply(metrics:)`.
- `Sources/Coda/WorktreeBar.swift` — **modify**: metric-driven fonts/height + `apply(metrics:)`.
- `Sources/Coda/GeneralSettingsViewController.swift` — **modify**: terminal size stepper + interface-size popup.
- `Sources/Coda/SettingsTabController.swift` — **modify**: pass through `uiScale` + `onChangeUIScale`.
- `Sources/Coda/AppDelegate.swift` — **modify**: build/inject metrics, `setUIScale`, live broadcast, settings wiring.

---

### Task 1: `UIScale` model + preferences persistence

**Files:**
- Modify: `Sources/CodaCore/Preferences.swift`
- Test: `Tests/CodaCoreTests/PreferencesTests.swift`

**Interfaces:**
- Produces:
  - `enum UIScale: String, Codable, CaseIterable { case small, medium, large, xlarge }`
  - `UIScale.multiplier -> Double` (0.9 / 1.0 / 1.15 / 1.3)
  - `UIScale.displayName -> String` ("Small" / "Medium" / "Large" / "Extra Large")
  - `UIScale.scaled(_ base: Double) -> Double` == `(base * multiplier).rounded()`
  - `Preferences.uiScale: UIScale` (default `.medium`)

- [ ] **Step 1: Write the failing tests**

Add to `Tests/CodaCoreTests/PreferencesTests.swift` (new final class near the end of the file):

```swift
final class UIScaleTests: XCTestCase {
    func testMultipliersAreExact() {
        XCTAssertEqual(UIScale.small.multiplier, 0.9)
        XCTAssertEqual(UIScale.medium.multiplier, 1.0)
        XCTAssertEqual(UIScale.large.multiplier, 1.15)
        XCTAssertEqual(UIScale.xlarge.multiplier, 1.3)
    }

    func testScaledRoundsToNearestWholePoint() {
        // 24 * 1.15 = 27.6 → 28; medium is identity.
        XCTAssertEqual(UIScale.medium.scaled(24), 24)
        XCTAssertEqual(UIScale.large.scaled(24), 28)
        XCTAssertEqual(UIScale.small.scaled(13), 12) // 11.7 → 12
    }

    func testDisplayNamesAreHumanReadable() {
        XCTAssertEqual(UIScale.xlarge.displayName, "Extra Large")
        XCTAssertEqual(UIScale.medium.displayName, "Medium")
    }

    func testUIScaleDefaultsMediumForOldPrefs() {
        // Prefs written before the UI-scale control carried no uiScale key.
        let json = #"{"defaultEditor":{"name":"Visual Studio Code","bundleID":"com.microsoft.VSCode","urlScheme":"vscode"}}"#
        let prefs = try! JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        XCTAssertEqual(prefs.uiScale, .medium)
    }

    func testUIScaleRoundTrips() throws {
        var prefs = Preferences()
        prefs.uiScale = .large
        let back = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(back.uiScale, .large)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter UIScaleTests`
Expected: FAIL — compile error, `UIScale` is not defined.

- [ ] **Step 3: Add the `UIScale` enum**

In `Sources/CodaCore/Preferences.swift`, add after the `TerminalFontPref` struct (after line 35):

```swift
/// App-wide interface (chrome) size, as four presets. The multiplier scales chrome
/// fonts and geometry; `.medium` (1.0) is the app's default look. Pure/UI-free so the
/// scale math is testable in CodaCore — the AppKit `UIMetrics` type consumes it.
public enum UIScale: String, Codable, CaseIterable {
    case small, medium, large, xlarge

    public var multiplier: Double {
        switch self {
        case .small:  return 0.9
        case .medium: return 1.0
        case .large:  return 1.15
        case .xlarge: return 1.3
        }
    }

    public var displayName: String {
        switch self {
        case .small:  return "Small"
        case .medium: return "Medium"
        case .large:  return "Large"
        case .xlarge: return "Extra Large"
        }
    }

    /// Scale a base point/length to the nearest whole point.
    public func scaled(_ base: Double) -> Double { (base * multiplier).rounded() }
}
```

- [ ] **Step 4: Add `uiScale` to `Preferences`**

In the same file, modify the `Preferences` struct. Change the stored properties and initializer (lines 40–53) to:

```swift
    public var defaultEditor: Editor
    /// Name of the active terminal theme (a file in ~/.coda/themes/). nil → the
    /// app falls back to its default bundled theme. Synthesized Codable decodes a
    /// missing key to nil, so older prefs files still load.
    public var activeTheme: String?
    /// The terminal font. nil → the app's default monospaced font. Synthesized Codable
    /// decodes a missing key to nil, so older prefs files still load.
    public var terminalFont: TerminalFontPref?
    /// The interface (chrome) size. Defaults to `.medium`; older prefs files without
    /// the key decode to `.medium` via the custom decoder below.
    public var uiScale: UIScale
    public init(defaultEditor: Editor = .vsCode, activeTheme: String? = nil,
                terminalFont: TerminalFontPref? = nil, uiScale: UIScale = .medium) {
        self.defaultEditor = defaultEditor
        self.activeTheme = activeTheme
        self.terminalFont = terminalFont
        self.uiScale = uiScale
    }

    // Synthesized Codable would make `uiScale` a required key and fail to decode older
    // prefs files. A custom decoder defaults the missing key to `.medium` (and keeps the
    // other keys' existing optional/required behavior).
    private enum CodingKeys: String, CodingKey {
        case defaultEditor, activeTheme, terminalFont, uiScale
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.defaultEditor = try c.decode(Editor.self, forKey: .defaultEditor)
        self.activeTheme = try c.decodeIfPresent(String.self, forKey: .activeTheme)
        self.terminalFont = try c.decodeIfPresent(TerminalFontPref.self, forKey: .terminalFont)
        self.uiScale = try c.decodeIfPresent(UIScale.self, forKey: .uiScale) ?? .medium
    }
```

Note: `Preferences` already conforms to `Codable, Equatable`. Adding an explicit `init(from:)` keeps decoding; `Encodable` stays synthesized from the stored properties, and `Equatable` stays synthesized.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter UIScaleTests`
Expected: PASS (5 tests).

- [ ] **Step 6: Run the full CodaCore prefs suite to catch regressions**

Run: `swift test --filter PreferencesTests`
Expected: PASS — existing round-trip / old-prefs / no-absolute-paths tests still green.

- [ ] **Step 7: Commit**

```bash
git add Sources/CodaCore/Preferences.swift Tests/CodaCoreTests/PreferencesTests.swift
git commit -m "feat(core): add UIScale presets and persist Preferences.uiScale

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `UIMetrics` — scale → AppKit fonts and lengths

**Files:**
- Create: `Sources/Coda/UIMetrics.swift`

**Interfaces:**
- Consumes: `UIScale` (Task 1).
- Produces:
  - `struct UIMetrics { init(scale: UIScale) }`
  - `func length(_ base: CGFloat) -> CGFloat`
  - `var sectionHeader: NSFont` (smallSystemFontSize, semibold)
  - `var body: NSFont` (systemFontSize)
  - `var footnote: NSFont` (footnote text-style point size)
  - `func tabLabel(active: Bool) -> NSFont` (base 11; semibold if active else regular)
  - `var worktreeTitle: NSFont` (base 12, semibold)
  - `var worktreeBranch: NSFont` (base 11, monospaced)

> There is no `Coda` (app) test target, so `UIMetrics` is verified by `swift build` + manual checks; the pure scale math it relies on is already unit-tested in Task 1 (`UIScale.scaled`).

- [ ] **Step 1: Create the file**

Create `Sources/Coda/UIMetrics.swift`:

```swift
import AppKit
import CodaCore

/// Turns a `UIScale` preset into scaled AppKit fonts and geometry lengths for the app
/// chrome (sidebar, tab bar, worktree bar). One value; chrome views hold a copy and read
/// from it when they (re)build. The terminal font is NOT routed through here — it keeps
/// its own explicit point size from `TerminalFontPref`.
struct UIMetrics {
    let scale: UIScale

    init(scale: UIScale) { self.scale = scale }

    /// Scale a base geometry length (row/bar height, inset) to the nearest whole point.
    func length(_ base: CGFloat) -> CGFloat { CGFloat(scale.scaled(Double(base))) }

    private func size(_ base: CGFloat) -> CGFloat { CGFloat(scale.scaled(Double(base))) }

    /// Sidebar repo section header.
    var sectionHeader: NSFont { .systemFont(ofSize: size(NSFont.smallSystemFontSize), weight: .semibold) }

    /// Sidebar worktree title / settings body labels.
    var body: NSFont { .systemFont(ofSize: size(NSFont.systemFontSize)) }

    /// Sidebar worktree subtitle (branch).
    var footnote: NSFont {
        .systemFont(ofSize: size(NSFont.preferredFont(forTextStyle: .footnote).pointSize))
    }

    /// Surface tab label; the active tab is semibold.
    func tabLabel(active: Bool) -> NSFont { .systemFont(ofSize: size(11), weight: active ? .semibold : .regular) }

    /// Worktree identity-bar title.
    var worktreeTitle: NSFont { .systemFont(ofSize: size(12), weight: .semibold) }

    /// Worktree identity-bar branch (monospaced).
    var worktreeBranch: NSFont { .monospacedSystemFont(ofSize: size(11), weight: .regular) }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: `Build complete!` with no new errors (a pre-existing `allowedFileTypes` deprecation warning in `ThemeSettingsViewController.swift` is unrelated and expected).

- [ ] **Step 3: Commit**

```bash
git add Sources/Coda/UIMetrics.swift
git commit -m "feat(app): add UIMetrics to derive scaled chrome fonts and lengths

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Sidebar honors metrics + live `apply`

**Files:**
- Modify: `Sources/Coda/SidebarController.swift`

**Interfaces:**
- Consumes: `UIMetrics` (Task 2).
- Produces: `SidebarController.apply(metrics:)`; internal `metrics` defaults to `UIMetrics(scale: .medium)`.

- [ ] **Step 1: Add a stored metrics property**

In `SidebarController` add near the other stored properties (after line 80, `private var chrome: ChromeTheme?`):

```swift
    private var metrics = UIMetrics(scale: .medium)
```

- [ ] **Step 2: Route the repo header font through metrics**

In `outlineView(_:viewFor:item:)`, replace the repo header font line (currently line 327):

```swift
            cell.textField?.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
```

with:

```swift
            cell.textField?.font = metrics.sectionHeader
```

- [ ] **Step 3: Set worktree cell fonts in `viewFor` (so reused cells refresh)**

Worktree cell fonts are set once in `makeWorktreeCell()` and the cell is reused, so `reloadData()` alone won't restyle them. In the `if let wt = item as? WorktreeNode { ... }` branch of `outlineView(_:viewFor:item:)`, after `cell.subtitleLabel.stringValue = wt.worktree.branch`, add:

```swift
            cell.textField?.font = metrics.body
            cell.subtitleLabel.font = metrics.footnote
```

- [ ] **Step 4: Scale the row heights**

Replace `outlineView(_:heightOfRowByItem:)` (lines 318–320) body:

```swift
        item is WorktreeNode ? 38 : 24
```

with:

```swift
        item is WorktreeNode ? metrics.length(38) : metrics.length(24)
```

- [ ] **Step 5: Add `apply(metrics:)`**

Add a method to `SidebarController` (e.g. after `setIdentityOverride`):

```swift
    /// Adopt a new interface scale and restyle live. Row heights and cell fonts are
    /// recomputed on `reloadData()`; `noteHeightOfRows` forces the outline to re-measure.
    func apply(metrics: UIMetrics) {
        self.metrics = metrics
        outline.reloadData()
        let all = IndexSet(integersIn: 0..<outline.numberOfRows)
        outline.noteHeightOfRows(withIndexesChanged: all)
    }
```

- [ ] **Step 6: Verify it builds**

Run: `swift build`
Expected: `Build complete!` (only the unrelated deprecation warning).

- [ ] **Step 7: Commit**

```bash
git add Sources/Coda/SidebarController.swift
git commit -m "feat(sidebar): drive fonts and row heights from UIMetrics

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Surface tab bar honors metrics + live `apply`

**Files:**
- Modify: `Sources/Coda/SurfaceTabBar.swift`

**Interfaces:**
- Consumes: `UIMetrics` (Task 2).
- Produces: `SurfaceTabBar.apply(metrics:)`. `SurfaceTabBar.height` stays a `static let` used by `AppDelegate` layout only for the *default* spacing; the live height is driven by a stored constraint.

- [ ] **Step 1: Store metrics + the height constraint**

In `SurfaceTabBar`, add stored properties near `private let stack = NSStackView()` (after line 27):

```swift
    private var metrics = UIMetrics(scale: .medium)
    private var heightConstraint: NSLayoutConstraint!
```

- [ ] **Step 2: Capture the height constraint at init**

In `init(frame:)`, replace the height line (currently line 32):

```swift
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
```

with:

```swift
        heightConstraint = heightAnchor.constraint(equalToConstant: Self.height)
        heightConstraint.isActive = true
```

- [ ] **Step 3: Scale the tab label font**

In `makeTab(_:)`, replace the label font line (currently line 80):

```swift
        label.font = .systemFont(ofSize: 11, weight: item.isActive ? .semibold : .regular)
```

with:

```swift
        label.font = metrics.tabLabel(active: item.isActive)
```

- [ ] **Step 4: Scale the inner tab height**

In `makeTab(_:)`, replace the fixed tab height constraint (currently line 110):

```swift
            tab.heightAnchor.constraint(equalToConstant: 22),
```

with:

```swift
            tab.heightAnchor.constraint(equalToConstant: metrics.length(22)),
```

- [ ] **Step 5: Add `apply(metrics:)`**

Add to `SurfaceTabBar`:

```swift
    /// Adopt a new interface scale. Updates the bar's own height; the caller must re-run
    /// `update(items:)` so the tabs rebuild at the new metrics (AppDelegate does this via
    /// its tab-refresh path).
    func apply(metrics: UIMetrics) {
        self.metrics = metrics
        heightConstraint.constant = metrics.length(Self.height)
    }
```

- [ ] **Step 6: Verify it builds**

Run: `swift build`
Expected: `Build complete!` (only the unrelated deprecation warning).

- [ ] **Step 7: Commit**

```bash
git add Sources/Coda/SurfaceTabBar.swift
git commit -m "feat(tabbar): drive label font and heights from UIMetrics

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Worktree identity bar honors metrics + live `apply`

**Files:**
- Modify: `Sources/Coda/WorktreeBar.swift`

**Interfaces:**
- Consumes: `UIMetrics` (Task 2).
- Produces: `WorktreeBar.apply(metrics:)`.

> Scope note: only the two label fonts and the bar height scale here. The fixed 10pt
> horizontal insets stay constant — they don't clip text vertically, and keeping them
> fixed avoids storing the inner stack view just to mutate insets.

- [ ] **Step 1: Store metrics + the height constraint**

In `WorktreeBar`, add stored properties near the other lets (after line 12, `static let height: CGFloat = 26`):

```swift
    private var metrics = UIMetrics(scale: .medium)
    private var heightConstraint: NSLayoutConstraint!
```

- [ ] **Step 2: Capture the height constraint at init**

In `init(frame:)`, replace the height line (currently line 19):

```swift
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
```

with:

```swift
        heightConstraint = heightAnchor.constraint(equalToConstant: Self.height)
        heightConstraint.isActive = true
```

- [ ] **Step 3: Set the label fonts from metrics at init**

In `init(frame:)`, replace the two font lines (currently lines 21–22):

```swift
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        branchLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
```

with:

```swift
        titleLabel.font = metrics.worktreeTitle
        branchLabel.font = metrics.worktreeBranch
```

- [ ] **Step 4: Add `apply(metrics:)`**

Add to `WorktreeBar` (after `update(...)`):

```swift
    /// Adopt a new interface scale: restyle the labels and resize the bar. The next
    /// `update(...)` (or the current text) re-lays out inside the new height.
    func apply(metrics: UIMetrics) {
        self.metrics = metrics
        titleLabel.font = metrics.worktreeTitle
        branchLabel.font = metrics.worktreeBranch
        heightConstraint.constant = metrics.length(Self.height)
    }
```

- [ ] **Step 5: Verify it builds**

Run: `swift build`
Expected: `Build complete!` (only the unrelated deprecation warning).

- [ ] **Step 6: Commit**

```bash
git add Sources/Coda/WorktreeBar.swift
git commit -m "feat(worktreebar): drive fonts and height from UIMetrics

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Settings UI — terminal size stepper + interface-size popup

**Files:**
- Modify: `Sources/Coda/GeneralSettingsViewController.swift`
- Modify: `Sources/Coda/SettingsTabController.swift`

**Interfaces:**
- Consumes: `UIScale` (Task 1), existing `TerminalFontPref` + `onChangeFont`.
- Produces:
  - `GeneralSettingsViewController.init(editor:terminalFont:uiScale:)`
  - `GeneralSettingsViewController.onChangeUIScale: ((UIScale) -> Void)?`
  - `SettingsTabController.init(... uiScale: UIScale, onChangeUIScale: @escaping (UIScale) -> Void)` appended to the existing parameter list.

- [ ] **Step 1: Add stored state + the new callback to `GeneralSettingsViewController`**

In `GeneralSettingsViewController`, add after `private var terminalFont: NSFont` (line 14):

```swift
    private var uiScale: UIScale
    private let sizeStepper = NSStepper()
    private let sizeField = NSTextField()
    private let scalePopup = NSPopUpButton()
```

Add after `var onChangeFont: ((TerminalFontPref) -> Void)?` (line 17):

```swift
    var onChangeUIScale: ((UIScale) -> Void)?
```

- [ ] **Step 2: Accept `uiScale` in the initializer**

Replace the initializer (lines 21–25):

```swift
    init(editor: Editor, terminalFont: NSFont) {
        self.editor = editor
        self.terminalFont = terminalFont
        super.init(nibName: nil, bundle: nil)
    }
```

with:

```swift
    init(editor: Editor, terminalFont: NSFont, uiScale: UIScale) {
        self.editor = editor
        self.terminalFont = terminalFont
        self.uiScale = uiScale
        super.init(nibName: nil, bundle: nil)
    }
```

- [ ] **Step 3: Build the terminal-size + interface-size rows**

In `loadView()`, replace the font block (currently lines 45–54, from `let fontTitle` through the `fontHint.textColor` line) with:

```swift
        let fontTitle = NSTextField(labelWithString: "Terminal font")
        fontTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        updateFontLabel()
        let changeFontButton = NSButton(title: "Change…", target: self, action: #selector(chooseFont))

        // Terminal size, decoupled from the font panel's preset list (which jumps 14→18).
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

        let fontRow = NSStackView(views: [
            NSTextField(labelWithString: "Font:"), fontValueLabel, changeFontButton,
            NSTextField(labelWithString: "Size:"), sizeField, sizeStepper,
        ])
        fontRow.orientation = .horizontal
        fontRow.spacing = 8
        let fontHint = NSTextField(labelWithString: "Powerline / Nerd-Font glyphs render only if the chosen font includes them.")
        fontHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        fontHint.textColor = .secondaryLabelColor

        // Interface (chrome) size — four presets, applied live.
        let scaleTitle = NSTextField(labelWithString: "Interface size")
        scaleTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        for scale in UIScale.allCases { scalePopup.addItem(withTitle: scale.displayName) }
        scalePopup.selectItem(at: UIScale.allCases.firstIndex(of: uiScale) ?? 1)
        scalePopup.target = self
        scalePopup.action = #selector(scaleChanged)
        let scaleRow = NSStackView(views: [NSTextField(labelWithString: "Size:"), scalePopup])
        scaleRow.orientation = .horizontal
        scaleRow.spacing = 8
        let scaleHint = NSTextField(labelWithString: "Scales the sidebar, tabs, and labels. Applies immediately.")
        scaleHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        scaleHint.textColor = .secondaryLabelColor
```

- [ ] **Step 4: Add the new rows to the outer stack**

In `loadView()`, replace the stack construction line (currently line 56):

```swift
        let stack = NSStackView(views: [title, row, hint, fontTitle, fontRow, fontHint])
```

with:

```swift
        let stack = NSStackView(views: [
            title, row, hint,
            fontTitle, fontRow, fontHint,
            scaleTitle, scaleRow, scaleHint,
        ])
```

- [ ] **Step 5: Add the action handlers**

Add to `GeneralSettingsViewController` (near `changeFont`):

```swift
    /// Emit the current font with a new size. Keeps the typeface; only the size changes.
    private func commitSize(_ newSize: Int) {
        let clamped = max(8, min(48, newSize))
        sizeStepper.integerValue = clamped
        sizeField.stringValue = "\(clamped)"
        if let resized = NSFont(name: terminalFont.fontName, size: CGFloat(clamped)) {
            terminalFont = resized
        }
        updateFontLabel()
        onChangeFont?(TerminalFontPref(name: terminalFont.fontName, size: Double(clamped)))
    }

    @objc private func sizeStepperChanged() { commitSize(sizeStepper.integerValue) }

    @objc private func sizeFieldChanged() {
        commitSize(Int(sizeField.stringValue) ?? Int(terminalFont.pointSize.rounded()))
    }

    @objc private func scaleChanged() {
        let idx = scalePopup.indexOfSelectedItem
        guard UIScale.allCases.indices.contains(idx) else { return }
        uiScale = UIScale.allCases[idx]
        onChangeUIScale?(uiScale)
    }
```

- [ ] **Step 6: Keep the size controls in sync when the font panel changes the font**

In `changeFont(_:)`, after the existing `updateFontLabel()` call (line 143), add:

```swift
        sizeStepper.integerValue = Int(terminalFont.pointSize.rounded())
        sizeField.stringValue = "\(Int(terminalFont.pointSize.rounded()))"
```

- [ ] **Step 7: Thread `uiScale` + callback through `SettingsTabController`**

In `SettingsTabController.init`, append two parameters to the signature (after `onChangeFont` on line 16):

```swift
         onChangeFont: @escaping (TerminalFontPref) -> Void,
         uiScale: UIScale,
         onChangeUIScale: @escaping (UIScale) -> Void) {
```

Then update the `GeneralSettingsViewController` construction (lines 20–22):

```swift
        let general = GeneralSettingsViewController(editor: editor, terminalFont: terminalFont, uiScale: uiScale)
        general.onChangeEditor = onChangeEditor
        general.onChangeFont = onChangeFont
        general.onChangeUIScale = onChangeUIScale
```

- [ ] **Step 8: Verify it builds**

Run: `swift build`
Expected: FAIL — `AppDelegate.swift`'s call to `SettingsTabController(...)` is missing the two new arguments. This is fixed in Task 7. (If you want a green build at this boundary, do Task 7 before building.)

- [ ] **Step 9: Commit**

```bash
git add Sources/Coda/GeneralSettingsViewController.swift Sources/Coda/SettingsTabController.swift
git commit -m "feat(settings): add terminal size stepper and interface-size popup

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: AppDelegate — inject metrics, live broadcast, settings wiring

**Files:**
- Modify: `Sources/Coda/AppDelegate.swift`

**Interfaces:**
- Consumes: `UIMetrics` (Task 2), `SidebarController.apply` (Task 3), `SurfaceTabBar.apply` (Task 4), `WorktreeBar.apply` (Task 5), `SettingsTabController.init(... uiScale:onChangeUIScale:)` (Task 6), existing `refreshTabBar()` (defined near line 540) and `setTerminalFont`.
- Produces: `AppDelegate.setUIScale(_:)`, `AppDelegate.applyUIMetrics()`.

- [ ] **Step 1: Add the metrics helpers**

Add to `AppDelegate` near `setTerminalFont` (around line 790):

```swift
    /// Current chrome metrics from the saved interface-size preference.
    private var uiMetrics: UIMetrics { UIMetrics(scale: preferences.uiScale) }

    /// Push the current metrics to every chrome view and relayout live.
    private func applyUIMetrics() {
        let m = uiMetrics
        sidebar.apply(metrics: m)
        worktreeBar.apply(metrics: m)
        surfaceTabBar.apply(metrics: m)
        refreshTabBar()   // rebuild tab views at the new metrics
    }

    /// Persist a new interface scale and re-apply it live (no relaunch).
    private func setUIScale(_ scale: UIScale) {
        preferences.uiScale = scale
        do { try prefsStore.save(preferences) } catch { presentError(error) }
        applyUIMetrics()
    }
```

- [ ] **Step 2: Apply metrics at launch**

In `applicationDidFinishLaunching`, after `applyChromeTheme()` (line 59), add:

```swift
        applyUIMetrics()
```

- [ ] **Step 3: Pass `uiScale` + callback into the Settings window**

In `openSettings()`, update the `SettingsTabController(...)` call — replace the `onChangeFont` argument line (line 288):

```swift
                onChangeFont: { [weak self] pref in self?.setTerminalFont(pref) })
```

with:

```swift
                onChangeFont: { [weak self] pref in self?.setTerminalFont(pref) },
                uiScale: preferences.uiScale,
                onChangeUIScale: { [weak self] scale in self?.setUIScale(scale) })
```

- [ ] **Step 4: Verify the whole thing builds**

Run: `swift build`
Expected: `Build complete!` (only the unrelated `allowedFileTypes` deprecation warning).

- [ ] **Step 5: Run the full test suite**

Run: `swift test`
Expected: PASS — all existing CodaCore tests plus the new `UIScaleTests` are green.

- [ ] **Step 6: Commit**

```bash
git add Sources/Coda/AppDelegate.swift
git commit -m "feat(app): inject UIMetrics, broadcast interface-size changes live

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Manual end-to-end verification

**Files:** none (verification only).

- [ ] **Step 1: Launch the app**

Run: `swift run Coda` (or the project's usual launch). Use the `run` skill if available.

- [ ] **Step 2: Terminal size**

Open Settings (⌘,) → General. Set **Terminal → Size** to `15` via the stepper and via typing. Expected: the terminal panes re-render at 15pt immediately; the font label reads "`<name> 15`".

- [ ] **Step 3: Interface size across all presets**

Change **Interface size** through Small → Medium → Large → Extra Large. Expected each time, live and without relaunch:
- Sidebar repo headers, worktree titles, and branch subtitles scale; row heights grow/shrink so text is not clipped.
- Surface tab labels and tab bar height scale; the worktree identity bar text and height scale.

- [ ] **Step 4: Persistence**

Quit and relaunch. Expected: both the terminal size (15) and the chosen interface size persist. Inspect `~/.coda/preferences.json` — it contains `"uiScale"` and the `terminalFont.size` of 15.

- [ ] **Step 5: Backward compatibility**

Confirm a `preferences.json` without a `uiScale` key still loads (covered by `testUIScaleDefaultsMediumForOldPrefs`; spot-check by removing the key from a copy and relaunching if desired). Expected: app opens at Medium, no crash.

---

## Self-Review

**Spec coverage:**
- Data model (`UIScale` + `Preferences.uiScale`, old-prefs default) → Task 1. ✓
- `UIMetrics` provider (fonts + `length`) → Task 2. ✓
- Sidebar / tab bar / worktree bar consumers with live rebuild → Tasks 3, 4, 5. ✓
- Settings UI (terminal size control + interface-size popup) + `SettingsTabController` plumbing → Task 6. ✓
- Live-apply flow in `AppDelegate` (`setUIScale`, launch injection, settings callback) → Task 7. ✓
- Testing: unit (Task 1 `UIScaleTests`), manual (Task 8). ✓
- Non-goals (no slider, no per-view override, no chrome family picker) respected. ✓

**Placeholder scan:** No TBD/TODO; every code step shows the actual code and exact commands.

**Type consistency:** `apply(metrics:)` used identically across Tasks 3–5 and 7. `UIScale.scaled`/`multiplier`/`displayName` defined in Task 1 and consumed in Tasks 2 & 6. `onChangeUIScale: ((UIScale) -> Void)?` defined in Task 6 and supplied in Task 7. `GeneralSettingsViewController.init(editor:terminalFont:uiScale:)` and `SettingsTabController.init(...)` signatures match between Tasks 6 and 7.

**Known build boundary:** Task 6 intentionally leaves the tree non-building (AppDelegate call site not yet updated); Task 7 closes it. Called out in Task 6 Step 8.
