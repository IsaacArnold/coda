# Branch Picker & Stash Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a toolbar-triggered branch picker with search/filter, local+remote branches, checkout switching, and integrated stash management.

**Architecture:** Extend `GitWorktree` with branch listing, checkout, stash, and dirty-check methods. Add `Branch` and `Stash` value types to `Models.swift`. Build a floating `BranchPickerPanel` (NSPanel + NSVisualEffectView, following the `CompletionPopupView` pattern). Wire via a new toolbar cluster button in `AppDelegate`.

**Tech Stack:** Swift, AppKit (NSPanel, NSVisualEffectView, NSTableView, NSToolbar), git CLI via ProcessRunner.

**Spec:** `docs/superpowers/specs/2026-08-23-branch-picker-design.md`

## Global Constraints

- macOS 13+ deployment target (existing project floor)
- All git operations via `GitWorktree` → `ProcessRunner.run` (synchronous, no async)
- Tests use real temporary git repos (`makeTempRepo()` helper), no mocks
- `CodaCore` stays AppKit-free; all UI in `Coda` target
- Build must pass: `swift build` with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`

---

### Task 1: Data Models — `Branch` and `Stash` types

**Files:**
- Modify: `Sources/CodaCore/Models.swift` (append after `RootRef`, before the private extension)
- Test: `Tests/CodaCoreTests/BranchStashTests.swift` (new file)

**Interfaces:**
- Produces: `Branch` struct (name: String, isRemote: Bool, isHead: Bool, remoteName: String?, shortName: String) — used by Task 2's `branches(repo:)` return type and Task 4's UI
- Produces: `Stash` struct (id: Int, message: String, branch: String?) — used by Task 3's `stashList(repo:)` return type and Task 4's UI

- [ ] **Step 1: Write tests for Branch and Stash value types**

Create `Tests/CodaCoreTests/BranchStashTests.swift`:

```swift
import XCTest
@testable import CodaCore

final class BranchStashTests: XCTestCase {
    func testLocalBranchProperties() {
        let b = Branch(name: "main", isRemote: false, isHead: true, remoteName: nil)
        XCTAssertEqual(b.shortName, "main")
        XCTAssertTrue(b.isHead)
        XCTAssertFalse(b.isRemote)
        XCTAssertNil(b.remoteName)
    }

    func testRemoteBranchStripsOriginPrefix() {
        let b = Branch(name: "origin/feature-x", isRemote: true, isHead: false, remoteName: "origin")
        XCTAssertEqual(b.shortName, "feature-x")
        XCTAssertTrue(b.isRemote)
    }

    func testRemoteBranchWithMultiSlashName() {
        let b = Branch(name: "origin/fix/login-bug", isRemote: true, isHead: false, remoteName: "origin")
        XCTAssertEqual(b.shortName, "fix/login-bug")
    }

    func testStashIdentifiable() {
        let s = Stash(id: 0, message: "WIP on main: abc1234 some commit", branch: "main")
        XCTAssertEqual(s.id, 0)
        XCTAssertEqual(s.branch, "main")
    }

