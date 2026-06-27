# Repo Main-Checkout Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a registered repo's own checkout a first-class, always-present session (so you never have to create a `git worktree` to start working), with its branch tracked live, plus a Remove-Repository path.

**Architecture:** The repo's main checkout becomes a *synthesized, never-persisted* `Worktree` (`isMain` flag, `worktreePath == repo.path`, derived id `"<repoID>#main"`), produced by a pure Core function that prepends one per repo to the sidebar sections. A shell-side `HeadWatcher` watches each repo's `.git/HEAD` and refreshes the branch label in place. The entire existing surface/tab/split/badge stack is reused because the main checkout is just another `Worktree` to the surface registry.

**Tech Stack:** Swift 6 (SwiftPM), AppKit, SwiftTerm, XCTest. Pure decision logic in `ConductorCore`; thin AppKit in `Conductor`.

## Global Constraints

- **Every** `swift build` / `swift run` / `swift test` MUST be prefixed `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (Command Line Tools ship no XCTest; this also pins the toolchain to Swift 6.2.3 to avoid stale-`.swiftmodule` errors). If you hit `module compiled with Swift 6.3.2 cannot be imported…`, run `rm -rf .build` and rebuild through the prefix.
- Tests are **XCTest**, not Swift Testing.
- `swift test` builds the **whole package** including the `Conductor` app target — so the app MUST compile after every Core task, not just `ConductorCore`.
- Only `ConductorCore` is unit-tested (`.testTarget(name: "ConductorCoreTests", dependencies: ["ConductorCore"])`). App-target types (`HeadWatcher`, `AppDelegate`) are verified by **build + in-app manual** checks, not unit tests.
- SourceKit/editor diagnostics give FALSE "cannot find type" alarms on freshly-added types; `swift build` is the source of truth.
- Identity colors are CHROME-ONLY; never tint the terminal grid.

---

### Task 1: `Worktree.isMain` flag + `mainCheckout` factory

**Files:**
- Modify: `Sources/ConductorCore/Models.swift` (the `Worktree` struct, lines 50–78)
- Test: `Tests/ConductorCoreTests/ModelsCodableTests.swift` (add cases)

**Interfaces:**
- Produces: `Worktree.isMain: Bool` (stored, default `false`, excluded from `CodingKeys` → never persisted); `static func Worktree.mainCheckout(for: Repository, branch: String) -> Worktree` (sets `id = "\(repo.id)#main"`, `repoID = repo.id`, `title = "Default"`, `worktreePath = repo.path`, `color = nil`, `isMain = true`).

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ConductorCoreTests/ModelsCodableTests.swift` (inside the existing `final class ModelsCodableTests: XCTestCase`):

```swift
func testWorktreeIsMainDefaultsFalseAndIsNotPersisted() throws {
    // A synthesized main worktree carries isMain == true in memory…
    let repo = Repository(id: "R1", path: "/tmp/acme", name: "acme")
    let main = Worktree.mainCheckout(for: repo, branch: "main")
    XCTAssertTrue(main.isMain)
    XCTAssertEqual(main.id, "R1#main")
    XCTAssertEqual(main.repoID, "R1")
    XCTAssertEqual(main.title, "Default")
    XCTAssertEqual(main.worktreePath, "/tmp/acme")
    XCTAssertEqual(main.branch, "main")

    // …but isMain is in-memory only: it must not survive a JSON round-trip, and the
    // encoded JSON must not even contain the key.
    let data = try JSONEncoder().encode(main)
    let json = String(decoding: data, as: UTF8.self)
    XCTAssertFalse(json.contains("isMain"), "isMain leaked into persisted JSON")
    let decoded = try JSONDecoder().decode(Worktree.self, from: data)
    XCTAssertFalse(decoded.isMain, "isMain should decode to false (not persisted)")
}

func testNormalWorktreeIsNotMain() {
    let wt = Worktree(id: "W1", repoID: "R1", title: "Feature", branch: "feat",
                      worktreePath: "/tmp/wt/feat")
    XCTAssertFalse(wt.isMain)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ModelsCodableTests`
Expected: FAIL — `value of type 'Worktree' has no member 'isMain'` / `type 'Worktree' has no member 'mainCheckout'`.

- [ ] **Step 3: Add the `isMain` stored property**

