# Conductor Repo Settings UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A "Settings…" sheet (opened from the sidebar toolbar) lets you pick a registered repo and edit its `setupScript` and `copyAllowlist` (one path per line), with validation that rejects absolute/`..`-escaping paths — and the copy engine defensively skips such paths too.

**Architecture:** Two small pure additions to `ConductorCore` (TDD): a `isSafeRelativePath` guard wired into `copyAllowlistedFiles`, and a `parseAllowlist` text→list helper. Then one AppKit task (build + manual verify): a `RepoSettingsController` sheet with a repo dropdown + two text editors, a "Settings…" button in the sidebar, and `AppDelegate` wiring that persists via `SessionStore.updateRepository`.

**Tech Stack:** Swift (Swift 5 language mode), SwiftPM, AppKit, XCTest.

## Global Constraints

- **TOOLCHAIN:** Command Line Tools lack XCTest. Prefix **every** `swift build`/`run`/`test` with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Tests are **XCTest** (`import XCTest`, `XCTestCase`, `XCTAssert*`). Filter by class: `swift test --filter ConductorCoreTests.<ClassName>`.
- **Path safety:** allowlist entries must be relative with no `..` components. The copy engine MUST skip unsafe entries (defense in depth); the Save action MUST reject them with a visible message.
- **Persistence:** edits persist via `SessionStore.updateRepository(id:setupScript:copyAllowlist:)` (already exists) → machine-local `~/.conductor/local.json`. No absolute paths hardcoded in source.
- **macOS target:** `.macOS(.v13)`; `swiftLanguageModes: [.v5]`.
- **Out of scope (defer):** showing repositories as a list in the sidebar (the dropdown surfaces them for now); a context-menu entry point; editing a repo's path/name.

## File Structure

```
Sources/ConductorCore/
  FileCopy.swift        # MODIFY: add isSafeRelativePath; copyAllowlistedFiles skips unsafe entries
  AllowlistText.swift   # CREATE: parseAllowlist(_:) -> [String]
Sources/Conductor/
  RepoSettingsController.swift  # CREATE: the settings sheet
  SidebarController.swift       # MODIFY: add "Settings…" button + onRepoSettings callback
  AppDelegate.swift             # MODIFY: wire onRepoSettings -> present sheet -> updateRepository
Tests/ConductorCoreTests/
  FileCopyTests.swift           # MODIFY: add path-safety tests
  AllowlistTextTests.swift      # CREATE
```

**Interfaces locked across tasks:**

```swift
// FileCopy.swift (Task 1)
public func isSafeRelativePath(_ rel: String) -> Bool   // false if absolute, has "..", or empty

// AllowlistText.swift (Task 2)
public func parseAllowlist(_ text: String) -> [String]  // split lines, trim, drop blanks

// SidebarController.swift (Task 3)
var onRepoSettings: (() -> Void)?

// RepoSettingsController.swift (Task 3)
init(repos: [Repository])
var onSave: ((String, String, [String]) -> Void)?       // (repoID, setupScript, allowlist)
```

---

### Task 1: Path-safety guard in copyAllowlistedFiles

**Files:**
- Modify: `Sources/ConductorCore/FileCopy.swift`
- Test: `Tests/ConductorCoreTests/FileCopyTests.swift`

