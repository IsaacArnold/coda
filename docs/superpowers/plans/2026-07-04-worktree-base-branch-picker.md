# Worktree Base-Branch Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user see and choose which local branch a new worktree forks from, instead of silently using the repo's current `HEAD`.

**Architecture:** Keep the existing pure-core / AppKit-glue split. Add a branch-listing git command and a `base` parameter to worktree creation in `CodaCore` (unit-tested); add a two-field dialog (title + base-branch popup) in `Coda` and thread the chosen base through. The base is optional end-to-end so all existing callers and tests keep working unchanged (`nil` = current `HEAD`, today's behavior).

**Tech Stack:** Swift 6 toolchain (language mode v5), SwiftPM, AppKit (`NSAlert` / `NSPopUpButton` / `NSStackView`), XCTest. Git via `/usr/bin/git` through `ProcessRunner`.

## Global Constraints

- **Toolchain (critical):** every `swift` command must be prefixed with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. `swift test` builds the whole package (including the `Coda` app target), so the app must compile after every task.
- **Pure-core split:** all git/path/decision logic lives in `Sources/CodaCore/` with XCTest coverage in `Tests/CodaCoreTests/`; AppKit/dialog glue lives in `Sources/Coda/`.
- **SourceKit caveat:** Coda↔CodaCore edits can throw phantom stale "cannot find type / no member / extra argument" diagnostics — trust `swift build`, not the editor diagnostics.
- **Backward compatibility:** the new `base` parameter on `createWorktree` MUST default to `nil` and preserve current-`HEAD` behavior, so the existing 10+ call sites (all in tests, plus `AppDelegate`) compile and pass unchanged.
- **Scope:** local branches only. No remote-tracking branches, no arbitrary commit-ish/tag/SHA. Spec: `docs/superpowers/specs/2026-07-04-worktree-base-branch-picker-design.md`.

---

### Task 1: List local branches (`CodaCore`, pure)

Adds the git command that enumerates a repo's local branches, used to populate the picker.

**Files:**
- Modify: `Sources/CodaCore/GitWorktree.swift` (add method after `list`, ~line 81)
- Test: `Tests/CodaCoreTests/GitWorktreeTests.swift` (add one test)

**Interfaces:**
- Consumes: existing private `git(_ repo:_ args:)` helper, `GitWorktree(gitPath:)`.
- Produces: `func localBranches(repo: String) throws -> [String]` — trimmed, non-empty local branch names in git's default (alphabetical) order.

- [ ] **Step 1: Write the failing test**

Add to `Tests/CodaCoreTests/GitWorktreeTests.swift`, inside the `GitWorktreeTests` class:

```swift
    func testLocalBranchesListsEveryLocalBranch() throws {
        let repo = try makeTempRepo()   // starts with branch "main"
        _ = try ProcessRunner.run("/usr/bin/git", ["-C", repo, "branch", "feature-a"], cwd: nil)
        _ = try ProcessRunner.run("/usr/bin/git", ["-C", repo, "branch", "feature-b"], cwd: nil)
        let git = GitWorktree(gitPath: "/usr/bin/git")
        XCTAssertEqual(Set(try git.localBranches(repo: repo)), ["main", "feature-a", "feature-b"])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GitWorktreeTests/testLocalBranchesListsEveryLocalBranch`
Expected: FAIL — `value of type 'GitWorktree' has no member 'localBranches'`.

- [ ] **Step 3: Write minimal implementation**

Add to `Sources/CodaCore/GitWorktree.swift`, after the `list(repo:)` method (after line 81, inside the `GitWorktree` struct):

```swift
    /// Local branch names, one per line, via `git branch --format=%(refname:short)`.
    /// No `refs/heads/` prefix, no `*` current-branch marker — just names.
    public func localBranches(repo: String) throws -> [String] {
        try git(repo, ["branch", "--format=%(refname:short)"])
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GitWorktreeTests`
Expected: PASS (all `GitWorktreeTests`, including the new one).

- [ ] **Step 5: Commit**

```bash
git add Sources/CodaCore/GitWorktree.swift Tests/CodaCoreTests/GitWorktreeTests.swift
git commit -m "feat(core): list a repo's local branches"
```

---

### Task 2: Optional base + repo-level branch list (`WorktreeStore`, pure)

Threads an optional `base` through `createWorktree` (default `nil` = current `HEAD`, unchanged) and exposes a repo-level pass-through the UI uses to populate the picker.

**Files:**
- Modify: `Sources/CodaCore/WorktreeStore.swift` (`createWorktree` at line 78; add `localBranches(repoID:)` nearby)
- Test: `Tests/CodaCoreTests/WorktreeStoreTests.swift` (add three tests)

**Interfaces:**
- Consumes: `GitWorktree.localBranches(repo:)` (Task 1), existing `git.currentBranch(repo:)`, `git.add(repo:path:branch:base:)`, `state.repositories`, `WorktreeStoreError.repoNotFound`.
- Produces:
  - `func createWorktree(repoID: String, title: String, base: String? = nil) throws -> Worktree` — `base == nil` forks from `git.currentBranch`; non-nil forks from that branch.
  - `func localBranches(repoID: String) throws -> [String]`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/CodaCoreTests/WorktreeStoreTests.swift`, inside the `WorktreeStoreTests` class. The first uses a local helper that puts a distinct file on a `develop` branch so we can prove which base was used:

```swift
    func testCreateWorktreeForksFromExplicitBase() throws {
        let repo = try makeTempRepo()   // branch "main", has README.md
        func git(_ args: [String]) throws {
            let r = try ProcessRunner.run("/usr/bin/git", ["-C", repo] + args, cwd: nil)
            XCTAssertEqual(r.exitCode, 0, r.stderr)
        }
        // A develop-only file marks develop's tip; main does not have it.
        try git(["checkout", "-b", "develop"])
        try "dev".write(toFile: repo + "/DEV.md", atomically: true, encoding: .utf8)
        try git(["add", "."]); try git(["commit", "-m", "dev-only"])
        try git(["checkout", "main"])

        let (store, _) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r = try store.addRepository(path: repo)
        let s = try store.createWorktree(repoID: r.id, title: "From Develop", base: "develop")

        XCTAssertEqual(s.branch, "from-develop")
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.worktreePath + "/DEV.md"),
                      "worktree should be forked from develop, which has DEV.md")
    }

    func testCreateWorktreeDefaultsToCurrentHeadWhenBaseNil() throws {
        let repo = try makeTempRepo()   // on main; DEV.md lives only on develop
        func git(_ args: [String]) throws {
            let r = try ProcessRunner.run("/usr/bin/git", ["-C", repo] + args, cwd: nil)
            XCTAssertEqual(r.exitCode, 0, r.stderr)
        }
        try git(["checkout", "-b", "develop"])
        try "dev".write(toFile: repo + "/DEV.md", atomically: true, encoding: .utf8)
        try git(["add", "."]); try git(["commit", "-m", "dev-only"])
        try git(["checkout", "main"])

        let (store, _) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r = try store.addRepository(path: repo)
        let s = try store.createWorktree(repoID: r.id, title: "From Head")   // base omitted → main

        XCTAssertFalse(FileManager.default.fileExists(atPath: s.worktreePath + "/DEV.md"),
                       "omitting base should fork from current HEAD (main), which lacks DEV.md")
    }

    func testLocalBranchesForRepo() throws {
        let repo = try makeTempRepo()
        _ = try ProcessRunner.run("/usr/bin/git", ["-C", repo, "branch", "develop"], cwd: nil)
        let (store, _) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r = try store.addRepository(path: repo)
        XCTAssertEqual(Set(try store.localBranches(repoID: r.id)), ["main", "develop"])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter WorktreeStoreTests`
Expected: FAIL — `extra argument 'base' in call` (createWorktree) and `has no member 'localBranches'`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/CodaCore/WorktreeStore.swift`, change the `createWorktree` signature and base resolution. Replace lines 78–82:

```swift
    public func createWorktree(repoID: String, title: String) throws -> Worktree {
        guard let repo = state.repositories.first(where: { $0.id == repoID }) else {
            throw WorktreeStoreError.repoNotFound(repoID)
        }
        let base = try git.currentBranch(repo: repo.path)
```

with:

```swift
    public func createWorktree(repoID: String, title: String, base: String? = nil) throws -> Worktree {
        guard let repo = state.repositories.first(where: { $0.id == repoID }) else {
            throw WorktreeStoreError.repoNotFound(repoID)
        }
        let resolvedBase = try base ?? git.currentBranch(repo: repo.path)
```

Then update the single use of the old local `base` — change line 87 from:

```swift
        try git.add(repo: repo.path, path: worktreePath, branch: branch, base: base)
```

to:

```swift
        try git.add(repo: repo.path, path: worktreePath, branch: branch, base: resolvedBase)
```

(Leave `uniqueBranch(base: slugify(title), repo: repo)` on line 83 untouched — its `base:` label is unrelated to the fork point.)

Add the pass-through method after `currentBranch(repoID:)` (after line 61):

```swift
    /// The repo's local branch names, for the "base branch" picker in New Worktree.
    public func localBranches(repoID: String) throws -> [String] {
        guard let repo = state.repositories.first(where: { $0.id == repoID }) else {
            throw WorktreeStoreError.repoNotFound(repoID)
        }
        return try git.localBranches(repo: repo.path)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter WorktreeStoreTests`
Expected: PASS (all `WorktreeStoreTests`, including the three new ones — the existing `base`-less tests still pass because the parameter defaults to `nil`).

- [ ] **Step 5: Commit**

```bash
git add Sources/CodaCore/WorktreeStore.swift Tests/CodaCoreTests/WorktreeStoreTests.swift
git commit -m "feat(core): optional base branch for createWorktree + repo branch list"
```

---

### Task 3: Base-branch picker dialog + wiring (`Coda`, glue)

Replaces the title-only prompt in the New Worktree flow with a two-field dialog (title + base-branch popup) and passes the chosen base into `createWorktree`. Falls back to the old prompt when there are no branches to choose from.

**Files:**
- Modify: `Sources/Coda/AppDelegate.swift` (`newWorktree` at lines 564–580; add `promptForNewWorktree` near `promptForText` at line 1453)

**Interfaces:**
- Consumes: `store.localBranches(repoID:)` and `store.createWorktree(repoID:title:base:)` (Task 2), `store.currentBranch(repoID:)`, existing `promptForText(prompt:defaultValue:)`, `Repository`.
- Produces: `func promptForNewWorktree(repo: Repository) -> (title: String, base: String)?` (private).

- [ ] **Step 1: Add the dialog method**

In `Sources/Coda/AppDelegate.swift`, add this private method immediately before `promptForText` (before line 1453):

```swift
    /// Prompt for a new worktree's title and the local branch it forks from. Returns nil on
    /// Cancel. When branch enumeration yields nothing (e.g. an unborn repo), falls back to the
    /// title-only prompt with the base left at the repo's current HEAD.
    private func promptForNewWorktree(repo: Repository) -> (title: String, base: String)? {
        let branches = (try? store.localBranches(repoID: repo.id)) ?? []
        let currentHead = try? store.currentBranch(repoID: repo.id)

        guard !branches.isEmpty else {
            guard let title = promptForText(prompt: "Worktree title:", defaultValue: "New Worktree") else { return nil }
            return (title, currentHead ?? "HEAD")
        }

        let alert = NSAlert()
        alert.messageText = "New Worktree"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let titleLabel = NSTextField(labelWithString: "Title")
        let titleField = NSTextField(string: "New Worktree")
        let baseLabel = NSTextField(labelWithString: "Base branch")
        let basePopup = NSPopUpButton()
        for b in branches { basePopup.addItem(withTitle: b) }
        if let head = currentHead, let idx = branches.firstIndex(of: head) {
            basePopup.selectItem(at: idx)
        }

        let stack = NSStackView(views: [titleLabel, titleField, baseLabel, basePopup])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 100)
        titleField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        basePopup.widthAnchor.constraint(equalToConstant: 260).isActive = true
        alert.accessoryView = stack

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let title = titleField.stringValue.isEmpty ? "New Worktree" : titleField.stringValue
        let base = basePopup.titleOfSelectedItem ?? currentHead ?? "HEAD"
        return (title, base)
    }
```

- [ ] **Step 2: Wire it into `newWorktree`**

In `Sources/Coda/AppDelegate.swift`, replace the body of `newWorktree` (lines 573–579, from the `let title = promptForText(...)` line through the closing of the `do/catch`):

```swift
        let title = promptForText(prompt: "Worktree title:", defaultValue: "New Worktree") ?? "New Worktree"
        do {
            let s = try store.createWorktree(repoID: repo.id, title: title)
            pendingSetupWorktreeIDs.insert(s.id)
            refreshSidebar(select: s.id)
            select(s)
        } catch { presentError(error) }
```

with:

```swift
        guard let (title, base) = promptForNewWorktree(repo: repo) else { return }
        do {
            let s = try store.createWorktree(repoID: repo.id, title: title, base: base)
            pendingSetupWorktreeIDs.insert(s.id)
            refreshSidebar(select: s.id)
            select(s)
        } catch { presentError(error) }
```

(Note: Cancel now aborts creation instead of falling back to a "New Worktree"-titled worktree — the previous `?? "New Worktree"` created one even on cancel. Aborting on cancel is the intended behavior.)

- [ ] **Step 3: Build and run the full test suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: build succeeds; all tests pass (no new CodaCore tests here, but the app target must compile and nothing regresses). Ignore any stale SourceKit cross-module diagnostics — trust the build result.

- [ ] **Step 4: Manual GUI verification**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run Coda`
Verify, in a repo with at least two local branches:
1. `Worktree ▸ New Worktree` (and sidebar right-click → New Worktree) opens a dialog with a **Title** field and a **Base branch** popup.
2. The popup lists the repo's local branches and preselects the current `HEAD`.
3. Creating with a non-default base forks the new worktree from that branch (e.g. `cd` into the new worktree dir, `git log --oneline -1` shows the chosen base's tip).
4. Cancel creates nothing.
5. Title-only fallback still works in a freshly `git init`'d repo with no branches/commits (no crash; worktree creation path behaves as before).

- [ ] **Step 5: Commit**

```bash
git add Sources/Coda/AppDelegate.swift
git commit -m "feat(app): base-branch picker in the New Worktree dialog"
```

---

## Self-Review Notes

- **Spec coverage:** §1 CodaCore → Tasks 1 (`localBranches`) & 2 (`base` param + store pass-through); §2 AppKit dialog → Task 3; §3 unborn-repo fallback → Task 3 Step 1 (empty-branches guard) + Step 4.5; §4 testing → Tasks 1–2 tests + Task 3 build/manual.
- **Type consistency:** `localBranches` used identically in `GitWorktree` (repo path) and `WorktreeStore` (repoID pass-through); `createWorktree(...:base:)` signature matches its Task 3 call site; `promptForNewWorktree` return tuple `(title:base:)` matches the `guard let (title, base)` destructure.
- **Backward compat:** `base` defaults to `nil`; existing `createWorktree` test/app call sites unchanged and covered by `testCreateWorktreeDefaultsToCurrentHeadWhenBaseNil`.