In `Sources/ConductorCore/Models.swift`, add the property to `Worktree` directly after `public var color: String?` (line 58):

```swift
    /// True only for the synthesized repo main-checkout worktree (working dir == repo dir).
    /// In-memory only — absent from `CodingKeys`, so it never persists and always decodes false.
    public var isMain: Bool = false
```

No change is needed to the existing memberwise `init` or the custom `init(from:)`: `isMain` has a default value, and `CodingKeys` already omits it (so both encode and the custom decode skip it).

- [ ] **Step 4: Add the `mainCheckout` factory**

In `Sources/ConductorCore/Models.swift`, append after the `Worktree` struct's closing brace (after line 78):

```swift
extension Worktree {
    /// The synthesized "main checkout" worktree for a repo: its working dir IS the repo dir.
    /// Never persisted (identified by `isMain`); id derived from the repo so surfaces persist
    /// within a session and the derived chrome color is stable.
    public static func mainCheckout(for repo: Repository, branch: String) -> Worktree {
        var wt = Worktree(id: "\(repo.id)#main", repoID: repo.id, title: "Default",
                          branch: branch, worktreePath: repo.path, color: nil)
        wt.isMain = true
        return wt
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ModelsCodableTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/ConductorCore/Models.swift Tests/ConductorCoreTests/ModelsCodableTests.swift
git commit -m "feat(core): Worktree.isMain flag + mainCheckout factory (in-memory only)"
```

---

### Task 2: `sectionsWithMainCheckouts` (prepend the main checkout per repo)

**Files:**
- Modify: `Sources/ConductorCore/WorktreeGrouping.swift`
- Test: `Tests/ConductorCoreTests/WorktreeGroupingTests.swift`

**Interfaces:**
- Consumes: `Worktree.mainCheckout(for:branch:)` (Task 1); existing `RepositorySection`.
- Produces: `func sectionsWithMainCheckouts(repositories: [Repository], worktrees: [Worktree], branchForRepo: [String: String]) -> [RepositorySection]` — for each repo (order preserved), a section whose `worktrees` are `[synthesized main] + repo's real worktrees`. Branch comes from `branchForRepo[repo.id] ?? ""`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ConductorCoreTests/WorktreeGroupingTests.swift`:

```swift
func testMainCheckoutIsPrependedPerRepo() {
    let r1 = Repository(id: "R1", path: "/tmp/r1", name: "r1")
    let r2 = Repository(id: "R2", path: "/tmp/r2", name: "r2")
    let w = Worktree(id: "W1", repoID: "R1", title: "Feat", branch: "feat",
                     worktreePath: "/tmp/wt/feat")
    let sections = sectionsWithMainCheckouts(
        repositories: [r1, r2], worktrees: [w],
        branchForRepo: ["R1": "main", "R2": "develop"])

    XCTAssertEqual(sections.count, 2)
    // R1: main checkout first, then the real worktree.
    XCTAssertEqual(sections[0].worktrees.map(\.id), ["R1#main", "W1"])
    XCTAssertTrue(sections[0].worktrees[0].isMain)
    XCTAssertEqual(sections[0].worktrees[0].branch, "main")
    XCTAssertEqual(sections[0].worktrees[0].title, "Default")
    XCTAssertFalse(sections[0].worktrees[1].isMain)
    // R2: only its main checkout (no real worktrees), with its own branch.
    XCTAssertEqual(sections[1].worktrees.map(\.id), ["R2#main"])
    XCTAssertEqual(sections[1].worktrees[0].branch, "develop")
}

