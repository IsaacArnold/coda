# Conductor Setup Behavior Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A freshly created worktree-session copies repo-configured allowlisted files (e.g. `.env`) into the new worktree and runs a per-repo `setupScript` (e.g. `npm install`) **visibly in the terminal before `claude`** — running setup exactly once at creation, not on every relaunch.

**Architecture:** All logic lands in `ConductorCore` (TDD): two new `Repository` fields with backward-compatible decoding, a `SessionStore.updateRepository` API to set them, a pure `copyAllowlistedFiles` function, and a pure `terminalLaunchLine` builder. The `Conductor` app layer (build + manual verify) then: copies files inside `createSession`, builds the launch line with the repo's `setupScript`, and runs setup only for sessions created in the current app run.

**Tech Stack:** Swift (Swift 5 language mode), SwiftPM, AppKit, SwiftTerm 1.13.x, XCTest, real `git` CLI.

## Global Constraints

- **TOOLCHAIN:** Command Line Tools lack XCTest. Prefix **every** `swift build`/`run`/`test` with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Tests are **XCTest** (`import XCTest`, `XCTestCase`, `XCTAssert*`), not Swift Testing. Filter by class: `swift test --filter ConductorCoreTests.<ClassName>`.
- **Engine:** embed SwiftTerm's `LocalProcessTerminalView`; never write a terminal emulator.
- **Backward compatibility:** existing `~/.conductor/local.json` (repos WITHOUT the new fields) MUST still decode — new fields default to empty.
- **Config split:** machine-local config (`~/.conductor/local.json`) is the only place absolute paths live; no absolute paths hardcoded in source (`/usr/bin/git` and `/bin/zsh` system paths excepted).
- **macOS target:** `.macOS(.v13)`; `swiftLanguageModes: [.v5]`.
- **Setup-run semantics:** `setupScript` runs once, in the terminal, only for a session created in the current app run; reselecting or relaunching the app must NOT re-run it (the worktree already has its deps on disk).
- **Out of scope (Plan 2 — UI):** the per-repo settings sheet. This plan ships the behavior; repo fields are set programmatically / by hand-editing `local.json` until Plan 2.

## File Structure

```
Sources/ConductorCore/
  Models.swift          # MODIFY: Repository gains setupScript + copyAllowlist (backward-compat Codable)
  SessionStore.swift    # MODIFY: updateRepository(...) API; createSession copies allowlisted files
  FileCopy.swift        # CREATE: copyAllowlistedFiles(from:to:allowlist:)
  LaunchCommand.swift   # CREATE: terminalLaunchLine(workingDirectory:setupScript:command:) + shellSingleQuote
Sources/Conductor/
  TerminalSurface.swift # MODIFY: take setupScript, build line via terminalLaunchLine
  AppDelegate.swift     # MODIFY: track freshly-created sessions; pass repo setupScript to the surface
Tests/ConductorCoreTests/
  ModelsCodableTests.swift   # CREATE
  FileCopyTests.swift        # CREATE
  LaunchCommandTests.swift   # CREATE
  SessionStoreTests.swift    # MODIFY: updateRepository + createSession-copies tests
```

**Interfaces locked across tasks:**

```swift
// Models.swift (Task 1)
public struct Repository: Codable, Equatable, Identifiable {
    public var id: String
    public var path: String
    public var name: String
    public var setupScript: String         // default ""
    public var copyAllowlist: [String]     // default []
    public init(id: String, path: String, name: String, setupScript: String = "", copyAllowlist: [String] = [])
}

// SessionStore.swift (Task 1)
public func updateRepository(id: String, setupScript: String, copyAllowlist: [String]) throws -> Repository

// FileCopy.swift (Task 2)
public func copyAllowlistedFiles(from repoRoot: String, to worktree: String, allowlist: [String]) throws -> [String]

// LaunchCommand.swift (Task 3)
public func shellSingleQuote(_ s: String) -> String
public func terminalLaunchLine(workingDirectory: String, setupScript: String, command: String) -> String
```