    func testStashEquality() {
        let a = Stash(id: 0, message: "WIP", branch: "main")
        let b = Stash(id: 0, message: "WIP", branch: "main")
        XCTAssertEqual(a, b)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path /tmp/coda-build --filter BranchStashTests 2>&1 | tail -20`
Expected: compilation errors — `Branch` and `Stash` not defined.

- [ ] **Step 3: Implement Branch and Stash types**

Add to `Sources/CodaCore/Models.swift`, after the `RootRef` type and before the private `String` extension:

```swift
public struct Branch: Equatable {
    public var name: String
    public var isRemote: Bool
    public var isHead: Bool
    public var remoteName: String?

    public var shortName: String {
        if let remote = remoteName, name.hasPrefix(remote + "/") {
            return String(name.dropFirst(remote.count + 1))
        }
        return name
    }

    public init(name: String, isRemote: Bool, isHead: Bool, remoteName: String?) {
        self.name = name
        self.isRemote = isRemote
        self.isHead = isHead
        self.remoteName = remoteName
    }
}

public struct Stash: Equatable, Identifiable {
    public var id: Int
    public var message: String
    public var branch: String?

    public init(id: Int, message: String, branch: String?) {
        self.id = id
        self.message = message
        self.branch = branch
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path /tmp/coda-build --filter BranchStashTests 2>&1 | tail -20`
Expected: all 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodaCore/Models.swift Tests/CodaCoreTests/BranchStashTests.swift
git commit -m "feat(models): add Branch and Stash value types for branch picker"
```

---

### Task 2: Git Operations — Branch Listing, Checkout, and Dirty Check

**Files:**
- Modify: `Sources/CodaCore/GitWorktree.swift` (add methods before the closing `}`)
- Test: `Tests/CodaCoreTests/BranchStashTests.swift` (append to existing file)

**Interfaces:**
- Consumes: `Branch` struct from Task 1
- Produces: `GitWorktree.branches(repo:) -> [Branch]` — called by Task 5's `toggleBranchPicker`
- Produces: `GitWorktree.checkout(repo:branch:)` — called by Task 4's branch selection handler
- Produces: `GitWorktree.hasUncommittedChanges(repo:) -> Bool` — called by Task 4's dirty-check flow

- [ ] **Step 1: Write tests for `branches(repo:)`**

Append to `Tests/CodaCoreTests/BranchStashTests.swift`:

```swift
final class GitBranchTests: XCTestCase {
    func testBranchesListsLocalBranches() throws {
        let repo = try makeTempRepo()
        let git = GitWorktree(gitPath: "/usr/bin/git")
        _ = try ProcessRunner.run("/usr/bin/git", ["-C", repo, "branch", "feature-a"], cwd: nil)
        let branches = try git.branches(repo: repo)
        let local = branches.filter { !$0.isRemote }
        XCTAssertEqual(Set(local.map(\.name)), ["main", "feature-a"])
        XCTAssertTrue(local.first(where: { $0.name == "main" })!.isHead)
        XCTAssertFalse(local.first(where: { $0.name == "feature-a" })!.isHead)
    }

    func testBranchesListsRemoteBranches() throws {
        let upstream = try makeTempRepo()
        _ = try ProcessRunner.run("/usr/bin/git", ["-C", upstream, "branch", "remote-feat"], cwd: nil)
        let clone = NSTemporaryDirectory() + "coda-clone-" + UUID().uuidString
        _ = try ProcessRunner.run("/usr/bin/git", ["clone", upstream, clone], cwd: nil)
        let git = GitWorktree(gitPath: "/usr/bin/git")
        let branches = try git.branches(repo: clone)
        let remote = branches.filter { $0.isRemote }
        XCTAssertTrue(remote.contains(where: { $0.shortName == "remote-feat" }))
    }

    func testBranchesDeduplicatesTrackedRemotes() throws {
        let upstream = try makeTempRepo()
        let clone = NSTemporaryDirectory() + "coda-clone-" + UUID().uuidString
        _ = try ProcessRunner.run("/usr/bin/git", ["clone", upstream, clone], cwd: nil)
        let git = GitWorktree(gitPath: "/usr/bin/git")
        let branches = try git.branches(repo: clone)
        // "main" exists locally and as origin/main — remote list should NOT include origin/main
        let remoteNames = branches.filter { $0.isRemote }.map(\.shortName)
        XCTAssertFalse(remoteNames.contains("main"))
    }

    func testBranchesStripsOriginHEAD() throws {
        let upstream = try makeTempRepo()
        let clone = NSTemporaryDirectory() + "coda-clone-" + UUID().uuidString
        _ = try ProcessRunner.run("/usr/bin/git", ["clone", upstream, clone], cwd: nil)
        let git = GitWorktree(gitPath: "/usr/bin/git")
        let branches = try git.branches(repo: clone)
        XCTAssertFalse(branches.contains(where: { $0.name.contains("HEAD") }))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path /tmp/coda-build --filter GitBranchTests 2>&1 | tail -20`
Expected: compilation error — `branches(repo:)` not defined.

- [ ] **Step 3: Implement `branches(repo:)`**

Add to `Sources/CodaCore/GitWorktree.swift`, before the closing `}` of the struct:

```swift
    /// All local + remote branches. Remote branches that have an identically-named local branch
    /// are excluded (they'd be duplicates in a picker). `origin/HEAD` is always excluded.
    public func branches(repo: String) throws -> [Branch] {
        let out = try git(repo, ["branch", "-a", "--format=%(refname:short) %(HEAD)"])
        let localNames = Set(
            try localBranches(repo: repo)
        )
        var result: [Branch] = []
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let isHead = trimmed.hasSuffix(" *")
            let name = isHead
                ? String(trimmed.dropLast(2)).trimmingCharacters(in: .whitespaces)
                : trimmed
            if name.contains("/HEAD") { continue }
            let isRemote = name.contains("/")
                && !localNames.contains(name)
            if isRemote {
                let slashIndex = name.firstIndex(of: "/")!
                let remoteName = String(name[name.startIndex..<slashIndex])
                let shortName = String(name[name.index(after: slashIndex)...])
                // Skip if a local branch with this short name already exists
                if localNames.contains(shortName) { continue }
                result.append(Branch(name: name, isRemote: true, isHead: false, remoteName: remoteName))
            } else {
                result.append(Branch(name: name, isRemote: false, isHead: isHead, remoteName: nil))
            }
        }
        return result
    }
```

- [ ] **Step 4: Run branch tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path /tmp/coda-build --filter GitBranchTests 2>&1 | tail -20`
Expected: all 4 tests pass.

- [ ] **Step 5: Write tests for `checkout(repo:branch:)` and `hasUncommittedChanges(repo:)`**

Append to `GitBranchTests` in `BranchStashTests.swift`:

```swift
    func testCheckoutSwitchesBranch() throws {
        let repo = try makeTempRepo()
        let git = GitWorktree(gitPath: "/usr/bin/git")
        _ = try ProcessRunner.run("/usr/bin/git", ["-C", repo, "branch", "feature-z"], cwd: nil)
        try git.checkout(repo: repo, branch: "feature-z")
        XCTAssertEqual(try git.currentBranch(repo: repo), "feature-z")
    }

    func testCheckoutRemoteBranchCreatesTrackingBranch() throws {
        let upstream = try makeTempRepo()
        _ = try ProcessRunner.run("/usr/bin/git", ["-C", upstream, "branch", "remote-only"], cwd: nil)
        let clone = NSTemporaryDirectory() + "coda-clone-" + UUID().uuidString
        _ = try ProcessRunner.run("/usr/bin/git", ["clone", upstream, clone], cwd: nil)
        let git = GitWorktree(gitPath: "/usr/bin/git")
        try git.checkout(repo: clone, branch: "remote-only")
        XCTAssertEqual(try git.currentBranch(repo: clone), "remote-only")
        XCTAssertTrue(try git.localBranches(repo: clone).contains("remote-only"))
    }

    func testCheckoutFailsOnBranchLockedByWorktree() throws {
        let repo = try makeTempRepo()
        let git = GitWorktree(gitPath: "/usr/bin/git")
        let wt = NSTemporaryDirectory() + "wt-lock-" + UUID().uuidString
        try git.add(repo: repo, path: wt, branch: "locked-branch", base: "main")
        XCTAssertThrowsError(try git.checkout(repo: repo, branch: "locked-branch"))
    }

    func testHasUncommittedChangesDetectsModifiedFiles() throws {
        let repo = try makeTempRepo()
        let git = GitWorktree(gitPath: "/usr/bin/git")
        XCTAssertFalse(try git.hasUncommittedChanges(repo: repo))
        try "modified".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        XCTAssertTrue(try git.hasUncommittedChanges(repo: repo))
    }

    func testHasUncommittedChangesDetectsUntrackedFiles() throws {
        let repo = try makeTempRepo()
        let git = GitWorktree(gitPath: "/usr/bin/git")
        try "new".write(toFile: repo + "/new.txt", atomically: true, encoding: .utf8)
        XCTAssertTrue(try git.hasUncommittedChanges(repo: repo))
    }

    func testHasUncommittedChangesDetectsStagedFiles() throws {
        let repo = try makeTempRepo()
        let git = GitWorktree(gitPath: "/usr/bin/git")
        try "staged".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run("/usr/bin/git", ["-C", repo, "add", "README.md"], cwd: nil)
        XCTAssertTrue(try git.hasUncommittedChanges(repo: repo))
    }
```

- [ ] **Step 6: Implement `checkout(repo:branch:)` and `hasUncommittedChanges(repo:)`**

Add to `Sources/CodaCore/GitWorktree.swift`, after `branches(repo:)`:

```swift
    /// Check out a branch. For a branch name that only exists as a remote tracking branch,
    /// git's `checkout` automatically creates a local tracking branch.
    public func checkout(repo: String, branch: String) throws {
        try git(repo, ["checkout", branch])
    }

    /// True if the working tree has any uncommitted changes (staged, unstaged, or untracked).
    public func hasUncommittedChanges(repo: String) throws -> Bool {
        let out = try git(repo, ["status", "--porcelain"])
        return !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
```

- [ ] **Step 7: Run all tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path /tmp/coda-build --filter 'GitBranchTests|BranchStashTests' 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/CodaCore/GitWorktree.swift Tests/CodaCoreTests/BranchStashTests.swift
git commit -m "feat(git): add branches(), checkout(), and hasUncommittedChanges()"
```

---

### Task 3: Git Operations — Stash Methods

**Files:**
- Modify: `Sources/CodaCore/GitWorktree.swift` (append stash methods)
- Test: `Tests/CodaCoreTests/BranchStashTests.swift` (append new test class)

**Interfaces:**
- Consumes: `Stash` struct from Task 1
- Produces: `GitWorktree.stashList(repo:) -> [Stash]` — called by Task 5
- Produces: `GitWorktree.stashSave(repo:message:)` — called by Task 4's stash-and-switch flow
- Produces: `GitWorktree.stashPop(repo:index:)` — called by Task 4's stash UI
- Produces: `GitWorktree.stashApply(repo:index:)` — called by Task 4's stash UI
- Produces: `GitWorktree.stashDrop(repo:index:)` — called by Task 4's stash UI

- [ ] **Step 1: Write tests for stash operations**

Append to `Tests/CodaCoreTests/BranchStashTests.swift`:

```swift
final class GitStashTests: XCTestCase {
    func testStashListEmptyOnCleanRepo() throws {
        let repo = try makeTempRepo()
        let git = GitWorktree(gitPath: "/usr/bin/git")
        XCTAssertEqual(try git.stashList(repo: repo), [])
    }

    func testStashSaveAndListRoundTrip() throws {
        let repo = try makeTempRepo()
        let git = GitWorktree(gitPath: "/usr/bin/git")
        try "dirty".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        try git.stashSave(repo: repo, message: "test stash")
        let stashes = try git.stashList(repo: repo)
        XCTAssertEqual(stashes.count, 1)
        XCTAssertEqual(stashes[0].id, 0)
        XCTAssertTrue(stashes[0].message.contains("test stash"))
        // Working tree should be clean after stash
        XCTAssertFalse(try git.hasUncommittedChanges(repo: repo))
    }

    func testStashSaveIncludesUntrackedFiles() throws {
        let repo = try makeTempRepo()
        let git = GitWorktree(gitPath: "/usr/bin/git")
        try "new file".write(toFile: repo + "/untracked.txt", atomically: true, encoding: .utf8)
        try git.stashSave(repo: repo, message: "with untracked")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo + "/untracked.txt"))
        XCTAssertEqual(try git.stashList(repo: repo).count, 1)
    }

    func testStashPopRestoresChanges() throws {
        let repo = try makeTempRepo()
        let git = GitWorktree(gitPath: "/usr/bin/git")
        try "dirty".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        try git.stashSave(repo: repo, message: "pop test")
        try git.stashPop(repo: repo, index: 0)
        XCTAssertTrue(try git.hasUncommittedChanges(repo: repo))
        XCTAssertEqual(try git.stashList(repo: repo).count, 0)
    }

    func testStashApplyRestoresButKeepsStash() throws {
        let repo = try makeTempRepo()
        let git = GitWorktree(gitPath: "/usr/bin/git")
        try "dirty".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        try git.stashSave(repo: repo, message: "apply test")
        try git.stashApply(repo: repo, index: 0)
        XCTAssertTrue(try git.hasUncommittedChanges(repo: repo))
        XCTAssertEqual(try git.stashList(repo: repo).count, 1)
    }

    func testStashDropRemovesStash() throws {
        let repo = try makeTempRepo()
        let git = GitWorktree(gitPath: "/usr/bin/git")
        try "dirty".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        try git.stashSave(repo: repo, message: "drop test")
        try git.stashDrop(repo: repo, index: 0)
        XCTAssertEqual(try git.stashList(repo: repo).count, 0)
    }

    func testStashListParsesMultipleStashes() throws {
        let repo = try makeTempRepo()
        let git = GitWorktree(gitPath: "/usr/bin/git")
        try "first".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        try git.stashSave(repo: repo, message: "first stash")
        try "second".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        try git.stashSave(repo: repo, message: "second stash")
        let stashes = try git.stashList(repo: repo)
        XCTAssertEqual(stashes.count, 2)
        XCTAssertEqual(stashes[0].id, 0)
        XCTAssertEqual(stashes[1].id, 1)
        XCTAssertTrue(stashes[0].message.contains("second stash"))
        XCTAssertTrue(stashes[1].message.contains("first stash"))
    }

    func testStashListParsesBranchFromMessage() throws {
        let repo = try makeTempRepo()
        let git = GitWorktree(gitPath: "/usr/bin/git")
        try "dirty".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        try git.stashSave(repo: repo, message: "my changes")
        let stashes = try git.stashList(repo: repo)
        XCTAssertEqual(stashes[0].branch, "main")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path /tmp/coda-build --filter GitStashTests 2>&1 | tail -20`
Expected: compilation error — stash methods not defined.

- [ ] **Step 3: Implement stash methods**

Add to `Sources/CodaCore/GitWorktree.swift`, after `hasUncommittedChanges(repo:)`:

```swift
    /// List all stashes. Parses `git stash list` output into `[Stash]`.
    /// The default stash message format is "On <branch>: <message>" for custom messages
    /// and "WIP on <branch>: <sha> <commit msg>" for default stash push.
    public func stashList(repo: String) throws -> [Stash] {
        let (out, _) = try gitAllowingFailure(repo, ["stash", "list", "--format=%gd||%gs"])
        guard !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return out.split(separator: "\n").compactMap { line -> Stash? in
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 3 else { return nil }
            let refPart = String(parts[0])
            guard let openBrace = refPart.firstIndex(of: "{"),
                  let closeBrace = refPart.firstIndex(of: "}"),
                  let index = Int(refPart[refPart.index(after: openBrace)..<closeBrace]) else { return nil }
            let messagePart = String(parts[2])
            // Parse branch from "On <branch>: ..." or "WIP on <branch>: ..."
            let branch: String? = {
                let patterns = ["On ", "WIP on "]
                for prefix in patterns {
                    if messagePart.hasPrefix(prefix),
                       let colonIndex = messagePart.firstIndex(of: ":") {
                        let start = messagePart.index(messagePart.startIndex, offsetBy: prefix.count)
                        return String(messagePart[start..<colonIndex])
                    }
                }
                return nil
            }()
            return Stash(id: index, message: messagePart, branch: branch)
        }
    }

    /// Stash uncommitted changes (including untracked files).
    public func stashSave(repo: String, message: String) throws {
        try git(repo, ["stash", "push", "-u", "-m", message])
    }

    /// Pop (apply + drop) a stash by index.
    public func stashPop(repo: String, index: Int) throws {
        try git(repo, ["stash", "pop", "stash@{\(index)}"])
    }

    /// Apply a stash by index (keeps it in the stash list).
    public func stashApply(repo: String, index: Int) throws {
        try git(repo, ["stash", "apply", "stash@{\(index)}"])
    }

    /// Drop a stash by index.
    public func stashDrop(repo: String, index: Int) throws {
        try git(repo, ["stash", "drop", "stash@{\(index)}"])
    }
```

- [ ] **Step 4: Run stash tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path /tmp/coda-build --filter GitStashTests 2>&1 | tail -20`
Expected: all 8 tests pass.

- [ ] **Step 5: Run full test suite to check for regressions**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path /tmp/coda-build 2>&1 | tail -30`
Expected: all existing tests still pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/CodaCore/GitWorktree.swift Tests/CodaCoreTests/BranchStashTests.swift
git commit -m "feat(git): add stash list/save/pop/apply/drop operations"
```

---

### Task 4: Branch Picker Panel UI

**Files:**
- Create: `Sources/Coda/BranchPickerPanel.swift`

**Interfaces:**
- Consumes: `Branch` struct from Task 1 (displayed in table rows)
- Consumes: `Stash` struct from Task 1 (displayed in stash bar)
- Produces: `BranchPickerPanel` class — instantiated by Task 5's `toggleBranchPicker`
- Produces: `BranchPickerPanel.onCheckout: ((Branch) -> Void)?` — wired by Task 5
- Produces: `BranchPickerPanel.onStashAction: ((StashAction) -> Void)?` — wired by Task 5
- Produces: `BranchPickerPanel.showConfirmation(message:onConfirm:)` — called by Task 5 on dirty tree
- Produces: `BranchPickerPanel.showError(_:)` — called by Task 5 on git failure
- Produces: `BranchPickerPanel.show(relativeTo:branches:stashes:)` — called by Task 5
- Produces: `BranchPickerPanel.dismiss()` — called by Task 5

- [ ] **Step 1: Create the panel file with the StashAction enum and BranchPickerPanel shell**

Create `Sources/Coda/BranchPickerPanel.swift` with the panel window, visual effect background, and search field:

```swift
import AppKit
import CodaCore

enum StashAction {
    case apply(Int)
    case pop(Int)
    case drop(Int)
}

final class BranchPickerPanel: NSPanel {
    var onCheckout: ((Branch) -> Void)?
    var onStashAction: ((StashAction) -> Void)?

    private let effectView = NSVisualEffectView()
    private let searchField = NSTextField()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let stashBar = NSView()
    private let stashDisclosure = NSButton()
    private let stashLabel = NSTextField(labelWithString: "")
    private let stashListView = NSStackView()
    private let errorLabel = NSTextField(labelWithString: "")
    private let confirmationView = NSView()
    private let confirmLabel = NSTextField(labelWithString: "")
    private let confirmButton = NSButton()
    private let cancelButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: "No branches")

    private var allBranches: [Branch] = []
    private var filteredBranches: [Branch] = []
    private var stashes: [Stash] = []
    private var stashExpanded = false

    static let panelWidth: CGFloat = 300
    static let maxPanelHeight: CGFloat = 400
    static let rowHeight: CGFloat = 24
    static let sectionHeaderHeight: CGFloat = 20
    static let searchFieldHeight: CGFloat = 28
    static let stashBarHeight: CGFloat = 32
    static let cornerRadius: CGFloat = 8

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing bufferingType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: [.nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        hidesOnDeactivate = false

        let content = NSView(frame: contentRect)
        contentView = content

        effectView.material = .menu
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = Self.cornerRadius
        effectView.layer?.masksToBounds = true
        effectView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(effectView)

        setupSearchField(in: content)
        setupTableView(in: content)
        setupStashBar(in: content)
        setupConfirmationView(in: content)
        setupErrorLabel(in: content)
        setupEmptyLabel(in: content)
        layoutSubviews(in: content)
    }

    // MARK: - Setup

    private func setupSearchField(in container: NSView) {
        searchField.placeholderString = "Filter branches..."
        searchField.isBordered = false
        searchField.focusRingType = .none
        searchField.drawsBackground = false
        searchField.font = .systemFont(ofSize: NSFont.systemFontSize)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(searchChanged)
        container.addSubview(searchField)
    }

    private func setupTableView(in container: NSView) {
        let column = NSTableColumn(identifier: .init("branch"))
        column.title = ""
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.doubleAction = #selector(tableDoubleClicked)
        tableView.target = self
        tableView.delegate = self
        tableView.dataSource = self

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
    }

    private func setupStashBar(in container: NSView) {
        stashBar.translatesAutoresizingMaskIntoConstraints = false
        stashBar.isHidden = true

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        stashBar.addSubview(separator)

        stashDisclosure.bezelStyle = .disclosure
        stashDisclosure.title = ""
        stashDisclosure.state = .off
        stashDisclosure.target = self
        stashDisclosure.action = #selector(toggleStashExpansion)
        stashDisclosure.translatesAutoresizingMaskIntoConstraints = false
        stashBar.addSubview(stashDisclosure)

        stashLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stashLabel.textColor = .secondaryLabelColor
        stashLabel.translatesAutoresizingMaskIntoConstraints = false
        stashBar.addSubview(stashLabel)

        stashListView.orientation = .vertical
        stashListView.spacing = 2
        stashListView.translatesAutoresizingMaskIntoConstraints = false
        stashListView.isHidden = true
        stashBar.addSubview(stashListView)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: stashBar.topAnchor),
            separator.leadingAnchor.constraint(equalTo: stashBar.leadingAnchor, constant: 8),
            separator.trailingAnchor.constraint(equalTo: stashBar.trailingAnchor, constant: -8),
            stashDisclosure.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            stashDisclosure.leadingAnchor.constraint(equalTo: stashBar.leadingAnchor, constant: 8),
            stashLabel.centerYAnchor.constraint(equalTo: stashDisclosure.centerYAnchor),
            stashLabel.leadingAnchor.constraint(equalTo: stashDisclosure.trailingAnchor, constant: 4),
            stashListView.topAnchor.constraint(equalTo: stashDisclosure.bottomAnchor, constant: 4),
            stashListView.leadingAnchor.constraint(equalTo: stashBar.leadingAnchor, constant: 8),
            stashListView.trailingAnchor.constraint(equalTo: stashBar.trailingAnchor, constant: -8),
            stashListView.bottomAnchor.constraint(equalTo: stashBar.bottomAnchor, constant: -4),
        ])

        container.addSubview(stashBar)
    }

    private func setupConfirmationView(in container: NSView) {
        confirmationView.translatesAutoresizingMaskIntoConstraints = false
        confirmationView.isHidden = true
        confirmationView.wantsLayer = true
        confirmationView.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.9).cgColor
        confirmationView.layer?.cornerRadius = 6

        confirmLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        confirmLabel.textColor = .labelColor
        confirmLabel.lineBreakMode = .byWordWrapping
        confirmLabel.maximumNumberOfLines = 3
        confirmLabel.translatesAutoresizingMaskIntoConstraints = false
        confirmationView.addSubview(confirmLabel)

        confirmButton.title = "Stash & Switch"
        confirmButton.bezelStyle = .rounded
        confirmButton.controlSize = .small
        confirmButton.target = self
        confirmButton.action = #selector(confirmClicked)
        confirmButton.translatesAutoresizingMaskIntoConstraints = false
        confirmationView.addSubview(confirmButton)

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        confirmationView.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            confirmLabel.topAnchor.constraint(equalTo: confirmationView.topAnchor, constant: 8),
            confirmLabel.leadingAnchor.constraint(equalTo: confirmationView.leadingAnchor, constant: 12),
            confirmLabel.trailingAnchor.constraint(equalTo: confirmationView.trailingAnchor, constant: -12),
            confirmButton.topAnchor.constraint(equalTo: confirmLabel.bottomAnchor, constant: 8),
            confirmButton.trailingAnchor.constraint(equalTo: confirmationView.trailingAnchor, constant: -12),
            confirmButton.bottomAnchor.constraint(equalTo: confirmationView.bottomAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: confirmButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: confirmButton.leadingAnchor, constant: -8),
        ])

        container.addSubview(confirmationView)
    }

    private func setupErrorLabel(in container: NSView) {
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(errorLabel)
    }

    private func setupEmptyLabel(in container: NSView) {
        emptyLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)
    }

    private func layoutSubviews(in container: NSView) {
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: container.topAnchor),
            effectView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            effectView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            searchField.heightAnchor.constraint(equalToConstant: Self.searchFieldHeight),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            stashBar.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stashBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stashBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stashBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            errorLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            errorLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            errorLabel.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -4),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            confirmationView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            confirmationView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            confirmationView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -8),
        ])
    }

    // MARK: - Public API

    func show(relativeTo button: NSView, branches: [Branch], stashes: [Stash]) {
        self.allBranches = branches
        self.stashes = stashes
        self.stashExpanded = false
        stashDisclosure.state = .off
        stashListView.isHidden = true
        confirmationView.isHidden = true
        errorLabel.isHidden = true
        searchField.stringValue = ""
        applyFilter()
        updateStashBar()
        updatePanelSize()

        guard let buttonWindow = button.window,
              let screen = buttonWindow.screen else { return }
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)
        let origin = NSPoint(x: screenRect.minX, y: screenRect.minY - frame.height - 4)
        let clamped = NSPoint(
            x: min(origin.x, screen.visibleFrame.maxX - frame.width),
            y: max(origin.y, screen.visibleFrame.minY)
        )
        setFrameOrigin(clamped)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(searchField)
    }

    func dismiss() {
        orderOut(nil)
    }

    func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.errorLabel.isHidden = true
        }
    }

    private var pendingConfirmAction: (() -> Void)?

    func showConfirmation(message: String, onConfirm: @escaping () -> Void) {
        confirmLabel.stringValue = message
        pendingConfirmAction = onConfirm
        confirmationView.isHidden = false
    }

    func updateStashes(_ stashes: [Stash]) {
        self.stashes = stashes
        updateStashBar()
        if stashExpanded { rebuildStashList() }
        updatePanelSize()
    }

    // MARK: - Internal

    private func applyFilter() {
        let query = searchField.stringValue.lowercased()
        if query.isEmpty {
            filteredBranches = allBranches
        } else {
            filteredBranches = allBranches.filter {
                $0.shortName.lowercased().contains(query)
            }
        }
        emptyLabel.isHidden = !filteredBranches.isEmpty
        tableView.reloadData()
    }

    private var localBranches: [Branch] { filteredBranches.filter { !$0.isRemote } }
    private var remoteBranches: [Branch] { filteredBranches.filter { $0.isRemote } }

    private func updateStashBar() {
        stashBar.isHidden = stashes.isEmpty
        stashLabel.stringValue = stashes.count == 1 ? "1 stash" : "\(stashes.count) stashes"
    }

    private func rebuildStashList() {
        stashListView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for stash in stashes {
            let row = makeStashRow(stash)
            stashListView.addArrangedSubview(row)
        }
    }

    private func makeStashRow(_ stash: Stash) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 4

        let label = NSTextField(labelWithString: "stash@{\(stash.id)}: \(stash.message)")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let applyBtn = makeSmallButton("Apply") { [weak self] in
            self?.onStashAction?(.apply(stash.id))
        }
        let popBtn = makeSmallButton("Pop") { [weak self] in
            self?.onStashAction?(.pop(stash.id))
        }
        let dropBtn = makeSmallButton("Drop") { [weak self] in
            self?.onStashAction?(.drop(stash.id))
        }

        row.addArrangedSubview(label)
        row.addArrangedSubview(applyBtn)
        row.addArrangedSubview(popBtn)
        row.addArrangedSubview(dropBtn)
        return row
    }

    private func makeSmallButton(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = CallbackButton(title: title, action: action)
        button.controlSize = .mini
        button.bezelStyle = .recessed
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return button
    }

    private func updatePanelSize() {
        let branchCount = filteredBranches.count
        let sectionCount = (localBranches.isEmpty ? 0 : 1) + (remoteBranches.isEmpty ? 0 : 1)
        let tableHeight = CGFloat(branchCount) * Self.rowHeight
            + CGFloat(sectionCount) * Self.sectionHeaderHeight
        let stashHeight: CGFloat = stashes.isEmpty ? 0 : (stashExpanded
            ? Self.stashBarHeight + CGFloat(stashes.count) * 24 + 8
            : Self.stashBarHeight)
        let totalHeight = Self.searchFieldHeight + 12 + min(tableHeight, Self.maxPanelHeight - Self.searchFieldHeight - 12 - stashHeight) + stashHeight
        let clampedHeight = min(max(totalHeight, 80), Self.maxPanelHeight)
        var frame = self.frame
        let heightDelta = clampedHeight - frame.height
        frame.origin.y -= heightDelta
        frame.size.height = clampedHeight
        frame.size.width = Self.panelWidth
        setFrame(frame, display: true)
    }

    // MARK: - Actions

    @objc private func searchChanged() { applyFilter() }

    @objc private func tableDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, let branch = branchForRow(row) else { return }
        onCheckout?(branch)
    }

    @objc private func toggleStashExpansion() {
        stashExpanded.toggle()
        stashDisclosure.state = stashExpanded ? .on : .off
        stashListView.isHidden = !stashExpanded
        if stashExpanded { rebuildStashList() }
        updatePanelSize()
    }

    @objc private func confirmClicked() {
        confirmationView.isHidden = true
        pendingConfirmAction?()
        pendingConfirmAction = nil
    }

    @objc private func cancelClicked() {
        confirmationView.isHidden = true
        pendingConfirmAction = nil
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }

    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    // MARK: - Table helpers

    private enum SectionType { case local, remote }

    private struct TableItem {
        enum Kind { case sectionHeader(String), branch(Branch) }
        let kind: Kind
    }

    private var tableItems: [TableItem] {
        var items: [TableItem] = []
        let local = localBranches
        let remote = remoteBranches
        if !local.isEmpty {
            items.append(TableItem(kind: .sectionHeader("Local")))
            items += local.map { TableItem(kind: .branch($0)) }
        }
        if !remote.isEmpty {
            items.append(TableItem(kind: .sectionHeader("Remote")))
            items += remote.map { TableItem(kind: .branch($0)) }
        }
        return items
    }

    private func branchForRow(_ row: Int) -> Branch? {
        let items = tableItems
        guard items.indices.contains(row) else { return nil }
        if case .branch(let b) = items[row].kind { return b }
        return nil
    }
}

