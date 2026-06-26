# Repository Color + Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let each registered repository carry an optional display-name (rename) and color that tint its sidebar header and cascade to its worktree-row subtitles, mirroring Supacode.

**Architecture:** Two optional fields (`displayName`, `color`) added to the machine-local `Repository` model; two dedicated store setters (each nil-clears one field); sidebar `viewFor` tints the repo header text and builds an attributed `repo · branch` subtitle; a right-click repo menu (Rename… + Set Color/Remove Color) wired through `SidebarController` closures to `AppDelegate`.

**Tech Stack:** Swift 6 / SwiftPM, AppKit, XCTest. `ConductorCore` (pure logic, tested) + `Conductor` (AppKit shell, verified in-app).

## Global Constraints

- Every `swift build`/`run`/`test` MUST be prefixed `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (Command Line Tools ship no XCTest; two divergent toolchains on this machine).
- Tests are **XCTest**, not Swift Testing.
- Rename is **display-only** — never rename the folder, git repo, or branch.
- Repos are **not** auto-assigned a color (nil default → secondary gray); colors are set manually only. (Worktrees keep their existing `IdentityPalette` auto-assign — do not touch that.)
- Repo color/name live in the existing machine-local `Repository` config; no portable/local split change.
- Backward-compat: new fields decode via `decodeIfPresent` so older configs load unchanged.
- Branch: continue on `phase1-supacode-parity` (this builds on its two-line subtitle work).

---

### Task 1: `Repository` model — `displayName` + `color` + `sidebarDisplayName`

**Files:**
- Modify: `Sources/ConductorCore/Models.swift:3-33`
- Test: `Tests/ConductorCoreTests/ModelsCodableTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `Repository.displayName: String?`, `Repository.color: String?`, `Repository.sidebarDisplayName: String`, and the extended memberwise `init(... displayName: String? = nil, color: String? = nil)`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ConductorCoreTests/ModelsCodableTests.swift`:

```swift
func testRepositoryDecodesOldJSONWithoutColorOrDisplayName() throws {
    let json = #"{"id":"r1","path":"/tmp/repo","name":"repo"}"#
    let repo = try JSONDecoder().decode(Repository.self, from: Data(json.utf8))
    XCTAssertNil(repo.displayName)
    XCTAssertNil(repo.color)
}

func testRepositoryRoundTripsDisplayNameAndColor() throws {
    let repo = Repository(id: "r1", path: "/tmp/repo", name: "repo",
                          displayName: "My Repo", color: "#D97757")
    let back = try JSONDecoder().decode(Repository.self,
                                        from: JSONEncoder().encode(repo))
    XCTAssertEqual(back, repo)
}

func testSidebarDisplayNameFallsBackAndOverrides() {
    let base = Repository(id: "r1", path: "/tmp/repo", name: "folder-name")
    XCTAssertEqual(base.sidebarDisplayName, "folder-name")                 // nil → folder name

    var blank = base; blank.displayName = "   "
    XCTAssertEqual(blank.sidebarDisplayName, "folder-name")                // whitespace → folder name

    var named = base; named.displayName = "  Pretty Name  "
    XCTAssertEqual(named.sidebarDisplayName, "Pretty Name")                // trimmed override
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ModelsCodableTests 2>&1 | tail -20`
Expected: compile failure / FAIL — `Repository` has no `displayName`, `color`, or `sidebarDisplayName`.

- [ ] **Step 3: Add the fields, init params, coding, and helper**

In `Sources/ConductorCore/Models.swift`, edit the `Repository` struct. Add the stored properties after `autoLaunchClaude`:

```swift
    /// Display-only rename override; nil/blank → use the folder-derived `name`.
    public var displayName: String?
    /// Identity color as a hex string (e.g. "#D97757"); nil → secondary gray.
    public var color: String?
```

Extend the memberwise init signature and body:

```swift
    public init(id: String, path: String, name: String,
                setupScript: String = "", copyAllowlist: [String] = [],
                autoLaunchClaude: Bool = false,
                displayName: String? = nil, color: String? = nil) {
        self.id = id; self.path = path; self.name = name
        self.setupScript = setupScript; self.copyAllowlist = copyAllowlist
        self.autoLaunchClaude = autoLaunchClaude
        self.displayName = displayName; self.color = color
    }
```

Add the two keys to `CodingKeys`:

```swift
    private enum CodingKeys: String, CodingKey {
        case id, path, name, setupScript, copyAllowlist, autoLaunchClaude, displayName, color
    }
```

Append to the custom `init(from:)` (after the `autoLaunchClaude` line):

```swift
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        color = try c.decodeIfPresent(String.self, forKey: .color)
```

Add the computed helper inside the struct (after `init(from:)`):

```swift
    /// The name to show in the sidebar: a non-blank `displayName`, else the folder `name`.
    public var sidebarDisplayName: String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { return trimmed }
        return name
    }