---

### Task 1: Repository config fields + backward-compatible decoding + updateRepository

**Files:**
- Modify: `Sources/ConductorCore/Models.swift`
- Modify: `Sources/ConductorCore/SessionStore.swift`
- Test: `Tests/ConductorCoreTests/ModelsCodableTests.swift` (create)
- Test: `Tests/ConductorCoreTests/SessionStoreTests.swift` (add one test)

**Interfaces:**
- Consumes: existing `Config`, `LocalState`, `SessionStore`.
- Produces: `Repository.setupScript`/`copyAllowlist` (defaulted), `SessionStore.updateRepository(id:setupScript:copyAllowlist:)`.

- [ ] **Step 1: Write the failing backward-compat decode test**

`Tests/ConductorCoreTests/ModelsCodableTests.swift`:
```swift
import XCTest
import Foundation
@testable import ConductorCore

final class ModelsCodableTests: XCTestCase {
    func testRepositoryDecodesOldJSONWithoutNewFields() throws {
        // Mirrors an existing ~/.conductor/local.json repo entry with no setup fields.
        let json = #"{"id":"r1","path":"/tmp/repo","name":"repo"}"#
        let repo = try JSONDecoder().decode(Repository.self, from: Data(json.utf8))
        XCTAssertEqual(repo.setupScript, "")
        XCTAssertEqual(repo.copyAllowlist, [])
    }

    func testRepositoryRoundTripsNewFields() throws {
        let repo = Repository(id: "r1", path: "/tmp/repo", name: "repo",
                              setupScript: "npm install", copyAllowlist: [".env"])
        let data = try JSONEncoder().encode(repo)
        let back = try JSONDecoder().decode(Repository.self, from: data)
        XCTAssertEqual(back, repo)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ConductorCoreTests.ModelsCodableTests`
Expected: FAIL — `Repository` has no `setupScript`/`copyAllowlist` (compile error).

- [ ] **Step 3: Add the fields with backward-compatible decoding**

Replace the `Repository` struct in `Sources/ConductorCore/Models.swift` with:
```swift
public struct Repository: Codable, Equatable, Identifiable {
    public var id: String
    public var path: String
    public var name: String
    public var setupScript: String
    public var copyAllowlist: [String]

    public init(id: String, path: String, name: String,
                setupScript: String = "", copyAllowlist: [String] = []) {
        self.id = id; self.path = path; self.name = name
        self.setupScript = setupScript; self.copyAllowlist = copyAllowlist
    }

    private enum CodingKeys: String, CodingKey { case id, path, name, setupScript, copyAllowlist }

    // Custom decode so older configs without the setup fields still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decode(String.self, forKey: .name)
        setupScript = try c.decodeIfPresent(String.self, forKey: .setupScript) ?? ""
        copyAllowlist = try c.decodeIfPresent([String].self, forKey: .copyAllowlist) ?? []
    }
}
```

- [ ] **Step 4: Run to verify the decode tests pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ConductorCoreTests.ModelsCodableTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Write the failing updateRepository test**

Add to `Tests/ConductorCoreTests/SessionStoreTests.swift` inside the `SessionStoreTests` class:
```swift
    func testUpdateRepositoryPersistsSetupFields() throws {
        let repo = try makeTempRepo()
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r = try store.addRepository(path: repo)
        let updated = try store.updateRepository(id: r.id, setupScript: "npm install", copyAllowlist: [".env"])
        XCTAssertEqual(updated.setupScript, "npm install")
        XCTAssertEqual(updated.copyAllowlist, [".env"])
        // Persisted to disk:
        let reloaded = cfg.load().repositories.first { $0.id == r.id }
        XCTAssertEqual(reloaded?.setupScript, "npm install")
        XCTAssertEqual(reloaded?.copyAllowlist, [".env"])
    }
```

