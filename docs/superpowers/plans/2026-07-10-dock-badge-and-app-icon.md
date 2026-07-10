# Dock Badge + Selectable App Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Dock badge showing how many worktrees need the user's input, and a Settings gallery for choosing the app icon (running Dock icon + Finder icon) from a curated bundled set.

**Architecture:** Both features plug into existing `AppDelegate` chokepoints. The badge count is a pure CodaCore function called from `recomputeRollupsAndRefreshUI()` (the single point every agent-state change already flows through). The icon feature ships `.icns` files under `Resources/Icons/`, enumerated by a new `AppIconCatalog` helper, applied via `NSApp.applicationIconImage` (Dock) and `NSWorkspace.setIcon` (Finder). Both add optional-decoding `Preferences` fields and a callback into `GeneralSettingsViewController`, exactly mirroring the existing `accentColor` / notify-toggle wiring.

**Tech Stack:** Swift 6 (language mode 5), AppKit, SwiftPM, XCTest. macOS 13+.

## Global Constraints

- Swift tools version 6.0; `swiftLanguageModes: [.v5]`. Platform floor macOS 13.
- `Preferences` uses a **custom `init(from:)`** so every new field MUST be added to `CodingKeys`, the memberwise `init`, and the custom decoder with a default via `decodeIfPresent(...) ?? default` — never rely on synthesized Codable (it would make the key required and break older prefs files).
- Preferences must persist **no absolute paths** (enforced by `PreferencesTests.testPreferencesHoldsNoAbsolutePaths`). The icon pref stores a filename stem (`id`), never a path.
- `Sources/Coda/Resources/Coda.icns` MUST NOT be moved or renamed — `Bundle.codaAssets` (`ResourceBundle.swift`) probes for it to detect the `.app` layout.
- Every settings change is persisted via `do { try prefsStore.save(preferences) } catch { presentError(error) }` — copy this pattern verbatim.
- Running Swift tests requires full Xcode: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest`.
- Commit messages end with the `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` trailer.

---

## File Structure

- `Sources/CodaCore/AgentState.swift` — add `needsYouCount(_:)` pure function (Task 1).
- `Sources/CodaCore/Preferences.swift` — add `showDockBadge` + `appIconName` fields (Tasks 2, 4).
- `Sources/Coda/AppIconCatalog.swift` — **new**: enumerate/resolve bundled icons (Task 5).
- `Sources/Coda/Resources/Icons/Alternate.icns` — **new**: seeded curated icon (Task 5).
- `Sources/Coda/AppDelegate.swift` — `updateDockBadge`, `setShowDockBadge`, `applyAppIcon` (replacing `applyDockIcon`), `setAppIcon`, launch + settings wiring (Tasks 3, 6).
- `Sources/Coda/SettingsTabController.swift` — thread new params/callbacks through (Tasks 3, 6).
- `Sources/Coda/GeneralSettingsViewController.swift` — badge checkbox (Task 3), icon gallery (Task 6).
- `Tests/CodaCoreTests/AgentStateTests.swift` — `needsYouCount` tests (Task 1).
- `Tests/CodaCoreTests/PreferencesTests.swift` — new-field default/round-trip tests (Tasks 2, 4).

---

## Task 1: `needsYouCount` pure function (CodaCore)

**Files:**
- Modify: `Sources/CodaCore/AgentState.swift` (append after `rollup`, ~line 84)
- Test: `Tests/CodaCoreTests/AgentStateTests.swift`

**Interfaces:**
- Produces: `public func needsYouCount(_ rollups: [String: AgentState]) -> Int`

- [ ] **Step 1: Write the failing test**

Append to `Tests/CodaCoreTests/AgentStateTests.swift` (inside the existing `final class AgentStateTests: XCTestCase { ... }` — add before its closing brace):

```swift
    func testNeedsYouCountEmpty() {
        XCTAssertEqual(needsYouCount([:]), 0)
    }

    func testNeedsYouCountCountsOnlyNeedsYou() {
        let rollups: [String: AgentState] = [
            "a": .needsYou, "b": .working, "c": .needsYou, "d": .done, "e": .idle,
        ]
        XCTAssertEqual(needsYouCount(rollups), 2)
    }

    func testNeedsYouCountNoneNeedYou() {
        XCTAssertEqual(needsYouCount(["a": .working, "b": .idle, "c": .done]), 0)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter AgentStateTests`
Expected: FAIL — "cannot find 'needsYouCount' in scope".

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/CodaCore/AgentState.swift` after the `rollup` function (after line 84):

```swift

/// How many worktrees are awaiting the user (rolled-up state `.needsYou`).
/// Drives the Dock badge count. Pure so it is unit-testable without AppKit.
public func needsYouCount(_ rollups: [String: AgentState]) -> Int {
    rollups.values.filter { $0 == .needsYou }.count
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter AgentStateTests`
Expected: PASS (all `needsYouCount` tests green).

- [ ] **Step 5: Commit**

```bash
git add Sources/CodaCore/AgentState.swift Tests/CodaCoreTests/AgentStateTests.swift
git commit -m "feat(core): needsYouCount rollup helper for the Dock badge

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `showDockBadge` preference

**Files:**
- Modify: `Sources/CodaCore/Preferences.swift`
- Test: `Tests/CodaCoreTests/PreferencesTests.swift`

**Interfaces:**
- Produces: `Preferences.showDockBadge: Bool` (default `true`); memberwise-init param `showDockBadge: Bool = true`.

- [ ] **Step 1: Write the failing test**

Append inside `final class PreferencesTests: XCTestCase` in `Tests/CodaCoreTests/PreferencesTests.swift`:

```swift
    func testShowDockBadgeDefaultsTrueForOldPrefs() throws {
        // Prefs written before the Dock badge existed omit the key → must default true.
        let json = #"{"defaultEditor":{"name":"Visual Studio Code","bundleID":"com.microsoft.VSCode","urlScheme":"vscode"}}"#
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        XCTAssertTrue(prefs.showDockBadge)
    }

    func testShowDockBadgeRoundTrips() throws {
        var prefs = Preferences()
        prefs.showDockBadge = false
        let data = try JSONEncoder().encode(prefs)
        XCTAssertFalse(try JSONDecoder().decode(Preferences.self, from: data).showDockBadge)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter PreferencesTests`
Expected: FAIL — "value of type 'Preferences' has no member 'showDockBadge'".

- [ ] **Step 3: Write minimal implementation**

In `Sources/CodaCore/Preferences.swift`, make four edits:

1. Add the stored property (after `accentColor` declaration, ~line 108):

```swift
    /// Whether the Dock icon shows a badge with the count of worktrees that need the user's
    /// input. Defaults to `true`; older prefs files without the key decode to `true` via the
    /// custom decoder below.
    public var showDockBadge: Bool
```

2. Add the memberwise-init parameter (in the `public init(...)` signature, after `accentColor: String? = nil`):

```swift
                accentColor: String? = nil, showDockBadge: Bool = true) {
```

3. Add the assignment (end of the memberwise init body, after `self.accentColor = accentColor`):

```swift
        self.showDockBadge = showDockBadge
```

4. Add `showDockBadge` to `CodingKeys` (extend the `accentColor` line):

```swift
        case accentColor, showDockBadge
```

5. Add the decode line (in `init(from:)`, after the `accentColor` decode):

```swift
        self.showDockBadge = try c.decodeIfPresent(Bool.self, forKey: .showDockBadge) ?? true
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter PreferencesTests`
Expected: PASS (including the existing `testPreferencesHoldsNoAbsolutePaths`, since a Bool adds no path).

- [ ] **Step 5: Commit**

```bash
git add Sources/CodaCore/Preferences.swift Tests/CodaCoreTests/PreferencesTests.swift
git commit -m "feat(prefs): showDockBadge preference (default on)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Wire the Dock badge + its Settings toggle

**Files:**
- Modify: `Sources/Coda/AppDelegate.swift`
- Modify: `Sources/Coda/SettingsTabController.swift`
- Modify: `Sources/Coda/GeneralSettingsViewController.swift`

**Interfaces:**
- Consumes: `needsYouCount(_:)` (Task 1), `Preferences.showDockBadge` (Task 2).
- Produces: `AppDelegate.updateDockBadge(_:)`, `AppDelegate.setShowDockBadge(_:)`; `GeneralSettingsViewController.onChangeShowDockBadge: ((Bool) -> Void)?`; new `SettingsTabController` init params `showDockBadge: Bool` + `onChangeShowDockBadge: @escaping (Bool) -> Void`.

This is a UI/AppKit task — no unit test; it is verified by build + manual run (Task 7).

- [ ] **Step 1: Add the badge updater and call it from the state chokepoint**

In `Sources/Coda/AppDelegate.swift`, add this method (place it next to `recomputeRollupsAndRefreshUI`, ~line 1624):

```swift
    /// Set the Dock badge to the number of worktrees awaiting the user, or clear it when zero
    /// (or when the preference is off). Called from `recomputeRollupsAndRefreshUI`, the single
    /// point every agent-state change flows through. Safe with or without an `.app` bundle.
    private func updateDockBadge(_ rollups: [String: AgentState]) {
        let count = preferences.showDockBadge ? needsYouCount(rollups) : 0
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }
```

Then, inside `recomputeRollupsAndRefreshUI()`, add the call right after `sidebar.updateAgentStates(rollups)` (line 1620):

```swift
        sidebar.updateAgentStates(rollups)
        updateDockBadge(rollups)
```

- [ ] **Step 2: Add the persist-and-apply setter**

In `Sources/Coda/AppDelegate.swift`, add next to `setNotifyOnDone` (~line 1160):

```swift
    /// Persist the Dock-badge toggle and apply it immediately.
    private func setShowDockBadge(_ on: Bool) {
        preferences.showDockBadge = on
        do { try prefsStore.save(preferences) } catch { presentError(error) }
        recomputeRollupsAndRefreshUI()   // re-evaluates the badge with the new setting
    }
```

- [ ] **Step 3: Thread the toggle through SettingsTabController**

In `Sources/Coda/SettingsTabController.swift`:

1. Add init params after the `onChangeNotifyOnDone` param (~line 22):

```swift
         notifyOnDone: Bool,
         onChangeNotifyOnDone: @escaping (Bool) -> Void,
         showDockBadge: Bool,
         onChangeShowDockBadge: @escaping (Bool) -> Void,
```

2. Pass `showDockBadge` into the `GeneralSettingsViewController(...)` constructor (add argument after `notifyOnDone: notifyOnDone`):

```swift
        let general = GeneralSettingsViewController(editor: editor, terminalFont: terminalFont, uiScale: uiScale,
                                                    notifyOnNeedsYou: notifyOnNeedsYou, notifyOnDone: notifyOnDone,
                                                    showDockBadge: showDockBadge,
                                                    shell: shell, completionsEnabled: completionsEnabled,
                                                    accentColor: accentColor)
```

3. Assign the callback (after `general.onChangeNotifyOnDone = onChangeNotifyOnDone`):

```swift
        general.onChangeShowDockBadge = onChangeShowDockBadge
```

- [ ] **Step 4: Add the checkbox in GeneralSettingsViewController**

In `Sources/Coda/GeneralSettingsViewController.swift`:

1. Add stored state + checkbox + callback (near the other notify declarations, ~line 23-28):

```swift
    private var showDockBadge: Bool
    private let showDockBadgeCheckbox = NSButton(checkboxWithTitle: "Show a Dock badge when agents need you",
                                                 target: nil, action: nil)
```

```swift
    var onChangeShowDockBadge: ((Bool) -> Void)?
```

2. Add the init parameter and assignment. Change the `init` signature to insert `showDockBadge: Bool` after `notifyOnDone: Bool,`:

```swift
    init(editor: Editor, terminalFont: NSFont, uiScale: UIScale,
         notifyOnNeedsYou: Bool, notifyOnDone: Bool, showDockBadge: Bool, shell: ShellChoice,
         completionsEnabled: Bool, accentColor: String) {
```

And assign it in the init body (after `self.notifyOnDone = notifyOnDone`):

```swift
        self.showDockBadge = showDockBadge
```

3. Configure the checkbox and add it to the notify stack. In `loadView()`, after `notifyDoneCheckbox.action = #selector(notifyDoneChanged)` (line 132), add:

```swift
        showDockBadgeCheckbox.state = showDockBadge ? .on : .off
        showDockBadgeCheckbox.target = self
        showDockBadgeCheckbox.action = #selector(showDockBadgeChanged)
```

Then include it in `notifyStack` (line 133):

```swift
        let notifyStack = NSStackView(views: [notifyNeedsYouCheckbox, notifyDoneCheckbox, showDockBadgeCheckbox])
```

4. Add the action (next to `notifyDoneChanged`, ~line 330):

```swift
    @objc private func showDockBadgeChanged() {
        showDockBadge = showDockBadgeCheckbox.state == .on
        onChangeShowDockBadge?(showDockBadge)
    }
```

- [ ] **Step 5: Pass the values at the AppDelegate call site**

In `Sources/Coda/AppDelegate.swift`, in the `SettingsTabController(...)` construction (~line 538-539), add after the `onChangeNotifyOnDone` argument:

```swift
                notifyOnDone: preferences.notifyOnDone,
                onChangeNotifyOnDone: { [weak self] on in self?.setNotifyOnDone(on) },
                showDockBadge: preferences.showDockBadge,
                onChangeShowDockBadge: { [weak self] on in self?.setShowDockBadge(on) },
```

- [ ] **Step 6: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: builds with no errors.

- [ ] **Step 7: Commit**

```bash
git add Sources/Coda/AppDelegate.swift Sources/Coda/SettingsTabController.swift Sources/Coda/GeneralSettingsViewController.swift
git commit -m "feat(dock): badge with count of worktrees needing input + Settings toggle

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `appIconName` preference

**Files:**
- Modify: `Sources/CodaCore/Preferences.swift`
- Test: `Tests/CodaCoreTests/PreferencesTests.swift`

**Interfaces:**
- Produces: `Preferences.appIconName: String?` (default `nil`); memberwise-init param `appIconName: String? = nil`.

- [ ] **Step 1: Write the failing test**

Append inside `final class PreferencesTests: XCTestCase`:

```swift
    func testAppIconNameDefaultsNilForOldPrefs() throws {
        let json = #"{"defaultEditor":{"name":"Visual Studio Code","bundleID":"com.microsoft.VSCode","urlScheme":"vscode"}}"#
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        XCTAssertNil(prefs.appIconName)
    }

    func testAppIconNameRoundTrips() throws {
        var prefs = Preferences()
        prefs.appIconName = "Alternate"
        let data = try JSONEncoder().encode(prefs)
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: data).appIconName, "Alternate")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter PreferencesTests`
Expected: FAIL — "value of type 'Preferences' has no member 'appIconName'".

- [ ] **Step 3: Write minimal implementation**

In `Sources/CodaCore/Preferences.swift`, five edits mirroring `accentColor`:

1. Stored property (after `showDockBadge`, added in Task 2):

```swift
    /// The chosen app icon's id (a bundled icon filename stem, e.g. "Alternate"). nil → the
    /// built-in default (`Resources/Coda.icns`). Stores an id, never a path, so config stays
    /// portable. Older prefs files without the key decode to nil via the custom decoder below.
    public var appIconName: String?
```

2. Memberwise-init param (after `showDockBadge: Bool = true`):

```swift
                showDockBadge: Bool = true, appIconName: String? = nil) {
```

3. Assignment (after `self.showDockBadge = showDockBadge`):

```swift
        self.appIconName = appIconName
```

4. `CodingKeys` (extend the line ending with `showDockBadge`):

```swift
        case accentColor, showDockBadge, appIconName
```

5. Decoder line (after the `showDockBadge` decode):

```swift
        self.appIconName = try c.decodeIfPresent(String.self, forKey: .appIconName)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter PreferencesTests`
Expected: PASS. `testPreferencesHoldsNoAbsolutePaths` still passes (id is not a path).

- [ ] **Step 5: Commit**

```bash
git add Sources/CodaCore/Preferences.swift Tests/CodaCoreTests/PreferencesTests.swift
git commit -m "feat(prefs): appIconName preference (nil = default icon)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `AppIconCatalog` + seed the bundled Icons folder

**Files:**
- Create: `Sources/Coda/AppIconCatalog.swift`
- Create: `Sources/Coda/Resources/Icons/Alternate.icns` (copied from `~/Downloads/Coda.icns`)

**Interfaces:**
- Consumes: `Bundle.codaAssets`, `Bundle.codaBundledResource(_:)` (`ResourceBundle.swift`).
- Produces:
  - `struct AppIcon { let id: String; let displayName: String; let image: NSImage }`
  - `enum AppIconCatalog { static func all() -> [AppIcon]; static func image(forID id: String?) -> NSImage? }`
  - The `"Default"` id resolves to `Resources/Coda.icns`.

- [ ] **Step 1: Seed the curated icon into the resource bundle**

```bash
mkdir -p Sources/Coda/Resources/Icons
cp ~/Downloads/Coda.icns Sources/Coda/Resources/Icons/Alternate.icns
ls -la Sources/Coda/Resources/Icons/
```

Expected: `Alternate.icns` present (~379 KB). No `Package.swift` change is needed — `.copy("Resources")` copies the whole tree, so `Icons/` ships in both the `swift run`/test layout and, via `make-app.sh`'s flat copy, the distributed `.app`.

- [ ] **Step 2: Write the AppIconCatalog helper**

Create `Sources/Coda/AppIconCatalog.swift`:

```swift
import AppKit
import CodaCore

/// One selectable app icon: a stable `id` (used as the persisted preference and the swatch's
/// identity), a human `displayName`, and the loaded `image`.
struct AppIcon {
    let id: String
    let displayName: String
    let image: NSImage
}

/// The curated set of app icons the user can choose from in Settings.
///
/// "Default" is synthesised from `Resources/Coda.icns` (which must stay put — the `.app`-layout
/// probe in `ResourceBundle` depends on it) so it always appears first even though it lives
/// outside `Icons/`. Every other entry is discovered by scanning the bundled `Resources/Icons`
/// folder for `.icns` files, so curating the gallery is just adding/removing files there.
enum AppIconCatalog {
    static let defaultID = "Default"

    /// Default first, then each `Icons/*.icns` sorted by filename. Entries whose image fails to
    /// load are skipped (a corrupt/removed file never crashes the picker).
    static func all() -> [AppIcon] {
        var icons: [AppIcon] = []
        if let def = defaultImage() {
            icons.append(AppIcon(id: defaultID, displayName: defaultID, image: def))
        }
        if let dir = Bundle.codaBundledResource("Icons"),
           let urls = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) {
            for url in urls.filter({ $0.pathExtension == "icns" })
                            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let image = NSImage(contentsOf: url) else { continue }
                let id = url.deletingPathExtension().lastPathComponent
                icons.append(AppIcon(id: id, displayName: id, image: image))
            }
        }
        return icons
    }

    /// The image for a chosen id. nil/unknown/"Default" → the default icon. Falling back keeps a
    /// stale preference (a curated icon removed after being selected) from leaving a blank icon.
    static func image(forID id: String?) -> NSImage? {
        guard let id, id != defaultID else { return defaultImage() }
        return all().first { $0.id == id }?.image ?? defaultImage()
    }

    /// `Resources/Coda.icns`, the shipped default, via the same bundle accessor the dock icon
    /// used before this feature existed.
    private static func defaultImage() -> NSImage? {
        guard let url = Bundle.codaAssets.url(forResource: "Coda", withExtension: "icns",
                                              subdirectory: "Resources") else { return nil }
        return NSImage(contentsOf: url)
    }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: builds with no errors.

- [ ] **Step 4: Verify the catalog resolves at runtime (temporary smoke check)**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | tail -3
```
Then confirm both icons are present on disk (the `.build` copy proves the resource shipped):
```bash
find .build -path '*Coda_Coda.bundle*/Icons/*.icns' 2>/dev/null
```
Expected: at least `Alternate.icns` listed under the built resource bundle. (Runtime `AppIconCatalog.all()` count is verified end-to-end in Task 7.)

- [ ] **Step 5: Commit**

```bash
git add Sources/Coda/AppIconCatalog.swift Sources/Coda/Resources/Icons/Alternate.icns
git commit -m "feat(icon): AppIconCatalog + seed curated Icons/ bundle folder

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Apply the chosen icon + Settings gallery

**Files:**
- Modify: `Sources/Coda/AppDelegate.swift`
- Modify: `Sources/Coda/SettingsTabController.swift`
- Modify: `Sources/Coda/GeneralSettingsViewController.swift`

**Interfaces:**
- Consumes: `AppIconCatalog` (Task 5), `Preferences.appIconName` (Task 4).
- Produces: `AppDelegate.applyAppIcon()` (replaces `applyDockIcon()`), `AppDelegate.setAppIcon(_:)`; `GeneralSettingsViewController.onChangeAppIcon: ((String) -> Void)?`; new `SettingsTabController` init params `appIconName: String?` + `onChangeAppIcon: @escaping (String) -> Void`.

UI/AppKit task — verified by build + manual run (Task 7).

- [ ] **Step 1: Replace `applyDockIcon` with `applyAppIcon` and fix launch ordering**

In `Sources/Coda/AppDelegate.swift`, replace the whole `applyDockIcon()` method (lines 316-324) with:

```swift
    /// Whether we're running from a real `.app` bundle (vs a bare `swift run` executable).
    /// Only then does it make sense — or is it permitted — to set the bundle's Finder icon.
    private var isRunningFromAppBundle: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    /// Apply the user's chosen app icon to the running Dock/app-switcher icon and, when running
    /// as an installed `.app`, to the bundle's Finder icon.
    ///
    /// - Dock: `NSApp.applicationIconImage` — immediate, works in every layout (we run as a bare
    ///   executable with no `CFBundleIconFile` under `swift run`, so the icon is always applied
    ///   programmatically).
    /// - Finder: `NSWorkspace.setIcon(_:forFile:)` writes a custom icon as an extended attribute
    ///   on the `.app` directory. It does NOT modify the sealed `Contents/`, so the Developer-ID
    ///   code signature stays valid. A Homebrew update replaces the whole `.app` and drops the
    ///   xattr; because this runs on every launch, the first post-update launch re-applies it.
    private func applyAppIcon() {
        guard let image = AppIconCatalog.image(forID: preferences.appIconName) else { return }
        NSApp.applicationIconImage = image
        if isRunningFromAppBundle {
            NSWorkspace.shared.setIcon(image, forFile: Bundle.main.bundlePath, options: [])
        }
    }
```

- [ ] **Step 2: Fix the launch call — it must run after preferences load**

In `applicationDidFinishLaunching`, `applyDockIcon()` is currently the first line (line 75), but it now reads `preferences`, which isn't loaded until line 82. Remove the line-75 call and add the new call right after `preferences = prefsStore.load()` (line 82):

Delete this line (75):

```swift
        applyDockIcon()
```

And after `preferences = prefsStore.load()` (line 82) add:

```swift
        preferences = prefsStore.load()
        applyAppIcon()
```

- [ ] **Step 3: Add the persist-and-apply setter**

In `Sources/Coda/AppDelegate.swift`, add next to `setAccentColor` (~line 1148):

```swift
    /// Persist the chosen app icon and apply it immediately (Dock + Finder).
    private func setAppIcon(_ id: String) {
        preferences.appIconName = id
        do { try prefsStore.save(preferences) } catch { presentError(error) }
        applyAppIcon()
    }
```

- [ ] **Step 4: Thread the icon choice through SettingsTabController**

In `Sources/Coda/SettingsTabController.swift`:

1. Add init params after the `onChangeAccentColor` param (~line 28), before the closing `)` of the signature:

```swift
         accentColor: String,
         onChangeAccentColor: @escaping (String) -> Void,
         appIconName: String?,
         onChangeAppIcon: @escaping (String) -> Void) {
```

2. Pass `appIconName` into the `GeneralSettingsViewController(...)` constructor (add argument after `accentColor: accentColor`):

```swift
        let general = GeneralSettingsViewController(editor: editor, terminalFont: terminalFont, uiScale: uiScale,
                                                    notifyOnNeedsYou: notifyOnNeedsYou, notifyOnDone: notifyOnDone,
                                                    showDockBadge: showDockBadge,
                                                    shell: shell, completionsEnabled: completionsEnabled,
                                                    accentColor: accentColor, appIconName: appIconName)
```

3. Assign the callback (after `general.onChangeAccentColor = onChangeAccentColor`):

```swift
        general.onChangeAppIcon = onChangeAppIcon
```

- [ ] **Step 5: Add the icon gallery to GeneralSettingsViewController**

In `Sources/Coda/GeneralSettingsViewController.swift`:

1. Add stored state + views + callback (near the `accentColor` declarations, ~line 36-45):

```swift
    private var appIconName: String?
    private let appIconRow = NSStackView()
    private var appIconButtons: [NSButton] = []
    private let appIcons = AppIconCatalog.all()
```

```swift
    var onChangeAppIcon: ((String) -> Void)?
```

2. Add the init parameter + assignment. Change the `init` signature to append `appIconName: String?` after `accentColor: String`:

```swift
    init(editor: Editor, terminalFont: NSFont, uiScale: UIScale,
         notifyOnNeedsYou: Bool, notifyOnDone: Bool, showDockBadge: Bool, shell: ShellChoice,
         completionsEnabled: Bool, accentColor: String, appIconName: String?) {
```

And in the init body (after `self.accentColor = accentColor`):

```swift
        self.appIconName = appIconName
```

3. Build the gallery in `loadView()`. After the accent section setup (after `accentHint` is created, ~line 186), add:

```swift
        // App icon — a gallery of bundled icons. Selecting one changes the Dock + Finder icon.
        let appIconTitle = NSTextField(labelWithString: "App Icon")
        appIconTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
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
        let appIconHint = NSTextField(labelWithString: "Changes the Dock and Finder icon. Applies immediately.")
        appIconHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        appIconHint.textColor = .secondaryLabelColor
```

4. Add the three views to the main `stack` (in the `NSStackView(views: [...])` list, after `accentTitle, accentSwatchRow, accentHint,`):

```swift
            accentTitle, accentSwatchRow, accentHint,
            appIconTitle, appIconRow, appIconHint,
```

5. Select the current icon after the view is assembled. At the end of `loadView()`, right after the existing `updateAccentSelection()` call (line 211), add:

```swift
        updateAccentSelection()
        updateAppIconSelection()
```

6. Add the action, selection-ring, and thumbnail helpers (next to `accentSwatchClicked` / `circleImage`, ~line 343-363):

```swift
    @objc private func appIconClicked(_ sender: NSButton) {
        guard appIcons.indices.contains(sender.tag) else { return }
        appIconName = appIcons[sender.tag].id
        updateAppIconSelection()
        onChangeAppIcon?(appIcons[sender.tag].id)
    }

    /// Ring the button whose icon matches the active choice (nil → the "Default" entry).
    private func updateAppIconSelection() {
        let selectedID = appIconName ?? AppIconCatalog.defaultID
        for (index, button) in appIconButtons.enumerated() {
            let isSelected = appIcons[index].id == selectedID
            button.layer?.borderWidth = isSelected ? 2 : 0
            button.layer?.borderColor = isSelected ? NSColor.controlAccentColor.cgColor : nil
        }
    }

    /// A square, correctly-sized thumbnail for a swatch button (`.icns` images are multi-rep;
    /// setting an explicit size makes AppKit pick a crisp representation).
    private static func iconThumbnail(_ image: NSImage, side: CGFloat) -> NSImage {
        let copy = image.copy() as! NSImage
        copy.size = NSSize(width: side, height: side)
        return copy
    }
```

- [ ] **Step 6: Pass the values at the AppDelegate call site**

In `Sources/Coda/AppDelegate.swift`, in the `SettingsTabController(...)` construction, extend the accent arguments (~line 544-545):

```swift
                accentColor: AccentColor.resolve(preferences.accentColor),
                onChangeAccentColor: { [weak self] hex in self?.setAccentColor(hex) },
                appIconName: preferences.appIconName,
                onChangeAppIcon: { [weak self] id in self?.setAppIcon(id) })
```

- [ ] **Step 7: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: builds with no errors.

- [ ] **Step 8: Commit**

```bash
git add Sources/Coda/AppDelegate.swift Sources/Coda/SettingsTabController.swift Sources/Coda/GeneralSettingsViewController.swift
git commit -m "feat(icon): Settings gallery to pick the app icon (Dock + Finder)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: End-to-end verification in the built app

**Files:** none (verification only).

**Interfaces:** Consumes everything above.

- [ ] **Step 1: Full test suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest`
Expected: all tests pass (new `needsYouCount` + `Preferences` tests included).

- [ ] **Step 2: Build the distributable app**

Run: `VERSION=0.0.0-dev scripts/make-app.sh`
Expected: `dist/Coda.app` built and ad-hoc sealed ("bundle is ad-hoc sealed"). Confirm the icons shipped:
```bash
ls dist/Coda.app/Contents/Resources/Icons/
```
Expected: `Alternate.icns`.

- [ ] **Step 3: Launch and verify the Dock badge**

Run: `open dist/Coda.app`

Then, using the `verify` skill's approach (drive the real flow):
- Open a worktree and start Claude; drive it to a state where it asks you a question (needs-you). Confirm the Dock icon shows a red badge `1`.
- Trigger needs-you in a second worktree → badge shows `2`.
- Respond to one → badge drops to `1`; respond to both → badge clears.
- Open Settings → General, untick "Show a Dock badge when agents need you" → badge clears immediately while still in needs-you. Re-tick → badge returns.

- [ ] **Step 4: Verify the app-icon picker**

- Settings → General → App Icon: confirm two swatches ("Default" and "Alternate"), with Default ringed.
- Click "Alternate" → the Dock icon changes immediately; check Finder (`dist/Coda.app` in a Finder window) shows the new icon too.
- Quit and relaunch (`open dist/Coda.app`) → the Alternate icon persists (Dock + Finder).
- Confirm the signature survived the Finder-icon write:
```bash
codesign --verify --strict --verbose=2 dist/Coda.app && echo "signature OK"
```
Expected: "signature OK" (setting the icon via xattr does not invalidate the seal).
- Switch back to "Default" → both icons revert.

- [ ] **Step 5: Final commit (if any verification fixups were needed)**

If Steps 1-4 required no code changes, there is nothing to commit and the feature is complete. If a fix was needed, commit it:

```bash
git add -A
git commit -m "fix(dock/icon): address verification findings

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review Notes

- **Spec coverage:** Dock badge count (Tasks 1,3) ✓; badge pref + toggle (Tasks 2,3) ✓; bundled auto-scanned gallery (Task 5) ✓; Default entry = `Coda.icns`, seeded `Alternate.icns` (Task 5) ✓; Dock + Finder application via xattr, launch reapply, signature-safe (Task 6) ✓; `appIconName` pref (Task 4) ✓; settings UI for both (Tasks 3,6) ✓; CodaCore unit test + manual verification (Tasks 1,7) ✓.
- **Out-of-scope items** (file picker, per-worktree icons, bounce animation, separate Finder toggle) are not implemented, per spec.
- **Type consistency:** `needsYouCount`, `showDockBadge`, `appIconName`, `AppIconCatalog.all()/image(forID:)/defaultID`, `applyAppIcon`, `setShowDockBadge`, `setAppIcon`, `onChangeShowDockBadge`, `onChangeAppIcon` are used identically across tasks.