func testMainCheckoutBranchFallsBackToEmptyWhenUnknown() {
    let r1 = Repository(id: "R1", path: "/tmp/r1", name: "r1")
    let sections = sectionsWithMainCheckouts(
        repositories: [r1], worktrees: [], branchForRepo: [:])
    XCTAssertEqual(sections[0].worktrees.count, 1)
    XCTAssertEqual(sections[0].worktrees[0].branch, "")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter WorktreeGroupingTests`
Expected: FAIL — `cannot find 'sectionsWithMainCheckouts' in scope`.

- [ ] **Step 3: Implement the function**

Append to `Sources/ConductorCore/WorktreeGrouping.swift`:

```swift
/// Like `groupWorktreesByRepository`, but prepends each repo's synthesized "main checkout"
/// worktree (the repo's own working dir, current branch) above its real worktrees. This is
/// what the sidebar consumes: every repo always has at least the main-checkout row.
public func sectionsWithMainCheckouts(repositories: [Repository],
                                      worktrees: [Worktree],
                                      branchForRepo: [String: String]) -> [RepositorySection] {
    repositories.map { repo in
        let main = Worktree.mainCheckout(for: repo, branch: branchForRepo[repo.id] ?? "")
        let real = worktrees.filter { $0.repoID == repo.id }
        return RepositorySection(repository: repo, worktrees: [main] + real)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter WorktreeGroupingTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ConductorCore/WorktreeGrouping.swift Tests/ConductorCoreTests/WorktreeGroupingTests.swift
git commit -m "feat(core): sectionsWithMainCheckouts prepends repo main checkout"
```

---

### Task 3: `WorktreeStore.removeRepository` + `currentBranch(repoID:)` + detached-HEAD short SHA

**Files:**
- Modify: `Sources/ConductorCore/WorktreeStore.swift`
- Modify: `Sources/ConductorCore/GitWorktree.swift` (add `shortHead`)
- Test: `Tests/ConductorCoreTests/WorktreeStoreTests.swift`, `Tests/ConductorCoreTests/GitWorktreeTests.swift`

**Interfaces:**
- Consumes: existing `GitWorktree.currentBranch(repo:)`; `WorktreeStoreError`.
- Produces:
  - `GitWorktree.shortHead(repo:) throws -> String` — `git rev-parse --short HEAD`, trimmed.
  - `WorktreeStore.currentBranch(repoID:) throws -> String` — looks up the repo, returns its current branch; if git reports `"HEAD"` (detached), returns the short SHA instead.
  - `WorktreeStore.removeRepository(id:) throws -> [Worktree]` — removes the repo and all its worktrees from `state`, saves config, returns the removed worktrees. **Never** touches git/disk.

- [ ] **Step 1: Write the failing store tests**

Add to `Tests/ConductorCoreTests/WorktreeStoreTests.swift`:

```swift
func testRemoveRepositoryForgetsRepoAndWorktreesButLeavesDiskIntact() throws {
    let repoPath = try makeTempRepo()
    let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
    let r = try store.addRepository(path: repoPath)
    let wt = try store.createWorktree(repoID: r.id, title: "Keep On Disk")

    let removed = try store.removeRepository(id: r.id)

    // Returned the worktree so the shell can evict its surfaces.
    XCTAssertEqual(removed.map(\.id), [wt.id])
    // Forgotten in memory + on-disk config.
    XCTAssertFalse(store.state.repositories.contains { $0.id == r.id })
    XCTAssertFalse(store.state.worktrees.contains { $0.repoID == r.id })
    XCTAssertFalse(cfg.load().repositories.contains { $0.id == r.id })
    XCTAssertFalse(cfg.load().worktrees.contains { $0.repoID == r.id })
    // Disk untouched: the repo dir and the worktree dir both still exist.
    XCTAssertTrue(FileManager.default.fileExists(atPath: repoPath))
    XCTAssertTrue(FileManager.default.fileExists(atPath: wt.worktreePath))
}

func testRemoveRepositoryUnknownIDThrows() {
    let (store, _) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
    XCTAssertThrowsError(try store.removeRepository(id: "nope"))
}

func testCurrentBranchReturnsRepoBranch() throws {
    let repoPath = try makeTempRepo()
    let (store, _) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
    let r = try store.addRepository(path: repoPath)
    // makeTempRepo() initializes on the default branch; just assert it's non-empty and not "HEAD".
    let branch = try store.currentBranch(repoID: r.id)
    XCTAssertFalse(branch.isEmpty)
    XCTAssertNotEqual(branch, "HEAD")
}

func testCurrentBranchUnknownIDThrows() {
    let (store, _) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
    XCTAssertThrowsError(try store.currentBranch(repoID: "nope"))
}
```

- [ ] **Step 2: Write the failing GitWorktree test**

Add to `Tests/ConductorCoreTests/GitWorktreeTests.swift`:

```swift
func testShortHeadReturnsAbbreviatedSHA() throws {
    let repo = try makeTempRepo()
    let git = GitWorktree(gitPath: "/usr/bin/git")
    let sha = try git.shortHead(repo: repo)
    XCTAssertFalse(sha.isEmpty)
    // A short SHA is hex and reasonably short (git defaults to ~7 chars).
    XCTAssertLessThanOrEqual(sha.count, 40)
    XCTAssertTrue(sha.allSatisfy { $0.isHexDigit })
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter WorktreeStoreTests`
Then: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GitWorktreeTests`
Expected: FAIL — `has no member 'removeRepository'` / `'currentBranch(repoID:)'` / `'shortHead'`.

- [ ] **Step 4: Add `GitWorktree.shortHead`**

In `Sources/ConductorCore/GitWorktree.swift`, add directly after `currentBranch(repo:)` (after line ~30):

```swift
    /// The abbreviated SHA of HEAD (used to label a detached-HEAD checkout).
    public func shortHead(repo: String) throws -> String {
        try git(repo, ["rev-parse", "--short", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
```

- [ ] **Step 5: Add store `currentBranch(repoID:)` and `removeRepository(id:)`**

In `Sources/ConductorCore/WorktreeStore.swift`, add these methods (e.g. after `updateRepository`, before `createWorktree`):

```swift
    /// The current branch of a repo's main checkout, for the synthesized main-checkout label.
    /// Falls back to the short SHA when HEAD is detached (`rev-parse --abbrev-ref` returns "HEAD").
    public func currentBranch(repoID: String) throws -> String {
        guard let repo = state.repositories.first(where: { $0.id == repoID }) else {
            throw WorktreeStoreError.repoNotFound(repoID)
        }
        let branch = try git.currentBranch(repo: repo.path)
        if branch == "HEAD" { return (try? git.shortHead(repo: repo.path)) ?? branch }
        return branch
    }

    /// Forget a repository: removes it and all its worktrees from local state and persists.
    /// Returns the removed worktrees so the shell can evict their surfaces. NEVER deletes any
    /// branch, worktree directory, or repo on disk — this is purely a Conductor-side forget.
    @discardableResult
    public func removeRepository(id: String) throws -> [Worktree] {
        guard let idx = state.repositories.firstIndex(where: { $0.id == id }) else {
            throw WorktreeStoreError.repoNotFound(id)
        }
        let removed = state.worktrees.filter { $0.repoID == id }
        state.repositories.remove(at: idx)
        state.worktrees.removeAll { $0.repoID == id }
        try config.save(state)
        return removed
    }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter WorktreeStoreTests`
Then: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GitWorktreeTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/ConductorCore/WorktreeStore.swift Sources/ConductorCore/GitWorktree.swift Tests/ConductorCoreTests/WorktreeStoreTests.swift Tests/ConductorCoreTests/GitWorktreeTests.swift
git commit -m "feat(core): removeRepository + currentBranch(repoID:) with detached-HEAD short SHA"
```

---

### Task 4: `HeadWatcher` — live `.git/HEAD` file watcher

**Files:**
- Create: `Sources/Conductor/HeadWatcher.swift`

**Interfaces:**
- Produces (app target):
  - `final class HeadWatcher`
  - `var onChange: ((String) -> Void)?` — fired on the **main** queue with the affected `repoID`.
  - `func watch(repoID: String, repoPath: String)` — (re)start watching `<repoPath>/.git/HEAD`.
  - `func unwatch(repoID: String)`
  - `func unwatchAll()`

This is app-target code (not unit-tested); verified by build + the in-app branch-switch test in Task 7.

- [ ] **Step 1: Create the file**

Create `Sources/Conductor/HeadWatcher.swift`:

```swift
import Foundation

/// Watches each registered repo's `.git/HEAD` and calls `onChange(repoID)` (on the main queue)
/// when the checked-out branch changes — e.g. an external `git checkout`. git rewrites HEAD via
/// an atomic rename, which invalidates the original file descriptor, so the source re-arms itself
/// on every delete/rename event.
final class HeadWatcher {
    /// Called on the main queue with the repoID whose HEAD changed.
    var onChange: ((String) -> Void)?

    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var paths: [String: String] = [:]
    private let queue = DispatchQueue(label: "conductor.headwatcher")

    /// Start (or restart) watching a repo's HEAD. Call on the main thread.
    func watch(repoID: String, repoPath: String) {
        unwatch(repoID: repoID)
        paths[repoID] = repoPath
        arm(repoID)
    }

    /// Stop watching a repo. Call on the main thread.
    func unwatch(repoID: String) {
        paths[repoID] = nil
        sources[repoID]?.cancel()
        sources[repoID] = nil
    }

    func unwatchAll() {
        for id in Array(paths.keys) { unwatch(repoID: id) }
    }

    private func arm(_ repoID: String) {
        guard let repoPath = paths[repoID] else { return }
        let headPath = (repoPath as NSString).appendingPathComponent(".git/HEAD")
        let fd = open(headPath, O_EVTONLY)
        guard fd >= 0 else { return }   // no .git/HEAD (e.g. a non-git folder): silently skip
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend], queue: queue)
        src.setEventHandler { [weak self] in
            let needsRearm = src.data.contains(.delete) || src.data.contains(.rename)
            DispatchQueue.main.async {
                guard let self, self.paths[repoID] != nil else { return }
                self.onChange?(repoID)
                if needsRearm {
                    // The watched inode was replaced; cancel (closes fd) and re-open the new one.
                    self.sources[repoID]?.cancel()
                    self.sources[repoID] = nil
                    self.arm(repoID)
                }
            }
        }
        src.setCancelHandler { close(fd) }
        sources[repoID] = src
        src.resume()
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: Build complete (no errors).

- [ ] **Step 3: Commit**

```bash
git add Sources/Conductor/HeadWatcher.swift
git commit -m "feat(app): HeadWatcher — re-arming .git/HEAD file watcher"
```

---

### Task 5: Wire main checkouts into the sidebar + startup + add-repo

**Files:**
- Modify: `Sources/Conductor/AppDelegate.swift`

**Interfaces:**
- Consumes: `sectionsWithMainCheckouts(...)` (Task 2); `store.currentBranch(repoID:)`, `store.removeRepository` (Task 3, removeRepository used in Task 6); `HeadWatcher` (Task 4).
- Produces (private AppDelegate members used by Task 6): `currentBranches: [String: String]`; `headWatcher: HeadWatcher`; `displaySections() -> [RepositorySection]`; `allDisplayWorktrees() -> [Worktree]`; `displayWorktree(id: String?) -> Worktree?`; `seedBranchesAndWatchers()`.

- [ ] **Step 1: Add the branch map, watcher, and display helpers**

In `Sources/Conductor/AppDelegate.swift`, add stored properties near `selectedWorktree` (line 14):

```swift
    /// repoID → current branch of its main checkout, kept fresh by `headWatcher`.
    private var currentBranches: [String: String] = [:]
    private let headWatcher = HeadWatcher()
```

Add these helpers next to `refreshSidebar` (replace the two existing `refreshSidebar` methods at lines 205–217 and add the helpers):

```swift
    /// Sidebar sections WITH each repo's synthesized main-checkout row prepended.
    private func displaySections() -> [RepositorySection] {
        sectionsWithMainCheckouts(repositories: store.state.repositories,
                                  worktrees: store.state.worktrees,
                                  branchForRepo: currentBranches)
    }

    /// Every worktree the sidebar shows — synthesized main checkouts + real worktrees.
    private func allDisplayWorktrees() -> [Worktree] {
        displaySections().flatMap { $0.worktrees }
    }

    /// Look up a display worktree (incl. a synthesized main checkout) by id.
    private func displayWorktree(id: String?) -> Worktree? {
        guard let id else { return nil }
        return allDisplayWorktrees().first { $0.id == id }
    }

    private func refreshSidebar(select id: String?) {
        sidebar.reload(sections: displaySections(), selectedWorktreeID: id)
    }

    /// Refresh and highlight a repository header (used by add-repo before a row exists).
    private func refreshSidebar(selectRepo id: String?) {
        sidebar.reload(sections: displaySections(), selectedWorktreeID: nil, selectedRepoID: id)
    }

    /// Read each repo's current branch and start a HEAD watcher for it (call once at launch).
    private func seedBranchesAndWatchers() {
        headWatcher.onChange = { [weak self] repoID in
            guard let self else { return }
            self.currentBranches[repoID] = try? self.store.currentBranch(repoID: repoID)
            self.refreshSidebar(select: self.shownWorktreeID)
        }
        for repo in store.state.repositories {
            currentBranches[repo.id] = try? store.currentBranch(repoID: repo.id)
            headWatcher.watch(repoID: repo.id, repoPath: repo.path)
        }
    }
```

- [ ] **Step 2: Seed at launch and select the first main checkout**

In `applicationDidFinishLaunching` replace line 50 (`refreshSidebar(select: store.state.worktrees.first?.id)`) with:

```swift
        seedBranchesAndWatchers()
        refreshSidebar(select: allDisplayWorktrees().first?.id)
```

(The programmatic row selection inside `sidebar.reload` fires `onSelect`, which calls `select(_:)` with the synthesized main-checkout `Worktree`, spawning its shell in the repo dir.)

- [ ] **Step 3: On add-repo, seed + watch + select the new repo's main checkout**

Replace the body of `addRepo()` (lines 311–324) `do { … } catch { … }` block with:

```swift
        do {
            let repo = try store.addRepository(path: url.path)
            currentBranches[repo.id] = try? store.currentBranch(repoID: repo.id)
            headWatcher.watch(repoID: repo.id, repoPath: repo.path)
            let mainID = "\(repo.id)#main"
            refreshSidebar(select: mainID)
            select(displayWorktree(id: mainID))
        }
        catch { presentError(error) }
```

- [ ] **Step 4: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: Build complete.

- [ ] **Step 5: Manual smoke test**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run`
Verify: launching with an existing repo shows a **"Default"** row (subtitle `repo · <branch>`) under each repo, auto-selected with a live shell in the repo dir. Add a new repo → its "Default" row appears and is selected with a shell. In a terminal outside the app, `cd` into that repo and run `git switch -c scratch-test` → the sidebar subtitle updates to `… · scratch-test` in place (no new row). Switch back: `git switch -` → it reverts. Quit the app.

- [ ] **Step 6: Commit**

```bash
git add Sources/Conductor/AppDelegate.swift
git commit -m "feat(app): repo main-checkout sessions in sidebar + live HEAD branch tracking"
```

---

### Task 6: Remove Repository + main-checkout menu/archive guards

**Files:**
- Modify: `Sources/Conductor/SidebarController.swift`
- Modify: `Sources/Conductor/AppDelegate.swift`

**Interfaces:**
- Consumes: `store.removeRepository(id:)` (Task 3); `surfaces.evict(worktreeID:)`; `currentBranches`, `headWatcher`, `displayWorktree`, `allDisplayWorktrees` (Task 5).
- Produces: `SidebarController.onRemoveRepo: ((String) -> Void)?`; a "Remove Repository…" repo-header menu item; main-checkout rows omit the per-row Set-Color submenu; main checkout can't be archived.

- [ ] **Step 1: SidebarController — callback, clicked-worktree accessor, menu wiring**

In `Sources/Conductor/SidebarController.swift`:

(a) Add the callback near the other repo callbacks (after line 101):

```swift
    /// Right-click a repo header → "Remove Repository…" — forget the repo (no disk changes).
    var onRemoveRepo: ((String) -> Void)?
```

(b) Add an accessor + action next to `clickedWorktreeID()` (after line 148) and the other context actions:

```swift
    /// The worktree the right-clicked row represents, or nil if a repo header was clicked.
    private func clickedWorktree() -> Worktree? {
        let row = outline.clickedRow
        guard row >= 0, let wt = outline.item(atRow: row) as? WorktreeNode else { return nil }
        return wt.worktree
    }

    @objc private func contextRemoveRepo(_ sender: NSMenuItem) {
        (sender.representedObject as? String).map { onRemoveRepo?($0) }
    }
```

(c) In `menuNeedsUpdate(_:)`, add the Remove Repository item inside the repo-header branch (`if clickedWorktreeID() == nil { … }`), after the `ColorMenu.makeSetColorItem(...)` call (after line 265):

```swift
            menu.addItem(.separator())
            let remove = NSMenuItem(title: "Remove Repository…",
                                    action: #selector(contextRemoveRepo(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = repoID
            menu.addItem(remove)
```

(d) Gate the per-worktree Set-Color submenu off for main-checkout rows. Replace the final `if let worktreeID = clickedWorktreeID() { … }` block (lines 268–274) with:

```swift
        if let worktreeID = clickedWorktreeID(), clickedWorktree()?.isMain == false {
            menu.addItem(.separator())
            menu.addItem(ColorMenu.makeSetColorItem(
                targetID: worktreeID, target: self,
                setColor: #selector(contextSetColor(_:)),
                removeColor: #selector(contextRemoveColor(_:))))
        }
```

- [ ] **Step 2: Build (SidebarController only so far) to catch errors early**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: FAIL is acceptable here only if it's the `onRemoveRepo` not-yet-wired warning being unused — but it should BUILD (an unset optional closure is fine). If it errors, fix before continuing.

- [ ] **Step 3: AppDelegate — a surface-teardown helper (DRY with archive)**

In `Sources/Conductor/AppDelegate.swift`, add a private helper (near `archive`, ~line 344):

```swift
    /// Tear down a surface's panes + views (kills every PTY). Used by archive and repo removal.
    private func tearDown(_ split: SplitSurface) {
        split.allPanes.forEach { $0.view.removeFromSuperview(); $0.removeFromParent() }
        split.view.removeFromSuperview()
        split.removeFromParent()
    }
```

Then in `archive(_:)` replace the eviction loop body (lines 356–360) to use it:

```swift
            for split in surfaces.evict(worktreeID: s.id) { tearDown(split) }
```

- [ ] **Step 4: AppDelegate — wire the callback + implement `removeRepo`**

(a) In `wireSidebar()` next to the other sidebar closures (after line 166), add:

```swift
        sidebar.onRemoveRepo = { [weak self] repoID in self?.removeRepo(repoID) }
```

(b) Add the `removeRepo` method (near `addRepo`):

```swift
    /// Forget a repository (no disk changes): confirm, remove from the store, evict every
    /// surface for the repo's worktrees + its main checkout, stop its HEAD watcher.
    private func removeRepo(_ repoID: String) {
        guard let repo = store.state.repositories.first(where: { $0.id == repoID }) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove “\(repo.sidebarDisplayName)”?"
        alert.informativeText = "Conductor will forget this repository and its worktrees. "
            + "Your files, branches, and worktree directories are left untouched on disk."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let removed = try store.removeRepository(id: repoID)
            var evictIDs = removed.map { $0.id }
            evictIDs.append("\(repoID)#main")
            for id in evictIDs {
                for split in surfaces.evict(worktreeID: id) { tearDown(split) }
            }
            headWatcher.unwatch(repoID: repoID)
            currentBranches[repoID] = nil
            if let shown = shownWorktreeID, evictIDs.contains(shown) {
                shownWorktreeID = nil
                currentSurface = nil
                selectedWorktree = nil
            }
            refreshSidebar(select: allDisplayWorktrees().first?.id)
            select(allDisplayWorktrees().first)
        } catch { presentError(error) }
    }
```

- [ ] **Step 5: AppDelegate — block Archive for the main checkout**

In `archiveSelectedAction()` (line 878), add an `isMain` guard right after the `selectedWorktree` guard:

```swift
    @objc private func archiveSelectedAction() {
        guard let wt = selectedWorktree else { presentMessage("Select a worktree first."); return }
        if wt.isMain {
            presentMessage("The main checkout can’t be archived. Use Remove Repository to forget the repo.")
            return
        }
        archive(wt)
    }
```

(Leave the rest of the method as-is; only the guard is inserted. If `archiveSelectedAction` currently calls `archive(wt)` differently, preserve that call.)

- [ ] **Step 6: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: Build complete.

- [ ] **Step 7: Run the full Core suite (nothing regressed)**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: All tests PASS (prior count + the new Task 1–3 tests).

- [ ] **Step 8: Manual verification**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run`
Verify:
- Right-click a main-checkout ("Default") row → **no** "Set Color" submenu; right-click a real worktree → Set Color is present.
- Right-click a repo header → "Remove Repository…" present → confirm dialog → on Remove, the repo + all its rows disappear, and (in a separate terminal) `git worktree list` in the repo still shows everything; the repo dir + any worktree dirs are still on disk.
- Select a "Default" row, then menu **Archive** (or its shortcut) → shows the "can't be archived" message; the repo is untouched.
- Open a couple of tabs / a split in a main checkout, switch to another worktree and back → surfaces persist; a busy command lights the tab + sidebar badge.
- Quit.

- [ ] **Step 9: Commit**

```bash
git add Sources/Conductor/SidebarController.swift Sources/Conductor/AppDelegate.swift
git commit -m "feat(app): Remove Repository + main-checkout archive/color guards"
```

---

### Task 7: Stop watchers on terminate + update DECISIONS.md

**Files:**
- Modify: `Sources/Conductor/AppDelegate.swift`
- Modify: `DECISIONS.md`

- [ ] **Step 1: Tear down watchers on app termination**

In `Sources/Conductor/AppDelegate.swift`, ensure `applicationWillTerminate` (add it if absent) calls:

```swift
    func applicationWillTerminate(_ notification: Notification) {
        headWatcher.unwatchAll()
    }
```

If an `applicationWillTerminate` already exists, add the `headWatcher.unwatchAll()` line into it.

- [ ] **Step 2: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: Build complete.

- [ ] **Step 3: Update DECISIONS.md**

In `DECISIONS.md`, under the "Phase 1.5 — Multi-surface" section, replace the **Scratch (worktree-less) tabs** bullet (line ~144) with a note that scratch was superseded, and record the new piece. Replace that bullet with:

```markdown
- **Repo main-checkout sessions** *(supersedes the originally-planned scratch tabs, 2026-06-27)* — the repo's own checkout is a first-class, always-present session (synthesized never-persisted main `Worktree`, `worktreePath == repo.path`, live `.git/HEAD` branch tracking), so you never have to create a `git worktree` to start working. Includes Remove Repository (forgets the repo, no disk changes). Spec: `docs/superpowers/specs/2026-06-27-conductor-main-checkout-design.md`; plan: `docs/superpowers/plans/2026-06-27-conductor-main-checkout.md`. **Scratch (worktree-less, repo-less) terminals remain deferred** — `Surface.kind = .scratch` seam stays reserved, revisited after living with main-checkout sessions.
```

- [ ] **Step 4: Commit**

```bash
git add Sources/Conductor/AppDelegate.swift DECISIONS.md
git commit -m "feat(app): stop HEAD watchers on terminate; docs(decisions): main-checkout supersedes scratch"
```

---

## Self-Review

**Spec coverage:**
- Synthesized `isMain` main worktree, never persisted, derived id, title "Default" → Task 1. ✓
- Section builder prepending main per repo, branch fallback → Task 2. ✓
- `removeRepository` (returns removed, no disk side-effects) + detached-HEAD short SHA → Task 3. ✓
- `.git/HEAD` live watcher with re-arm-on-rename → Task 4. ✓
- Shell wiring: branch map, displaySections, startup auto-select main, add-repo seed/watch/select, in-place branch refresh → Task 5. ✓
- Lifecycle: main not archivable; Remove Repository menu + evict surfaces + stop watcher; main rows omit Set Color → Task 6. ✓
- Surfaces/tabs/splits/badges reused (no code change needed — registry keys by worktree id, poll walks `surfaces.worktreeIDs`) → verified in Task 5/6 manual steps. ✓
- Shell spawns in `repo.path`, no setup-script/copy-allowlist, never auto-launches Claude: the main checkout is never in `pendingSetupWorktreeIDs`, so `createSurface`'s `isNewlyCreated` is false → `setup == ""`, `command == ""`. No code change needed; `makePane` uses `wt.worktreePath` which == `repo.path` for the main checkout. ✓
- Watcher teardown on quit + DECISIONS.md update → Task 7. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code. ✓

**Type consistency:** `isMain`, `mainCheckout(for:branch:)`, `sectionsWithMainCheckouts(repositories:worktrees:branchForRepo:)`, `currentBranch(repoID:)`, `removeRepository(id:)`, `shortHead(repo:)`, `HeadWatcher.watch(repoID:repoPath:)/unwatch(repoID:)/unwatchAll()/onChange`, derived id `"<repoID>#main"`, and `displaySections()/allDisplayWorktrees()/displayWorktree(id:)` are used identically across tasks. ✓

**Note for the implementer:** line numbers in this plan are from the pre-change files and will drift as you edit — match on the quoted surrounding code, not the line number.