- [ ] **Step 6: Run to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ConductorCoreTests.SessionStoreTests`
Expected: FAIL — `updateRepository` not defined.

- [ ] **Step 7: Implement updateRepository**

Add this method to `SessionStore` in `Sources/ConductorCore/SessionStore.swift` (after `addRepository`):
```swift
    public func updateRepository(id: String, setupScript: String, copyAllowlist: [String]) throws -> Repository {
        guard let idx = state.repositories.firstIndex(where: { $0.id == id }) else {
            throw SessionStoreError.repoNotFound(id)
        }
        state.repositories[idx].setupScript = setupScript
        state.repositories[idx].copyAllowlist = copyAllowlist
        try config.save(state)
        return state.repositories[idx]
    }
```

- [ ] **Step 8: Run to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ConductorCoreTests.SessionStoreTests`
Expected: PASS (all SessionStore tests, including the new one).

- [ ] **Step 9: Commit**

```bash
git add Sources/ConductorCore/Models.swift Sources/ConductorCore/SessionStore.swift Tests/ConductorCoreTests/ModelsCodableTests.swift Tests/ConductorCoreTests/SessionStoreTests.swift
git commit -m "feat: add repo setupScript/copyAllowlist fields + updateRepository (backward-compat)"
```

---

### Task 2: copyAllowlistedFiles

**Files:**
- Create: `Sources/ConductorCore/FileCopy.swift`
- Test: `Tests/ConductorCoreTests/FileCopyTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `copyAllowlistedFiles(from:to:allowlist:) throws -> [String]` (returns the relative paths actually copied).

- [ ] **Step 1: Write the failing tests**

`Tests/ConductorCoreTests/FileCopyTests.swift`:
```swift
import XCTest
import Foundation
@testable import ConductorCore