// MARK: - NSTableViewDataSource & NSTableViewDelegate

extension BranchPickerPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { tableItems.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let items = tableItems
        guard items.indices.contains(row) else { return nil }
        switch items[row].kind {
        case .sectionHeader(let title):
            let cell = NSTextField(labelWithString: title)
            cell.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            cell.textColor = .secondaryLabelColor
            return cell
        case .branch(let branch):
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.spacing = 6
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 8)
            let checkmark = NSTextField(labelWithString: branch.isHead ? "✓" : "")
            checkmark.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            checkmark.textColor = .controlAccentColor
            checkmark.widthAnchor.constraint(equalToConstant: 14).isActive = true
            let nameLabel = NSTextField(labelWithString: branch.shortName)
            nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
            nameLabel.textColor = .labelColor
            nameLabel.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(checkmark)
            stack.addArrangedSubview(nameLabel)
            return stack
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let items = tableItems
        guard items.indices.contains(row) else { return Self.rowHeight }
        if case .sectionHeader = items[row].kind { return Self.sectionHeaderHeight }
        return Self.rowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .sectionHeader = tableItems[row].kind { return false }
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, let branch = branchForRow(row) else { return }
        onCheckout?(branch)
    }
}

// MARK: - CallbackButton (small helper for stash action buttons)