**Interfaces:**
- Consumes: existing `copyAllowlistedFiles`.
- Produces: `isSafeRelativePath(_:) -> Bool`; `copyAllowlistedFiles` now skips unsafe entries.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ConductorCoreTests/FileCopyTests.swift` inside the `FileCopyTests` class:
```swift
    func testIsSafeRelativePath() {
        XCTAssertTrue(isSafeRelativePath("a/b"))
        XCTAssertTrue(isSafeRelativePath(".env"))
        XCTAssertTrue(isSafeRelativePath("apps/web/.env.local"))
        XCTAssertFalse(isSafeRelativePath("/etc/hosts"))   // absolute
        XCTAssertFalse(isSafeRelativePath("../secret"))    // escapes
        XCTAssertFalse(isSafeRelativePath("a/../../b"))     // escapes via ..
        XCTAssertFalse(isSafeRelativePath(""))              // empty
    }

    func testCopySkipsUnsafePaths() throws {
        let src = try makeDir(), dst = try makeDir()
        try "x".write(toFile: src + "/.env", atomically: true, encoding: .utf8)
        // Absolute + parent-escape entries must be skipped; the safe one copied.
        let copied = try copyAllowlistedFiles(from: src, to: dst, allowlist: ["/etc/hosts", "../escape", ".env"])
        XCTAssertEqual(copied, [".env"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst + "/.env"))
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ConductorCoreTests.FileCopyTests`
Expected: FAIL — `isSafeRelativePath` not in scope.

- [ ] **Step 3: Add the guard**

In `Sources/ConductorCore/FileCopy.swift`, add this function above `copyAllowlistedFiles`:
```swift
/// True if `rel` is a safe relative path to copy into a worktree: not absolute,
/// no `..` components, not empty. Prevents allowlist entries from reading or
/// writing outside the repo/worktree.
public func isSafeRelativePath(_ rel: String) -> Bool {
    if rel.hasPrefix("/") { return false }
    let comps = rel.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    if comps.isEmpty { return false }
    return !comps.contains("..")
}
```

Then, inside `copyAllowlistedFiles`, as the FIRST statement in the `for rel in allowlist` loop (before the `let source = ...` line), add:
```swift
        guard isSafeRelativePath(rel) else { continue }
```

- [ ] **Step 4: Run to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ConductorCoreTests.FileCopyTests`
Expected: PASS (all FileCopy tests, including the two new ones).

- [ ] **Step 5: Commit**

```bash
git add Sources/ConductorCore/FileCopy.swift Tests/ConductorCoreTests/FileCopyTests.swift
git commit -m "feat: skip unsafe (absolute/.. ) allowlist paths in copyAllowlistedFiles"
```

---

### Task 2: parseAllowlist text helper

**Files:**
- Create: `Sources/ConductorCore/AllowlistText.swift`
- Test: `Tests/ConductorCoreTests/AllowlistTextTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `parseAllowlist(_:) -> [String]`.

- [ ] **Step 1: Write the failing tests**

`Tests/ConductorCoreTests/AllowlistTextTests.swift`:
```swift
import XCTest
@testable import ConductorCore

final class AllowlistTextTests: XCTestCase {
    func testParsesLinesTrimmingAndDroppingBlanks() {
        let text = ".env\n  apps/web/.env.local  \n\n\tconfig\n"
        XCTAssertEqual(parseAllowlist(text), [".env", "apps/web/.env.local", "config"])
    }

    func testHandlesCRLFAndEmptyInput() {
        XCTAssertEqual(parseAllowlist(".env\r\n.env.local\r\n"), [".env", ".env.local"])
        XCTAssertEqual(parseAllowlist(""), [])
        XCTAssertEqual(parseAllowlist("   \n\t\n"), [])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ConductorCoreTests.AllowlistTextTests`
Expected: FAIL — `parseAllowlist` not in scope.

- [ ] **Step 3: Implement parseAllowlist**

`Sources/ConductorCore/AllowlistText.swift`:
```swift
import Foundation

/// Parse a multiline allowlist (one path per line): trim each line of surrounding
/// whitespace (incl. trailing \r from CRLF) and drop blank lines.
public func parseAllowlist(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ConductorCoreTests.AllowlistTextTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Run the full Core suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: PASS (all ConductorCore tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/ConductorCore/AllowlistText.swift Tests/ConductorCoreTests/AllowlistTextTests.swift
git commit -m "feat: add parseAllowlist (multiline text -> path list)"
```

---

### Task 3: Repo settings sheet + sidebar button + wiring

**Files:**
- Create: `Sources/Conductor/RepoSettingsController.swift`
- Modify: `Sources/Conductor/SidebarController.swift`
- Modify: `Sources/Conductor/AppDelegate.swift`

**Interfaces:**
- Consumes: `Repository`, `SessionStore.updateRepository`, `parseAllowlist` (Task 2), `isSafeRelativePath` (Task 1).
- Produces: a working settings sheet.

- [ ] **Step 1: Create the settings sheet**

`Sources/Conductor/RepoSettingsController.swift`:
```swift
import AppKit
import ConductorCore

/// Sheet to edit a repository's setupScript + copyAllowlist. Choose a repo from the
/// popup, edit the fields, then Save: it parses the allowlist, validates each path
/// (no absolute or `..` paths), and calls `onSave(repoID, setupScript, allowlist)`.
final class RepoSettingsController: NSViewController {
    private let repos: [Repository]
    private let popup = NSPopUpButton()
    private let setupScroll = NSScrollView()
    private let setupTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 80))
    private let allowlistScroll = NSScrollView()
    private let allowlistTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 120))
    private let errorLabel = NSTextField(labelWithString: "")

    var onSave: ((String, String, [String]) -> Void)?

    init(repos: [Repository]) {
        self.repos = repos
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let container = NSView()

        popup.target = self
        popup.action = #selector(repoChanged)
        for r in repos { popup.addItem(withTitle: r.name) }

        configureEditor(setupScroll, setupTextView)
        configureEditor(allowlistScroll, allowlistTextView)

        let setupLabel = NSTextField(labelWithString: "Setup script (runs once in the terminal before claude):")
        let allowlistLabel = NSTextField(labelWithString: "Copy into new worktrees — one path per line (e.g. .env):")
        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelAction))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(saveAction))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [errorLabel, cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [popup, setupLabel, setupScroll, allowlistLabel, allowlistScroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 540),
            setupScroll.heightAnchor.constraint(equalToConstant: 80),
            allowlistScroll.heightAnchor.constraint(equalToConstant: 140),
            setupScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            allowlistScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        view = container
        loadFields()
    }

    private func configureEditor(_ scroll: NSScrollView, _ tv: NSTextView) {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        tv.isRichText = false
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
    }

    private var selectedRepo: Repository? {
        let i = popup.indexOfSelectedItem
        return (i >= 0 && i < repos.count) ? repos[i] : nil
    }

    private func loadFields() {
        guard let r = selectedRepo else { return }
        setupTextView.string = r.setupScript
        allowlistTextView.string = r.copyAllowlist.joined(separator: "\n")
        errorLabel.stringValue = ""
    }

    @objc private func repoChanged() { loadFields() }
    @objc private func cancelAction() { dismiss(self) }

    @objc private func saveAction() {
        guard let r = selectedRepo else { dismiss(self); return }
        let allowlist = parseAllowlist(allowlistTextView.string)
        if let bad = allowlist.first(where: { !isSafeRelativePath($0) }) {
            errorLabel.stringValue = "Invalid path “\(bad)” — must be relative, no “..”."
            return
        }
        onSave?(r.id, setupTextView.string, allowlist)
        dismiss(self)
    }
}
```

- [ ] **Step 2: Add the "Settings…" button + callback to SidebarController**

In `Sources/Conductor/SidebarController.swift`:

(a) Add the callback near the other `var on…` declarations:
```swift
    var onRepoSettings: (() -> Void)?