final class FileCopyTests: XCTestCase {
    private func makeDir() throws -> String {
        let d = NSTemporaryDirectory() + "fc-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    func testCopiesExistingFileAndSkipsMissing() throws {
        let src = try makeDir(), dst = try makeDir()
        try "SECRET=1".write(toFile: src + "/.env", atomically: true, encoding: .utf8)
        let copied = try copyAllowlistedFiles(from: src, to: dst, allowlist: [".env", "missing.txt"])
        XCTAssertEqual(copied, [".env"])
        XCTAssertEqual(try String(contentsOfFile: dst + "/.env", encoding: .utf8), "SECRET=1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst + "/missing.txt"))
    }

    func testCopiesNestedPathCreatingParentDirs() throws {
        let src = try makeDir(), dst = try makeDir()
        try FileManager.default.createDirectory(atPath: src + "/apps/web", withIntermediateDirectories: true)
        try "X=1".write(toFile: src + "/apps/web/.env.local", atomically: true, encoding: .utf8)
        let copied = try copyAllowlistedFiles(from: src, to: dst, allowlist: ["apps/web/.env.local"])
        XCTAssertEqual(copied, ["apps/web/.env.local"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst + "/apps/web/.env.local"))
    }

    func testCopiesDirectoryRecursively() throws {
        let src = try makeDir(), dst = try makeDir()
        try FileManager.default.createDirectory(atPath: src + "/config", withIntermediateDirectories: true)
        try "a".write(toFile: src + "/config/a.txt", atomically: true, encoding: .utf8)
        let copied = try copyAllowlistedFiles(from: src, to: dst, allowlist: ["config"])
        XCTAssertEqual(copied, ["config"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst + "/config/a.txt"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ConductorCoreTests.FileCopyTests`
Expected: FAIL — `copyAllowlistedFiles` not in scope.

- [ ] **Step 3: Implement copyAllowlistedFiles**

`Sources/ConductorCore/FileCopy.swift`:
```swift
import Foundation

/// Copy each allowlisted relative path from `repoRoot` into `worktree`, preserving
/// the relative path and creating parent directories. Missing sources are skipped.
/// Returns the relative paths that were actually copied. Files and directories
/// (recursively) are both supported.
public func copyAllowlistedFiles(from repoRoot: String, to worktree: String, allowlist: [String]) throws -> [String] {
    let fm = FileManager.default
    var copied: [String] = []
    for rel in allowlist {
        let source = (repoRoot as NSString).appendingPathComponent(rel)
        guard fm.fileExists(atPath: source) else { continue }
        let dest = (worktree as NSString).appendingPathComponent(rel)
        let destParent = (dest as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: destParent, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
        try fm.copyItem(atPath: source, toPath: dest)
        copied.append(rel)
    }
    return copied
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ConductorCoreTests.FileCopyTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ConductorCore/FileCopy.swift Tests/ConductorCoreTests/FileCopyTests.swift
git commit -m "feat: add copyAllowlistedFiles for seeding worktrees (e.g. .env)"
```

---

### Task 3: terminalLaunchLine builder

**Files:**
- Create: `Sources/ConductorCore/LaunchCommand.swift`
- Test: `Tests/ConductorCoreTests/LaunchCommandTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `shellSingleQuote(_:)`, `terminalLaunchLine(workingDirectory:setupScript:command:)`.

- [ ] **Step 1: Write the failing tests**

`Tests/ConductorCoreTests/LaunchCommandTests.swift`:
```swift
import XCTest
@testable import ConductorCore

final class LaunchCommandTests: XCTestCase {
    func testNoSetupExecsCommandDirectly() {
        let line = terminalLaunchLine(workingDirectory: "/tmp/wt", setupScript: "", command: "claude")
        XCTAssertEqual(line, "cd '/tmp/wt' && exec claude")
    }

    func testWhitespaceOnlySetupTreatedAsEmpty() {
        let line = terminalLaunchLine(workingDirectory: "/tmp/wt", setupScript: "   \n", command: "claude")
        XCTAssertEqual(line, "cd '/tmp/wt' && exec claude")
    }

    func testSetupRunsThenExecsCommandWithShellFallback() {
        let line = terminalLaunchLine(workingDirectory: "/tmp/wt", setupScript: "npm install", command: "claude")
        XCTAssertEqual(line, "cd '/tmp/wt' && { npm install && exec claude || exec zsh; }")
    }

    func testWorkingDirectoryIsSingleQuoted() {
        let line = terminalLaunchLine(workingDirectory: "/tmp/a b's", setupScript: "", command: "claude")
        XCTAssertEqual(line, "cd '/tmp/a b'\\''s' && exec claude")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ConductorCoreTests.LaunchCommandTests`
Expected: FAIL — `terminalLaunchLine` not in scope.

- [ ] **Step 3: Implement the builder**

`Sources/ConductorCore/LaunchCommand.swift`:
```swift
import Foundation

/// POSIX single-quote a string (the only fully safe quoting): wrap in '...' and
/// replace embedded ' with '\''.
public func shellSingleQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Build the `zsh -i -c` line for a terminal surface.
/// - No setupScript: `cd <dir> && exec <command>` (command replaces the shell).
/// - With setupScript: run setup first; on success exec the command; on failure
///   drop into an interactive shell so the user can investigate, instead of the
///   terminal dying. `exec` must NOT precede the setup chain, so it sits only in
///   front of the final command.
/// `command` is intentionally not quoted (it is a single token like `claude`).
public func terminalLaunchLine(workingDirectory: String, setupScript: String, command: String) -> String {
    let dir = shellSingleQuote(workingDirectory)
    let setup = setupScript.trimmingCharacters(in: .whitespacesAndNewlines)
    if setup.isEmpty {
        return "cd \(dir) && exec \(command)"
    }
    return "cd \(dir) && { \(setup) && exec \(command) || exec zsh; }"
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ConductorCoreTests.LaunchCommandTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ConductorCore/LaunchCommand.swift Tests/ConductorCoreTests/LaunchCommandTests.swift
git commit -m "feat: add terminalLaunchLine builder (setup chain + shell fallback)"
```

---

### Task 4: createSession copies allowlisted files

**Files:**
- Modify: `Sources/ConductorCore/SessionStore.swift`
- Test: `Tests/ConductorCoreTests/SessionStoreTests.swift` (add one test)

**Interfaces:**
- Consumes: `copyAllowlistedFiles` (Task 2), `updateRepository` (Task 1).
- Produces: `createSession` now seeds the worktree with the repo's `copyAllowlist`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/ConductorCoreTests/SessionStoreTests.swift` inside the `SessionStoreTests` class:
```swift
    func testCreateSessionCopiesAllowlistedFilesIntoWorktree() throws {
        let repo = try makeTempRepo()
        // An untracked, gitignored-style file that git worktree add would NOT bring over.
        try "SECRET=1".write(toFile: repo + "/.env", atomically: true, encoding: .utf8)

        let (store, _) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r = try store.addRepository(path: repo)
        _ = try store.updateRepository(id: r.id, setupScript: "", copyAllowlist: [".env"])
        let s = try store.createSession(repoID: r.id, title: "Needs Env")

        let copiedEnv = s.worktreePath + "/.env"
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedEnv))
        XCTAssertEqual(try String(contentsOfFile: copiedEnv, encoding: .utf8), "SECRET=1")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ConductorCoreTests.SessionStoreTests`
Expected: FAIL — `.env` is not copied into the worktree (file does not exist there).

- [ ] **Step 3: Call copyAllowlistedFiles in createSession**

In `Sources/ConductorCore/SessionStore.swift`, in `createSession`, immediately AFTER the `try git.add(...)` line and BEFORE constructing the `Session`, add:
```swift
        // Seed the fresh worktree with repo-configured untracked files (e.g. .env).
        // git worktree add only brings tracked files, so these would otherwise be missing.
        _ = try copyAllowlistedFiles(from: repo.path, to: worktreePath, allowlist: repo.copyAllowlist)
```

- [ ] **Step 4: Run to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ConductorCoreTests.SessionStoreTests`
Expected: PASS (all SessionStore tests).

- [ ] **Step 5: Run the full Core suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: PASS (all ConductorCore tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/ConductorCore/SessionStore.swift Tests/ConductorCoreTests/SessionStoreTests.swift
git commit -m "feat: createSession seeds new worktree with allowlisted files"
```

---

### Task 5: App wire-up — run setupScript once in the terminal on creation

**Files:**
- Modify: `Sources/Conductor/TerminalSurface.swift`
- Modify: `Sources/Conductor/AppDelegate.swift`

**Interfaces:**
- Consumes: `terminalLaunchLine` (Task 3), `Repository.setupScript` (Task 1), `SessionStore.state`.
- Produces: terminal runs `setupScript && claude` for a freshly-created session; `claude` only on subsequent selects/relaunches.

- [ ] **Step 1: Update TerminalSurface to take setupScript and use the Core builder**

Replace the full contents of `Sources/Conductor/TerminalSurface.swift` with:
```swift
import AppKit
import SwiftTerm
import ConductorCore

/// A view controller hosting one SwiftTerm terminal that runs `command` (via the
/// login shell) inside `workingDirectory`. If `setupScript` is non-empty it runs
/// before the command (visibly, once).
final class TerminalSurface: NSViewController {
    private let workingDirectory: String
    private let command: String
    private let setupScript: String
    private var terminal: LocalProcessTerminalView!

    init(workingDirectory: String, command: String, setupScript: String = "") {
        self.workingDirectory = workingDirectory
        self.command = command
        self.setupScript = setupScript
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        terminal.autoresizingMask = [.width, .height]
        view = terminal
    }

    private var processStarted = false

    override func viewDidLayout() {
        super.viewDidLayout()
        // Start the PTY only once bounds are known (viewDidAppear can fire at zero size).
        guard !processStarted, terminal.bounds.width > 0 else { return }
        processStarted = true
        let line = terminalLaunchLine(workingDirectory: workingDirectory,
                                      setupScript: setupScript,
                                      command: command)
        terminal.startProcess(executable: "/bin/zsh",
                              args: ["-i", "-c", line],
                              environment: nil,
                              execName: "-zsh",
                              currentDirectory: workingDirectory)
    }
}
```

- [ ] **Step 2: Track freshly-created sessions and pass setupScript in AppDelegate**

In `Sources/Conductor/AppDelegate.swift`:

(a) Add a stored property near the other private vars (e.g. just below `private var shownSessionID: String?`):
```swift
    // Sessions created in THIS app run, whose first terminal should run setupScript.
    private var pendingSetupSessionIDs: Set<String> = []
```

(b) In `newSession()`, immediately after the `let s = try store.createSession(...)` line (before `refreshSidebar`/`select`), add:
```swift
            pendingSetupSessionIDs.insert(s.id)
```

(c) Replace the `let surface = TerminalSurface(workingDirectory: s.worktreePath, command: "claude")` line in `select(_:)` with:
```swift
        let repo = store.state.repositories.first { $0.id == s.repoID }
        let setup = pendingSetupSessionIDs.contains(s.id) ? (repo?.setupScript ?? "") : ""
        pendingSetupSessionIDs.remove(s.id)
        let surface = TerminalSurface(workingDirectory: s.worktreePath, command: "claude", setupScript: setup)
```

- [ ] **Step 3: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: `Build complete!`

- [ ] **Step 4: Confirm Core suite still green**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: PASS (all ConductorCore tests).

- [ ] **Step 5: Manual verification (controller/user — GUI)**

Until Plan 2's settings sheet exists, set a repo's fields by hand-editing `~/.conductor/local.json` (quit the app first): add to a repository entry, e.g.
```json
"setupScript" : "echo '--- running setup ---'; sleep 1; echo done",
"copyAllowlist" : [ ".env" ]
```
Then `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run Conductor` and verify:
1. **New Session** on that repo → the terminal shows the setup output (`--- running setup ---`, `done`) THEN `claude` starts. ⭐️
2. If the repo has a `.env` (untracked), confirm it now exists in the new worktree: `ls -a ~/.conductor/worktrees/<repo>/<branch>/.env`.
3. Select a different session and back → `claude` is NOT torn down/restarted, and setup does NOT re-run.
4. Quit and relaunch → selecting the same session runs **only `claude`** (no setup re-run), because the worktree is already set up.
5. A repo with empty `setupScript` behaves exactly as before (just `claude`).

- [ ] **Step 6: Commit**

```bash
git add Sources/Conductor/TerminalSurface.swift Sources/Conductor/AppDelegate.swift
git commit -m "feat: run repo setupScript once in the terminal for freshly created sessions"
```

---

## Notes for the implementer

- **Toolchain:** every `swift` command needs `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (CLT lacks XCTest). Tests are XCTest.
- **Tasks 1–4 are pure `ConductorCore` (TDD, fully verifiable headlessly). Task 5 is the app layer** — verified by `swift build` + the manual GUI checklist (a subagent can build + liveness-check but cannot drive the window; visual verification is the controller/user's).
- **Setup-once semantics live in the app layer, not Core:** the file copy happens in `createSession` (always, at creation); the `setupScript` runs in the terminal only for sessions in `pendingSetupSessionIDs` (this app run). A relaunch starts with an empty set, so setup never re-runs — correct because the worktree's deps already exist on disk. Known edge (accept for now): if the app quits mid-setup, a relaunch won't re-run it; the user can delete + recreate the session.
- **Do not introduce the settings sheet here** — that's Plan 2. Repo fields are set via `updateRepository` (API) or hand-edited JSON until then.