```

> Note: `Repository` uses a custom `init(from:)` but relies on the synthesized
> encoder. Because the new properties are in `CodingKeys`, encoding includes them
> automatically — no `encode(to:)` needed.

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ModelsCodableTests 2>&1 | tail -20`
Expected: PASS (all three new tests + existing ones).

- [ ] **Step 5: Commit**

```bash
git add Sources/ConductorCore/Models.swift Tests/ConductorCoreTests/ModelsCodableTests.swift
git commit -m "feat(core): Repository displayName + color fields + sidebarDisplayName"
```

---

### Task 2: `WorktreeStore` — `setRepositoryColor` + `setRepositoryDisplayName`

**Files:**
- Modify: `Sources/ConductorCore/WorktreeStore.swift` (add two methods near `setWorktreeColor:111-118`)
- Test: `Tests/ConductorCoreTests/WorktreeStoreTests.swift`

**Interfaces:**
- Consumes: `Repository.displayName`, `Repository.color` (Task 1).
- Produces:
  - `func setRepositoryColor(id: String, color: String?) throws -> Repository`
  - `func setRepositoryDisplayName(id: String, displayName: String?) throws -> Repository`
  - Each sets exactly one field (nil clears it), persists, and returns the updated repo. (This supersedes the spec's `String??` suggestion — per-field setters mirror the existing `setWorktreeColor` and make "clear" unambiguous.)

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ConductorCoreTests/WorktreeStoreTests.swift`:

```swift
func testSetRepositoryColorPersistsAndClears() throws {
    let repo = try makeTempRepo()
    let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
    let r = try store.addRepository(path: repo)

    _ = try store.setRepositoryColor(id: r.id, color: "#D97757")
    XCTAssertEqual(cfg.load().repositories.first(where: { $0.id == r.id })?.color, "#D97757")

    _ = try store.setRepositoryColor(id: r.id, color: nil)
    XCTAssertNil(cfg.load().repositories.first(where: { $0.id == r.id })?.color)
}

func testSetRepositoryDisplayNamePersistsAndClears() throws {
    let repo = try makeTempRepo()
    let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
    let r = try store.addRepository(path: repo)

    let renamed = try store.setRepositoryDisplayName(id: r.id, displayName: "Pretty")
    XCTAssertEqual(renamed.sidebarDisplayName, "Pretty")
    XCTAssertEqual(cfg.load().repositories.first(where: { $0.id == r.id })?.displayName, "Pretty")

    _ = try store.setRepositoryDisplayName(id: r.id, displayName: nil)
    XCTAssertNil(cfg.load().repositories.first(where: { $0.id == r.id })?.displayName)
}

func testSetRepositoryColorUnknownIDThrows() throws {
    let (store, _) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
    XCTAssertThrowsError(try store.setRepositoryColor(id: "nope", color: "#fff"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter WorktreeStoreTests 2>&1 | tail -20`
Expected: compile failure — `setRepositoryColor` / `setRepositoryDisplayName` undefined.

- [ ] **Step 3: Add the two setters**

In `Sources/ConductorCore/WorktreeStore.swift`, immediately after `setWorktreeColor(id:color:)` (ends line ~118), add:

```swift
    public func setRepositoryColor(id: String, color: String?) throws -> Repository {
        guard let idx = state.repositories.firstIndex(where: { $0.id == id }) else {
            throw WorktreeStoreError.repoNotFound(id)
        }
        state.repositories[idx].color = color
        try config.save(state)
        return state.repositories[idx]
    }

    public func setRepositoryDisplayName(id: String, displayName: String?) throws -> Repository {
        guard let idx = state.repositories.firstIndex(where: { $0.id == id }) else {
            throw WorktreeStoreError.repoNotFound(id)
        }
        state.repositories[idx].displayName = displayName
        try config.save(state)
        return state.repositories[idx]
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter WorktreeStoreTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ConductorCore/WorktreeStore.swift Tests/ConductorCoreTests/WorktreeStoreTests.swift
git commit -m "feat(core): store setters for repository color + display name"
```

---

### Task 3: Sidebar rendering — header tint + display name + subtitle cascade

**Files:**
- Modify: `Sources/Conductor/SidebarController.swift` (the `viewFor` method, RepoNode branch ~258-264 and WorktreeNode branch ~265-272)

**Interfaces:**
- Consumes: `Repository.sidebarDisplayName`, `Repository.color` (Task 1); existing `NSColor(hex:)`, `chrome?.color(.secondaryText)`, `cell.subtitleLabel`, `outlineView.parent(forItem:)`.
- Produces: no new API — visual only. Verified by build + in-app.

- [ ] **Step 1: Tint the repo header + use the display name**

In `outlineView(_:viewFor:item:)`, replace the RepoNode branch body:

```swift
        if let repo = item as? RepoNode {
            // Repo rows are plain section headers, à la Supacode; tinted by the repo's color.
            let cell = makeCell(identifier: "repo", symbol: nil)
            cell.textField?.stringValue = repo.repository.sidebarDisplayName
            cell.textField?.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            let repoColor = repo.repository.color.flatMap { NSColor(hex: $0) }
            cell.textField?.textColor = repoColor
                ?? (chrome?.color(.secondaryText).nsColor) ?? .secondaryLabelColor
            return cell
        }
```

- [ ] **Step 2: Build the attributed `repo · branch` subtitle**

Replace the WorktreeNode branch's subtitle assignment (the two lines that today set `cell.subtitleLabel.stringValue = repoName.map { ... } ?? wt.worktree.branch`) with:

```swift
            let branch = wt.worktree.branch
            let parentRepo = (outlineView.parent(forItem: item) as? RepoNode)?.repository
            let secondary = NSColor.secondaryLabelColor
            let subFont = cell.subtitleLabel.font ?? .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize)
            if let parentRepo {
                let repoColor = parentRepo.color.flatMap { NSColor(hex: $0) } ?? secondary
                let s = NSMutableAttributedString(
                    string: parentRepo.sidebarDisplayName,
                    attributes: [.foregroundColor: repoColor, .font: subFont])
                s.append(NSAttributedString(
                    string: " · \(branch)",
                    attributes: [.foregroundColor: secondary, .font: subFont]))
                cell.subtitleLabel.attributedStringValue = s
            } else {
                cell.subtitleLabel.stringValue = branch
            }
```

> The rest of the WorktreeNode branch (title, `applyBadge`, `applyIdentityColor`,
> `return cell`) is unchanged. Keep `cell.textField?.stringValue = wt.worktree.title`.

- [ ] **Step 3: Build and verify**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 4: In-app visual check (manual)**

Run the app (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run Conductor`). Repo headers still render gray (no colors set yet); worktree rows still show `repo · branch`. No regression. (Coloring is exercised after Task 4 wires the menu.)

- [ ] **Step 5: Commit**

```bash
git add Sources/Conductor/SidebarController.swift
git commit -m "feat(app): tint repo header + worktree subtitle by repo color/name"
```

---

### Task 4: Right-click repo menu (Rename… + Set Color/Remove Color) + wiring

**Files:**
- Modify: `Sources/Conductor/SidebarController.swift` (closures ~84-94; context actions ~134-151; `menuNeedsUpdate` ~219-255)
- Modify: `Sources/Conductor/AppDelegate.swift` (`wireSidebar` ~147-153; add `renameRepo` / `setRepoColor` handlers near `setWorktreeColor` ~156-166)

**Interfaces:**
- Consumes: `store.setRepositoryColor`, `store.setRepositoryDisplayName` (Task 2); `promptForText(prompt:defaultValue:)`, `refreshSidebar(select:)`, `IdentityPalette.colors`, `Self.swatchImage`, `clickedRepoID()`, `clickedWorktreeID()` (all existing).
- Produces: `SidebarController.onRenameRepo: ((String) -> Void)?`, `onSetRepoColor: ((String, String) -> Void)?`, `onRemoveRepoColor: ((String) -> Void)?`.

- [ ] **Step 1: Add the three closures**

In `SidebarController`, next to the existing `onSetWorktreeColor`/`onRemoveWorktreeColor` declarations (~92-94), add:

```swift
    /// Right-click a repo header → "Rename…" — set/clear the display-name override.
    var onRenameRepo: ((String) -> Void)?
    /// Right-click a repo header → "Set Color" swatch — apply a hex identity color.
    var onSetRepoColor: ((String, String) -> Void)?
    /// Right-click a repo header → "Remove Color" — clear the repo color.
    var onRemoveRepoColor: ((String) -> Void)?
```

- [ ] **Step 2: Add the context-action methods**

After `contextNewWorktree(_:)` (~151), add:

```swift
    @objc private func contextRenameRepo(_ sender: NSMenuItem) {
        (sender.representedObject as? String).map { onRenameRepo?($0) }
    }

    @objc private func contextSetRepoColor(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let id = info["id"], let hex = info["hex"] else { return }
        onSetRepoColor?(id, hex)
    }

    @objc private func contextRemoveRepoColor(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onRemoveRepoColor?(id)
    }
```

- [ ] **Step 3: Add the repo menu items (only when a repo header is clicked)**

In `menuNeedsUpdate(_:)`, after the existing `newWorktree` item is added (line ~231, before the `if let worktreeID = clickedWorktreeID()` block), insert:

```swift
        // Repo-header right-click (not a worktree row): rename + color the repository.
        if clickedWorktreeID() == nil {
            menu.addItem(.separator())
            let rename = NSMenuItem(title: "Rename…",
                                    action: #selector(contextRenameRepo(_:)), keyEquivalent: "")
            rename.target = self
            rename.representedObject = repoID
            menu.addItem(rename)

            let colorItem = NSMenuItem(title: "Set Color", action: nil, keyEquivalent: "")
            let colorMenu = NSMenu()
            for hex in IdentityPalette.colors {
                let swatch = NSMenuItem(title: hex, action: #selector(contextSetRepoColor(_:)), keyEquivalent: "")
                swatch.target = self
                swatch.representedObject = ["id": repoID, "hex": hex]
                if let color = NSColor(hex: hex) { swatch.image = Self.swatchImage(color) }
                colorMenu.addItem(swatch)
            }
            colorMenu.addItem(.separator())
            let removeColor = NSMenuItem(title: "Remove Color",
                                         action: #selector(contextRemoveRepoColor(_:)), keyEquivalent: "")
            removeColor.target = self
            removeColor.representedObject = repoID
            colorMenu.addItem(removeColor)
            colorItem.submenu = colorMenu
            menu.addItem(colorItem)
        }
```

> `repoID` is already bound at the top of `menuNeedsUpdate` via
> `guard let repoID = clickedRepoID() else { return }`. The existing worktree
> `Set Color` block (gated on `clickedWorktreeID()`) stays as-is below this.

- [ ] **Step 4: Wire the closures in AppDelegate**

In `wireSidebar()` (~147-153), append:

```swift
        sidebar.onRenameRepo = { [weak self] repoID in self?.renameRepo(repoID) }
        sidebar.onSetRepoColor = { [weak self] repoID, hex in self?.setRepoColor(repoID, hex) }
        sidebar.onRemoveRepoColor = { [weak self] repoID in self?.setRepoColor(repoID, nil) }
```

- [ ] **Step 5: Add the AppDelegate handlers**

After `setWorktreeColor(_:_:)` (~166), add:

```swift
    /// Display-only rename of a repository (blank input clears the override).
    private func renameRepo(_ repoID: String) {
        guard let repo = store.state.repositories.first(where: { $0.id == repoID }),
              let input = promptForText(prompt: "Repository name:", defaultValue: repo.sidebarDisplayName)
        else { return }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try store.setRepositoryDisplayName(id: repoID, displayName: trimmed.isEmpty ? nil : trimmed)
            refreshSidebar(select: selectedWorktree?.id)
        } catch { presentError(error) }
    }

    /// Set or clear a repository's identity color and repaint the sidebar.
    private func setRepoColor(_ repoID: String, _ hex: String?) {
        do {
            _ = try store.setRepositoryColor(id: repoID, color: hex)
            refreshSidebar(select: selectedWorktree?.id)
        } catch { presentError(error) }
    }
```

- [ ] **Step 6: Build and run the full suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | tail -5`
Expected: `Build complete!`
Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -8`
Expected: all tests pass (138 prior + 6 new = 144).

- [ ] **Step 7: In-app verification (manual)**

Run the app. Right-click a repo header → **Rename…** (prefilled with current name; change it → header + worktree subtitles update; blank it → reverts to folder name). Right-click → **Set Color** → pick a swatch (header text + the repo portion of each worktree subtitle tint to that color). **Remove Color** → back to gray. Worktree right-click still shows its own Set Color (unchanged).

- [ ] **Step 8: Commit**

```bash
git add Sources/Conductor/SidebarController.swift Sources/Conductor/AppDelegate.swift
git commit -m "feat(app): right-click repo Rename + Set/Remove Color"
```

---

## Self-Review

**Spec coverage:**
- Data model (`displayName`, `color`, `decodeIfPresent`, `sidebarDisplayName`) → Task 1. ✅
- Store setters supporting clear → Task 2 (per-field setters; supersedes `String??`). ✅
- Repo header tint + display name → Task 3 Step 1. ✅
- Worktree subtitle cascade (repo portion tinted) → Task 3 Step 2. ✅
- Right-click Rename… (blank clears) + Set Color/Remove Color → Task 4. ✅
- Wiring via closures → Task 4 Steps 4-5. ✅
- Tests (decode back-compat, round-trip, sidebarDisplayName, store set/clear) → Tasks 1-2. ✅
- Non-goal "no on-disk rename" → renameRepo only calls `setRepositoryDisplayName` (no git/FS). ✅
- Non-goal "no auto color" → no `IdentityPalette` auto-assign added for repos. ✅

**Placeholder scan:** No TBD/TODO; every code step shows full code. ✅

**Type consistency:** `setRepositoryColor(id:color:)` / `setRepositoryDisplayName(id:displayName:)` used identically in Tasks 2 & 4; closures `onRenameRepo`/`onSetRepoColor`/`onRemoveRepoColor` declared (Task 4 Step 1), invoked in actions (Step 2), assigned in `wireSidebar` (Step 4); `sidebarDisplayName` defined Task 1, used Tasks 3-4. ✅

**Known minor:** recoloring a repo while a *repo header* (not a worktree) is selected may drop that selection on reload, since `refreshSidebar(select:)` reselects by worktree id only — acceptable and consistent with the existing `setWorktreeColor` flow.