```

(b) In `loadView()`, replace the toolbar construction lines:
```swift
        let addRepo = NSButton(title: "Add Repo…", target: self, action: #selector(addRepoAction))
        let new = NSButton(title: "New Session", target: self, action: #selector(newAction))
        let archive = NSButton(title: "Archive", target: self, action: #selector(archiveAction))
        let bar = NSStackView(views: [addRepo, new, archive])
```
with:
```swift
        let addRepo = NSButton(title: "Add Repo…", target: self, action: #selector(addRepoAction))
        let settings = NSButton(title: "Settings…", target: self, action: #selector(settingsAction))
        let new = NSButton(title: "New Session", target: self, action: #selector(newAction))
        let archive = NSButton(title: "Archive", target: self, action: #selector(archiveAction))
        let bar = NSStackView(views: [addRepo, settings, new, archive])
```

(c) Add the action method next to the other `@objc` actions:
```swift
    @objc private func settingsAction() { onRepoSettings?() }
```

- [ ] **Step 3: Wire it in AppDelegate**

In `Sources/Conductor/AppDelegate.swift`:

(a) In `wireSidebar()`, add:
```swift
        sidebar.onRepoSettings = { [weak self] in self?.openRepoSettings() }
```

(b) Add this method (e.g. after `addRepo()`):
```swift
    private func openRepoSettings() {
        guard !store.state.repositories.isEmpty else {
            presentMessage("Add a repo first (Add Repo…).")
            return
        }
        let vc = RepoSettingsController(repos: store.state.repositories)
        vc.onSave = { [weak self] id, setup, allowlist in
            do { _ = try self?.store.updateRepository(id: id, setupScript: setup, copyAllowlist: allowlist) }
            catch { self?.presentError(error) }
        }
        splitVC.presentAsSheet(vc)
    }
```

- [ ] **Step 4: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: `Build complete!`

- [ ] **Step 5: Confirm Core suite still green**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: PASS (all ConductorCore tests).

- [ ] **Step 6: Manual verification (controller/user — GUI)**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run Conductor`, then:
1. Add a repo if none exists. Click **Settings…** → a sheet appears with a repo dropdown, a setup-script editor, and an allowlist editor.
2. Type a setup script (e.g. `echo hello`) and an allowlist (e.g. `.env` on its own line). **Save**. Reopen Settings… → the values are still there (persisted).
3. Enter an invalid allowlist line — `../secret` or `/etc/hosts` — and **Save** → a red error appears and the sheet does NOT close/save.
4. Fix it, Save. Then **New Session** on that repo → the setup script runs in the terminal (ties to the prior feature), confirming the saved config is used.
5. With multiple repos, switching the dropdown loads each repo's own values.

- [ ] **Step 7: Commit**

```bash
git add Sources/Conductor/RepoSettingsController.swift Sources/Conductor/SidebarController.swift Sources/Conductor/AppDelegate.swift
git commit -m "feat: per-repo settings sheet to edit setupScript + copyAllowlist"
```

---

## Notes for the implementer

- **Toolchain:** every `swift` command needs `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Tests are XCTest.
- **Tasks 1–2 are pure `ConductorCore` (TDD). Task 3 is AppKit** — verified by `swift build` + the manual GUI checklist (a subagent can build + liveness-check but cannot drive the sheet; visual verification is the controller/user's).
- **`NSTextView` programmatic layout is fiddly.** If the editors render zero-height or don't scroll, the fix is in the scroll/text-view constraints in `configureEditor`/`loadView` — adjust there; do not change the Core helpers.
- **Defense in depth is intentional:** the Save action rejects unsafe paths (good UX), AND `copyAllowlistedFiles` skips them (so a hand-edited `local.json` can't escape either). Keep both.