private final class CallbackButton: NSButton {
    private var callback: (() -> Void)?

    convenience init(title: String, action: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.callback = action
        self.target = self
        self.action = #selector(clicked)
    }

    @objc private func clicked() { callback?() }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --build-path /tmp/coda-build 2>&1 | tail -20`
Expected: build succeeds with no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/Coda/BranchPickerPanel.swift
git commit -m "feat(ui): add BranchPickerPanel — floating branch switcher with search and stash bar"
```

---

### Task 5: Toolbar Integration & Wiring

**Files:**
- Modify: `Sources/Coda/AppDelegate.swift`

**Interfaces:**
- Consumes: `BranchPickerPanel` from Task 4
- Consumes: `GitWorktree.branches(repo:)` from Task 2
- Consumes: `GitWorktree.checkout(repo:branch:)` from Task 2
- Consumes: `GitWorktree.hasUncommittedChanges(repo:)` from Task 2
- Consumes: `GitWorktree.stashList(repo:)` from Task 3
- Consumes: `GitWorktree.stashSave(repo:message:)` from Task 3
- Consumes: `GitWorktree.stashPop(repo:index:)` from Task 3
- Consumes: `GitWorktree.stashApply(repo:index:)` from Task 3
- Consumes: `GitWorktree.stashDrop(repo:index:)` from Task 3

- [ ] **Step 1: Add the `.branchPicker` toolbar item identifier**

In `Sources/Coda/AppDelegate.swift`, in the `NSToolbarItem.Identifier` private extension (around line 2026), add:

```swift
    static let branchPicker = NSToolbarItem.Identifier("branchPicker")
```

- [ ] **Step 2: Add the branch picker property and button ref**

In `AppDelegate`'s property declarations (around line 78, near the other `weak var` toolbar refs), add:

```swift
    private var branchPickerPanel: BranchPickerPanel?
    private weak var branchPickerButton: NSButton?
    private weak var branchLabel: NSTextField?
```

- [ ] **Step 3: Add branchPicker to toolbar layout**

In `toolbarDefaultItemIdentifiers(_:)` (around line 2040), change the return to:

```swift
        [.leftCluster,
         .flexibleSpace, .notch, .flexibleSpace,
         .branchPicker, .rightCluster, .openIn]
```

Also update `toolbarAllowedItemIdentifiers` if it's separate (it calls `toolbarDefaultItemIdentifiers` so it picks it up automatically).

- [ ] **Step 4: Add the branchPicker toolbar item in `toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)`**

Add a new `case .branchPicker:` in the switch statement, before `case .rightCluster:`:

```swift
        case .branchPicker:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = ""
            let icon = clusterButton(
                symbolName: "arrow.triangle.branch", tooltip: "Switch Branch",
                target: self, action: #selector(toggleBranchPicker(_:)))
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.isBordered = false
            label.isEditable = false
            label.drawsBackground = false
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 120).isActive = true
            branchLabel = label
            branchPickerButton = icon
            let stack = NSStackView(views: [icon, label])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 4
            stack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
            item.view = stack
            return item
```

- [ ] **Step 5: Add the `toggleBranchPicker` action method**

Add a new method in `AppDelegate` (near other `@objc` action methods):

```swift
    @objc private func toggleBranchPicker(_ sender: Any?) {
        if let panel = branchPickerPanel, panel.isVisible {
            panel.dismiss()
            return
        }

        guard let repo = selectedRepo() else { return }
        let git = store.git

        let branches: [Branch]
        let stashes: [Stash]
        do {
            branches = try git.branches(repo: repo.path)
            stashes = try git.stashList(repo: repo.path)
        } catch {
            return
        }

        let panel = BranchPickerPanel(
            contentRect: NSRect(x: 0, y: 0, width: BranchPickerPanel.panelWidth, height: 200),
            styleMask: [], backing: .buffered, defer: true)
        self.branchPickerPanel = panel

        panel.onCheckout = { [weak self] branch in
            self?.handleBranchCheckout(branch, repo: repo)
        }

        panel.onStashAction = { [weak self] action in
            self?.handleStashAction(action, repo: repo)
        }

        guard let button = branchPickerButton else { return }
        panel.show(relativeTo: button, branches: branches, stashes: stashes)
    }

    private func handleBranchCheckout(_ branch: Branch, repo: Repository) {
        let git = store.git
        do {
            let dirty = try git.hasUncommittedChanges(repo: repo.path)
            if dirty {
                branchPickerPanel?.showConfirmation(
                    message: "Uncommitted changes. Stash and switch?",
                    onConfirm: { [weak self] in
                        do {
                            try git.stashSave(repo: repo.path, message: "Auto-stash before switching to \(branch.shortName)")
                            try git.checkout(repo: repo.path, branch: branch.isRemote ? branch.shortName : branch.name)
                            self?.branchPickerPanel?.dismiss()
                        } catch let error {
                            self?.branchPickerPanel?.showError(error.localizedDescription)
                        }
                    })
            } else {
                try git.checkout(repo: repo.path, branch: branch.isRemote ? branch.shortName : branch.name)
                branchPickerPanel?.dismiss()
            }
        } catch {
            branchPickerPanel?.showError(error.localizedDescription)
        }
    }

    private func handleStashAction(_ action: StashAction, repo: Repository) {
        let git = store.git
        do {
            switch action {
            case .apply(let index): try git.stashApply(repo: repo.path, index: index)
            case .pop(let index): try git.stashPop(repo: repo.path, index: index)
            case .drop(let index): try git.stashDrop(repo: repo.path, index: index)
            }
            let stashes = try git.stashList(repo: repo.path)
            branchPickerPanel?.updateStashes(stashes)
        } catch {
            branchPickerPanel?.showError(error.localizedDescription)
        }
    }
```

- [ ] **Step 6: Expose `git` on WorktreeStore (if not already public)**

Check if `store.git` is accessible. If `git` is private on `WorktreeStore`, add a public accessor. In `Sources/CodaCore/WorktreeStore.swift`, if `git` is private:

```swift
    // Change:
    private let git: GitWorktree
    // To:
    public let git: GitWorktree
```

- [ ] **Step 7: Add a `selectedRepo()` helper if one doesn't exist**

Check if `AppDelegate` already has a way to get the currently selected repo. If not, add:

```swift
    private func selectedRepo() -> Repository? {
        guard let wt = selectedWorktree else { return nil }
        return store.state.repositories.first(where: { $0.id == wt.repoID })
    }
```

- [ ] **Step 8: Update the branch label in the toolbar when HEAD changes**

Find where `HeadWatcher.onChange` is wired (the handler that already updates `currentBranches` and refreshes the sidebar). Add to that handler:

```swift
        // Update toolbar branch label
        if let wt = selectedWorktree, wt.repoID == repoID,
           let branch = currentBranches[repoID] {
            branchLabel?.stringValue = branch
        }
```

Also update the branch label when a worktree is selected. In the `select(_:focusTerminal:)` method or wherever `selectedWorktree` is set, add:

```swift
        branchLabel?.stringValue = selectedWorktree?.branch ?? ""
```

And set `branchPickerButton?.isEnabled` based on whether a repo is selected.

- [ ] **Step 9: Verify it compiles**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --build-path /tmp/coda-build 2>&1 | tail -20`
Expected: build succeeds.

- [ ] **Step 10: Run full test suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path /tmp/coda-build 2>&1 | tail -30`
Expected: all tests pass, no regressions.

- [ ] **Step 11: Commit**

```bash
git add Sources/Coda/AppDelegate.swift Sources/CodaCore/WorktreeStore.swift
git commit -m "feat(toolbar): wire branch picker button and checkout/stash handlers"
```

---

### Task 6: Manual Verification

**Files:** None (verification only)

- [ ] **Step 1: Build and run the app**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --build-path /tmp/coda-build 2>&1 | tail -10`

Then launch: open the built `.app` or run the binary directly.

- [ ] **Step 2: Verify toolbar button appears**

- Add a repo with multiple branches
- Confirm the branch icon + label appear in the toolbar between the flexible space and the Claude button
- Confirm the label shows the current branch name
- Confirm the button is disabled when no repo is selected

- [ ] **Step 3: Verify branch picker opens and lists branches**

- Click the toolbar button
- Confirm the floating panel appears below the button
- Confirm local branches appear under a "Local" header
- Confirm remote branches appear under a "Remote" header (if the repo has a remote)
- Confirm the current branch has a checkmark

- [ ] **Step 4: Verify search/filter**

- Type in the search field
- Confirm both local and remote branch lists filter
- Clear the search, confirm all branches reappear

- [ ] **Step 5: Verify branch switching**

- Click a different local branch
- Confirm the panel dismisses
- Confirm the sidebar and WorktreeBar update to show the new branch
- Confirm the toolbar label updates

- [ ] **Step 6: Verify dirty-tree stash-and-switch**

- Make an uncommitted change in the terminal
- Click the branch picker and select a different branch
- Confirm the "Uncommitted changes. Stash and switch?" confirmation appears
- Click "Stash & Switch"
- Confirm the branch switches and the stash appears in the stash bar

- [ ] **Step 7: Verify stash management**

- Open the branch picker with stashes present
- Confirm the stash bar shows "N stashes"
- Click the disclosure to expand
- Click "Apply" on a stash — confirm changes are applied, stash stays in list
- Click "Pop" on a stash — confirm changes are applied, stash is removed
- Click "Drop" on a stash — confirm stash is removed without applying

- [ ] **Step 8: Verify error states**

- If possible, try switching to a branch locked by a worktree — confirm error message appears
- Try pressing Escape — confirm panel dismisses
- Click outside the panel — confirm it dismisses

- [ ] **Step 9: Verify detached HEAD**

- In terminal, `git checkout --detach`
- Confirm toolbar label shows the short SHA or "(detached)"
- Open picker — confirm no checkmark on any branch
- Select a branch to reattach

- [ ] **Step 10: Commit any fixes found during verification**

If any issues are found and fixed during manual verification:

```bash
git add -A
git commit -m "fix(branch-picker): address issues found during manual verification"
```
