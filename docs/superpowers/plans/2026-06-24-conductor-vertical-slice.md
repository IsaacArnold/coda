# Conductor Vertical Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS app where you register a git repo, create a worktree-backed session (new branch + worktree + auto-launched `claude` in an embedded terminal), see it in a sidebar, and archive it (worktree removed, branch optionally deleted).

**Architecture:** A Swift package with two targets. `ConductorCore` holds all pure logic — running git, worktree lifecycle, session/repository models, machine-local config persistence — and is covered by unit/integration tests (TDD). `Conductor` is the AppKit executable that embeds SwiftTerm and drives `ConductorCore`; it is verified by build + manual launch, not unit tests. The split exists so the bug-prone logic is testable without a UI.

**Tech Stack:** Swift 6.3 (Swift 5 language mode), Swift Package Manager, AppKit, SwiftTerm 1.13.x, Swift Testing (`import Testing`), real `git` CLI.

## Global Constraints

- **Engine:** embed SwiftTerm's `LocalProcessTerminalView`; never write a terminal emulator.
- **Config split:** machine-local config (repo paths, worktree locations, sessions) lives in `~/.conductor/local.json`; it MUST contain absolute paths only here, never in any future portable config file.
- **No absolute paths in source:** worktree root and repo paths come from config/runtime, never hardcoded.
- **Build from source:** SwiftPM, `swift build` / `swift run` / `swift test`; no Xcode project, no signing, in this slice.
- **macOS target:** `.macOS(.v13)` minimum.
- **Working name:** Conductor.
- **Language mode:** `swiftLanguageModes: [.v5]` (AppKit main-actor friendliness; matches the spike).
- **Out of scope for this slice (later Phase-1 plans):** theming/`.itermcolors`, snippets, agent-state badges, tab/surface colors, cmd+click, `setupScript`, copy-allowlist, multiple surfaces per session, restore-on-relaunch.

---

## File Structure

```
Package.swift                                  # two targets + test target + SwiftTerm dep
Sources/
  ConductorCore/
    ProcessRunner.swift                        # run a CLI, capture stdout/stderr/exit
    GitWorktree.swift                          # git worktree add/list/remove/branch ops
    Models.swift                               # Repository, Session structs (Codable)
    Config.swift                               # load/save ~/.conductor/local.json
    SessionStore.swift                         # orchestrates repos+sessions over GitWorktree+Config
    Slug.swift                                 # title -> branch slug
  Conductor/
    main.swift                                 # NSApplication bootstrap
    AppDelegate.swift                          # window, wires UI <-> SessionStore
    SidebarController.swift                     # NSTableView of sessions + toolbar actions
    TerminalSurface.swift                      # SwiftTerm view that runs a command in a cwd
Tests/
  ConductorCoreTests/
    TestSupport.swift                          # makeTempRepo() helper
    ProcessRunnerTests.swift
    GitWorktreeTests.swift
    ConfigTests.swift
    SessionStoreTests.swift
    SlugTests.swift
```

**Interfaces locked across tasks** (defined in the task noted, consumed later):

```swift
// ProcessRunner.swift (Task 2)
public struct ProcessResult: Equatable { public let stdout: String; public let stderr: String; public let exitCode: Int32 }
public enum ProcessRunner { public static func run(_ executable: String, _ args: [String], cwd: String?) throws -> ProcessResult }

// Slug.swift (Task 2)
public func slugify(_ s: String) -> String

// GitWorktree.swift (Task 3)
public struct WorktreeInfo: Equatable { public let path: String; public let branch: String? }
public struct GitWorktree {
    public init(gitPath: String)
    public func currentBranch(repo: String) throws -> String
    public func list(repo: String) throws -> [WorktreeInfo]
    public func add(repo: String, path: String, branch: String, base: String) throws
    public func remove(repo: String, path: String) throws
    public func deleteBranch(repo: String, branch: String) throws
}

// Models.swift (Task 4)
public struct Repository: Codable, Equatable, Identifiable { public var id: String; public var path: String; public var name: String }
public struct Session: Codable, Equatable, Identifiable { public var id: String; public var repoID: String; public var title: String; public var branch: String; public var worktreePath: String }

// Config.swift (Task 4)
public struct LocalState: Codable, Equatable { public var repositories: [Repository]; public var sessions: [Session] }
public final class Config { public init(url: URL); public func load() -> LocalState; public func save(_ s: LocalState) throws }

// SessionStore.swift (Task 5)
public final class SessionStore {
    public init(config: Config, git: GitWorktree, worktreeRoot: String)
    public private(set) var state: LocalState
    public func addRepository(path: String) throws -> Repository
    public func createSession(repoID: String, title: String) throws -> Session
    public func archiveSession(id: String, deleteBranch: Bool) throws
}
```

---

### Task 1: Package scaffold + empty app window

**Files:**
- Create: `Package.swift`
- Create: `Sources/Conductor/main.swift`
- Create: `Sources/Conductor/AppDelegate.swift`
- Create: `Sources/ConductorCore/Placeholder.swift` (temporary, deleted in Task 2)
- Create: `Tests/ConductorCoreTests/TestSupport.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: a buildable package with `Conductor` (executable), `ConductorCore` (library), `ConductorCoreTests` targets.

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Conductor",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .target(name: "ConductorCore"),
        .executableTarget(
            name: "Conductor",
            dependencies: [
                "ConductorCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        ),
        .testTarget(name: "ConductorCoreTests", dependencies: ["ConductorCore"])
    ],
    swiftLanguageModes: [.v5]
)
```

- [ ] **Step 2: Write a temporary library file so the target compiles**

`Sources/ConductorCore/Placeholder.swift`:
```swift
public let conductorCoreReady = true
```

- [ ] **Step 3: Write the app bootstrap**

`Sources/Conductor/main.swift`:
```swift
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
```

`Sources/Conductor/AppDelegate.swift`:
```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Conductor"
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
```

- [ ] **Step 4: Write the test-support helper (used from Task 3 on)**

`Tests/ConductorCoreTests/TestSupport.swift`:
```swift
import Foundation

/// Create a throwaway git repo with one commit on branch `main`. Returns its path.
func makeTempRepo() throws -> String {
    let dir = NSTemporaryDirectory() + "conductor-test-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    func git(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
    }
    try git(["init", "-b", "main"])
    try git(["config", "user.email", "test@conductor.local"])
    try git(["config", "user.name", "Conductor Test"])
    try "hello".write(toFile: dir + "/README.md", atomically: true, encoding: .utf8)
    try git(["add", "."])
    try git(["commit", "-m", "init"])
    return dir
}
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 6: Launch and verify the empty window**

Run: `swift run Conductor`
Expected: a window titled "Conductor" appears. Close it; the process exits.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Package.resolved Sources Tests
git commit -m "feat: scaffold Conductor package (Core lib + AppKit app)"
```

---

### Task 2: ProcessRunner + Slug (pure helpers, TDD)

**Files:**
- Delete: `Sources/ConductorCore/Placeholder.swift`
- Create: `Sources/ConductorCore/ProcessRunner.swift`
- Create: `Sources/ConductorCore/Slug.swift`
- Test: `Tests/ConductorCoreTests/ProcessRunnerTests.swift`
- Test: `Tests/ConductorCoreTests/SlugTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `ProcessResult`, `ProcessRunner.run`, `slugify` (signatures in File Structure block).

- [ ] **Step 1: Write the failing ProcessRunner test**

`Tests/ConductorCoreTests/ProcessRunnerTests.swift`:
```swift
import Testing
import Foundation
@testable import ConductorCore

@Test func runCapturesStdoutAndExitZero() throws {
    let r = try ProcessRunner.run("/bin/echo", ["hello world"], cwd: nil)
    #expect(r.stdout == "hello world\n")
    #expect(r.exitCode == 0)
}

@Test func runReportsNonZeroExit() throws {
    let r = try ProcessRunner.run("/bin/sh", ["-c", "exit 3"], cwd: nil)
    #expect(r.exitCode == 3)
}

@Test func runHonorsWorkingDirectory() throws {
    let tmp = NSTemporaryDirectory()
    let r = try ProcessRunner.run("/bin/pwd", [], cwd: tmp)
    #expect(r.stdout.contains(tmp.hasSuffix("/") ? String(tmp.dropLast()) : tmp))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ProcessRunnerTests`
Expected: FAIL — `cannot find 'ProcessRunner' in scope`.

- [ ] **Step 3: Implement ProcessRunner**

First delete the placeholder: `rm Sources/ConductorCore/Placeholder.swift`

`Sources/ConductorCore/ProcessRunner.swift`:
```swift
import Foundation

public struct ProcessResult: Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
}

public enum ProcessRunner {
    /// Run an executable with args, optionally in `cwd`, and capture its output.
    public static func run(_ executable: String, _ args: [String], cwd: String?) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }
}
```

- [ ] **Step 4: Run to verify ProcessRunner tests pass**

Run: `swift test --filter ProcessRunnerTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Write the failing Slug test**

`Tests/ConductorCoreTests/SlugTests.swift`:
```swift
import Testing
@testable import ConductorCore

@Test func slugifyLowercasesAndHyphenates() {
    #expect(slugify("Add Login Flow") == "add-login-flow")
}

@Test func slugifyStripsPunctuationAndCollapsesDashes() {
    #expect(slugify("Fix: the @bug!! (urgent)") == "fix-the-bug-urgent")
}

@Test func slugifyFallsBackWhenEmpty() {
    #expect(slugify("!!!") == "session")
}
```

- [ ] **Step 6: Run to verify it fails**

Run: `swift test --filter SlugTests`
Expected: FAIL — `cannot find 'slugify' in scope`.

- [ ] **Step 7: Implement slugify**

`Sources/ConductorCore/Slug.swift`:
```swift
import Foundation

/// Turn a human title into a git-branch-safe slug: lowercase, words joined by
/// single hyphens, only [a-z0-9-]. Falls back to "session" if nothing survives.
public func slugify(_ s: String) -> String {
    let lowered = s.lowercased()
    var out = ""
    var lastWasDash = false
    for ch in lowered {
        if ch.isLetter || ch.isNumber {
            out.append(ch)
            lastWasDash = false
        } else if !lastWasDash {
            out.append("-")
            lastWasDash = true
        }
    }
    let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.isEmpty ? "session" : trimmed
}
```

- [ ] **Step 8: Run to verify Slug tests pass**

Run: `swift test --filter SlugTests`
Expected: PASS (3 tests).

- [ ] **Step 9: Commit**

```bash
git add Sources/ConductorCore Tests/ConductorCoreTests
git commit -m "feat: add ProcessRunner and slugify with tests"
```

---

### Task 3: GitWorktree lifecycle (TDD against a real temp repo)

**Files:**
- Create: `Sources/ConductorCore/GitWorktree.swift`
- Test: `Tests/ConductorCoreTests/GitWorktreeTests.swift`

**Interfaces:**
- Consumes: `ProcessRunner.run` (Task 2), `makeTempRepo()` (Task 1).
- Produces: `WorktreeInfo`, `GitWorktree` (signatures in File Structure block).

- [ ] **Step 1: Write the failing tests**

`Tests/ConductorCoreTests/GitWorktreeTests.swift`:
```swift
import Testing
import Foundation
@testable import ConductorCore

@Test func currentBranchIsMain() throws {
    let repo = try makeTempRepo()
    let git = GitWorktree(gitPath: "/usr/bin/git")
    #expect(try git.currentBranch(repo: repo) == "main")
}

@Test func addCreatesWorktreeAndBranchThenListsIt() throws {
    let repo = try makeTempRepo()
    let git = GitWorktree(gitPath: "/usr/bin/git")
    let wt = NSTemporaryDirectory() + "wt-" + UUID().uuidString
    try git.add(repo: repo, path: wt, branch: "feature-x", base: "main")

    #expect(FileManager.default.fileExists(atPath: wt + "/README.md"))
    let list = try git.list(repo: repo)
    #expect(list.contains { $0.path == wt && $0.branch == "feature-x" })
}

@Test func removeDeletesWorktreeAndBranchCanBeDeleted() throws {
    let repo = try makeTempRepo()
    let git = GitWorktree(gitPath: "/usr/bin/git")
    let wt = NSTemporaryDirectory() + "wt-" + UUID().uuidString
    try git.add(repo: repo, path: wt, branch: "feature-y", base: "main")
    try git.remove(repo: repo, path: wt)
    #expect(!FileManager.default.fileExists(atPath: wt))

    try git.deleteBranch(repo: repo, branch: "feature-y")
    let branches = try ProcessRunner.run("/usr/bin/git", ["-C", repo, "branch", "--list", "feature-y"], cwd: nil)
    #expect(branches.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter GitWorktreeTests`
Expected: FAIL — `cannot find 'GitWorktree' in scope`.

- [ ] **Step 3: Implement GitWorktree**

`Sources/ConductorCore/GitWorktree.swift`:
```swift
import Foundation

public struct WorktreeInfo: Equatable {
    public let path: String
    public let branch: String?
}

public enum GitError: Error, CustomStringConvertible {
    case command(String, Int32, String)
    public var description: String {
        switch self { case .command(let c, let code, let err): return "git \(c) failed (\(code)): \(err)" }
    }
}

public struct GitWorktree {
    private let gitPath: String
    public init(gitPath: String) { self.gitPath = gitPath }

    @discardableResult
    private func git(_ repo: String, _ args: [String]) throws -> String {
        let r = try ProcessRunner.run(gitPath, ["-C", repo] + args, cwd: nil)
        guard r.exitCode == 0 else {
            throw GitError.command(args.joined(separator: " "), r.exitCode, r.stderr)
        }
        return r.stdout
    }

    public func currentBranch(repo: String) throws -> String {
        try git(repo, ["rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func add(repo: String, path: String, branch: String, base: String) throws {
        try git(repo, ["worktree", "add", "-b", branch, path, base])
    }

    public func remove(repo: String, path: String) throws {
        try git(repo, ["worktree", "remove", path, "--force"])
    }

    public func deleteBranch(repo: String, branch: String) throws {
        try git(repo, ["branch", "-D", branch])
    }

    /// Parse `git worktree list --porcelain` into (path, branch) pairs.
    public func list(repo: String) throws -> [WorktreeInfo] {
        let out = try git(repo, ["worktree", "list", "--porcelain"])
        var result: [WorktreeInfo] = []
        var currentPath: String?
        var currentBranch: String?
        func flush() {
            if let p = currentPath { result.append(WorktreeInfo(path: p, branch: currentBranch)) }
            currentPath = nil; currentBranch = nil
        }
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                flush()
                currentPath = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch ") {
                // value like "refs/heads/feature-x"
                let ref = String(line.dropFirst("branch ".count))
                currentBranch = ref.replacingOccurrences(of: "refs/heads/", with: "")
            }
        }
        flush()
        return result
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter GitWorktreeTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ConductorCore/GitWorktree.swift Tests/ConductorCoreTests/GitWorktreeTests.swift
git commit -m "feat: add GitWorktree lifecycle (add/list/remove/branch) with tests"
```

---

### Task 4: Models + Config persistence (TDD)

**Files:**
- Create: `Sources/ConductorCore/Models.swift`
- Create: `Sources/ConductorCore/Config.swift`
- Test: `Tests/ConductorCoreTests/ConfigTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `Repository`, `Session`, `LocalState`, `Config` (signatures in File Structure block).

- [ ] **Step 1: Write the models**

`Sources/ConductorCore/Models.swift`:
```swift
import Foundation

public struct Repository: Codable, Equatable, Identifiable {
    public var id: String
    public var path: String
    public var name: String
    public init(id: String, path: String, name: String) {
        self.id = id; self.path = path; self.name = name
    }
}

public struct Session: Codable, Equatable, Identifiable {
    public var id: String
    public var repoID: String
    public var title: String
    public var branch: String
    public var worktreePath: String
    public init(id: String, repoID: String, title: String, branch: String, worktreePath: String) {
        self.id = id; self.repoID = repoID; self.title = title
        self.branch = branch; self.worktreePath = worktreePath
    }
}
```

- [ ] **Step 2: Write the failing Config test**

`Tests/ConductorCoreTests/ConfigTests.swift`:
```swift
import Testing
import Foundation
@testable import ConductorCore

@Test func loadReturnsEmptyStateWhenFileMissing() {
    let url = URL(fileURLWithPath: NSTemporaryDirectory() + "cfg-" + UUID().uuidString + ".json")
    let cfg = Config(url: url)
    #expect(cfg.load() == LocalState(repositories: [], sessions: []))
}

@Test func saveThenLoadRoundTrips() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory() + "cfg-" + UUID().uuidString + ".json")
    let cfg = Config(url: url)
    let state = LocalState(
        repositories: [Repository(id: "r1", path: "/tmp/repo", name: "repo")],
        sessions: [Session(id: "s1", repoID: "r1", title: "T", branch: "t", worktreePath: "/tmp/wt")]
    )
    try cfg.save(state)
    #expect(cfg.load() == state)
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `swift test --filter ConfigTests`
Expected: FAIL — `cannot find 'Config' in scope`.

- [ ] **Step 4: Implement Config**

`Sources/ConductorCore/Config.swift`:
```swift
import Foundation

public struct LocalState: Codable, Equatable {
    public var repositories: [Repository]
    public var sessions: [Session]
    public init(repositories: [Repository], sessions: [Session]) {
        self.repositories = repositories; self.sessions = sessions
    }
}

/// Machine-local config persisted as JSON. Holds absolute paths; this file is the
/// ONLY place absolute paths are allowed (future portable config must not have them).
public final class Config {
    private let url: URL
    public init(url: URL) { self.url = url }

    public func load() -> LocalState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(LocalState.self, from: data) else {
            return LocalState(repositories: [], sessions: [])
        }
        return state
    }

    public func save(_ state: LocalState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter ConfigTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/ConductorCore/Models.swift Sources/ConductorCore/Config.swift Tests/ConductorCoreTests/ConfigTests.swift
git commit -m "feat: add Repository/Session models and machine-local Config persistence"
```

---

### Task 5: SessionStore orchestration (TDD)

**Files:**
- Create: `Sources/ConductorCore/SessionStore.swift`
- Test: `Tests/ConductorCoreTests/SessionStoreTests.swift`

**Interfaces:**
- Consumes: `GitWorktree` (Task 3), `Config`/`LocalState`/`Repository`/`Session` (Task 4), `slugify` (Task 2).
- Produces: `SessionStore` (signatures in File Structure block).

- [ ] **Step 1: Write the failing tests**

`Tests/ConductorCoreTests/SessionStoreTests.swift`:
```swift
import Testing
import Foundation
@testable import ConductorCore

private func makeStore(worktreeRoot: String) -> (SessionStore, Config) {
    let cfgURL = URL(fileURLWithPath: NSTemporaryDirectory() + "store-" + UUID().uuidString + ".json")
    let cfg = Config(url: cfgURL)
    let store = SessionStore(config: cfg,
                             git: GitWorktree(gitPath: "/usr/bin/git"),
                             worktreeRoot: worktreeRoot)
    return (store, cfg)
}

@Test func addRepositoryDerivesNameAndPersists() throws {
    let repo = try makeTempRepo()
    let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
    let r = try store.addRepository(path: repo)
    #expect(r.path == repo)
    #expect(!r.name.isEmpty)
    #expect(cfg.load().repositories.contains(r))
}

@Test func createSessionMakesWorktreeAndPersists() throws {
    let repo = try makeTempRepo()
    let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
    let r = try store.addRepository(path: repo)
    let s = try store.createSession(repoID: r.id, title: "Add Login Flow")

    #expect(s.branch == "add-login-flow")
    #expect(FileManager.default.fileExists(atPath: s.worktreePath + "/README.md"))
    #expect(cfg.load().sessions.contains(s))
}

@Test func archiveSessionRemovesWorktreeAndSession() throws {
    let repo = try makeTempRepo()
    let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
    let r = try store.addRepository(path: repo)
    let s = try store.createSession(repoID: r.id, title: "Temp Work")
    try store.archiveSession(id: s.id, deleteBranch: true)

    #expect(!FileManager.default.fileExists(atPath: s.worktreePath))
    #expect(!cfg.load().sessions.contains { $0.id == s.id })
}

@Test func duplicateTitlesGetUniqueBranches() throws {
    let repo = try makeTempRepo()
    let (store, _) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
    let r = try store.addRepository(path: repo)
    let a = try store.createSession(repoID: r.id, title: "Same")
    let b = try store.createSession(repoID: r.id, title: "Same")
    #expect(a.branch != b.branch)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter SessionStoreTests`
Expected: FAIL — `cannot find 'SessionStore' in scope`.

- [ ] **Step 3: Implement SessionStore**

`Sources/ConductorCore/SessionStore.swift`:
```swift
import Foundation

public enum SessionStoreError: Error { case repoNotFound(String); case sessionNotFound(String) }

public final class SessionStore {
    private let config: Config
    private let git: GitWorktree
    private let worktreeRoot: String
    public private(set) var state: LocalState

    public init(config: Config, git: GitWorktree, worktreeRoot: String) {
        self.config = config
        self.git = git
        self.worktreeRoot = worktreeRoot
        self.state = config.load()
    }

    public func addRepository(path: String) throws -> Repository {
        if let existing = state.repositories.first(where: { $0.path == path }) { return existing }
        let name = URL(fileURLWithPath: path).lastPathComponent
        let repo = Repository(id: UUID().uuidString, path: path, name: name)
        state.repositories.append(repo)
        try config.save(state)
        return repo
    }

    public func createSession(repoID: String, title: String) throws -> Session {
        guard let repo = state.repositories.first(where: { $0.id == repoID }) else {
            throw SessionStoreError.repoNotFound(repoID)
        }
        let base = try git.currentBranch(repo: repo.path)
        let branch = uniqueBranch(base: slugify(title), repo: repo)
        let worktreePath = (worktreeRoot as NSString)
            .appendingPathComponent(repo.name)
            .appending("/").appending(branch)
        try git.add(repo: repo.path, path: worktreePath, branch: branch, base: base)

        let session = Session(id: UUID().uuidString, repoID: repoID,
                              title: title, branch: branch, worktreePath: worktreePath)
        state.sessions.append(session)
        try config.save(state)
        return session
    }

    public func archiveSession(id: String, deleteBranch: Bool) throws {
        guard let session = state.sessions.first(where: { $0.id == id }) else {
            throw SessionStoreError.sessionNotFound(id)
        }
        guard let repo = state.repositories.first(where: { $0.id == session.repoID }) else {
            throw SessionStoreError.repoNotFound(session.repoID)
        }
        try git.remove(repo: repo.path, path: session.worktreePath)
        if deleteBranch {
            try? git.deleteBranch(repo: repo.path, branch: session.branch)
        }
        state.sessions.removeAll { $0.id == id }
        try config.save(state)
    }

    private func uniqueBranch(base: String, repo: Repository) -> String {
        let taken = Set(state.sessions.filter { $0.repoID == repo.id }.map { $0.branch })
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter SessionStoreTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the whole Core suite**

Run: `swift test`
Expected: PASS (all tests across ProcessRunner, Slug, GitWorktree, Config, SessionStore).

- [ ] **Step 6: Commit**

```bash
git add Sources/ConductorCore/SessionStore.swift Tests/ConductorCoreTests/SessionStoreTests.swift
git commit -m "feat: add SessionStore orchestrating worktree-backed sessions"
```

---

### Task 6: App — sidebar wired to SessionStore (build + launch verify)

**Files:**
- Create: `Sources/Conductor/SidebarController.swift`
- Modify: `Sources/Conductor/AppDelegate.swift` (replace empty window with sidebar + detail layout, build the store)

**Interfaces:**
- Consumes: `SessionStore`, `Config`, `GitWorktree`, `Session`, `Repository` (ConductorCore).
- Produces: `SidebarController` with `var onSelect: ((Session?) -> Void)?`, `var onArchive: ((Session) -> Void)?`, `func reload(sessions: [Session], selected: String?)`.

- [ ] **Step 1: Write the SidebarController**

`Sources/Conductor/SidebarController.swift`:
```swift
import AppKit
import ConductorCore

/// A simple sidebar: a table of session titles + a toolbar with New / Archive.
final class SidebarController: NSViewController {
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var sessions: [Session] = []

    var onNew: (() -> Void)?
    var onAddRepo: (() -> Void)?
    var onSelect: ((Session?) -> Void)?
    var onArchive: ((Session) -> Void)?

    override func loadView() {
        let container = NSView()

        let addRepo = NSButton(title: "Add Repo…", target: self, action: #selector(addRepoAction))
        let new = NSButton(title: "New Session", target: self, action: #selector(newAction))
        let archive = NSButton(title: "Archive", target: self, action: #selector(archiveAction))
        let bar = NSStackView(views: [addRepo, new, archive])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        bar.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("title"))
        column.title = "Sessions"
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(bar)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    func reload(sessions: [Session], selected: String?) {
        self.sessions = sessions
        table.reloadData()
        if let selected, let idx = sessions.firstIndex(where: { $0.id == selected }) {
            table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
    }

    @objc private func addRepoAction() { onAddRepo?() }
    @objc private func newAction() { onNew?() }
    @objc private func archiveAction() {
        let row = table.selectedRow
        guard row >= 0, row < sessions.count else { return }
        onArchive?(sessions[row])
    }
}

extension SidebarController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { sessions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 6),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -6),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            c.identifier = id
            return c
        }()
        cell.textField?.stringValue = "\(sessions[row].title)  [\(sessions[row].branch)]"
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        onSelect?(row >= 0 && row < sessions.count ? sessions[row] : nil)
    }
}
```

- [ ] **Step 2: Rewrite AppDelegate to build the store and host the sidebar**

`Sources/Conductor/AppDelegate.swift`:
```swift
import AppKit
import ConductorCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var splitVC: NSSplitViewController!
    private let sidebar = SidebarController()
    private let detail = NSViewController()      // holds the terminal surface (Task 7)
    private var store: SessionStore!

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = makeStore()
        buildWindow()
        wireSidebar()
        refreshSidebar(select: store.state.sessions.first?.id)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func makeStore() -> SessionStore {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = home.appendingPathComponent(".conductor/local.json")
        let worktreeRoot = home.appendingPathComponent(".conductor/worktrees").path
        return SessionStore(config: Config(url: configURL),
                            git: GitWorktree(gitPath: "/usr/bin/git"),
                            worktreeRoot: worktreeRoot)
    }

    private func buildWindow() {
        detail.view = NSView()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        let detailItem = NSSplitViewItem(viewController: detail)
        splitVC = NSSplitViewController()
        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(detailItem)

        window = NSWindow(contentViewController: splitVC)
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.title = "Conductor"
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func wireSidebar() {
        sidebar.onAddRepo = { [weak self] in self?.addRepo() }
        sidebar.onNew = { [weak self] in self?.newSession() }
        sidebar.onArchive = { [weak self] s in self?.archive(s) }
        sidebar.onSelect = { [weak self] s in self?.select(s) }
    }

    private func refreshSidebar(select id: String?) {
        sidebar.reload(sessions: store.state.sessions, selected: id)
    }

    private func addRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add Repo"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { _ = try store.addRepository(path: url.path) }
        catch { presentError(error) }
    }

    private func newSession() {
        guard let repo = store.state.repositories.first else {
            presentMessage("Add a repo first (Add Repo…).")
            return
        }
        let title = promptForText(prompt: "Session title:", defaultValue: "New Session") ?? "New Session"
        do {
            let s = try store.createSession(repoID: repo.id, title: title)
            refreshSidebar(select: s.id)
            select(s)
        } catch { presentError(error) }
    }

    private func archive(_ s: Session) {
        do {
            try store.archiveSession(id: s.id, deleteBranch: true)
            refreshSidebar(select: store.state.sessions.first?.id)
            select(store.state.sessions.first)
        } catch { presentError(error) }
    }

    // select() is fully implemented in Task 7; here it just clears the detail view.
    private func select(_ s: Session?) {
        detail.view = NSView()
    }

    // MARK: - small helpers

    private func promptForText(prompt: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func presentError(_ error: Error) { presentMessage("\(error)") }

    private func presentMessage(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.runModal()
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Launch and verify the sidebar loop (without terminal yet)**

Run: `swift run Conductor`
Verify, in order:
1. Window shows a sidebar (Add Repo… / New Session / Archive + empty table) and a blank detail pane.
2. Click **Add Repo…**, choose a real git repo (e.g. `/Users/isaac/macOS-projects/conductor` itself).
3. Click **New Session**, accept the title. A row appears in the sidebar like `New Session  [new-session]`.
4. Confirm on disk: `ls ~/.conductor/worktrees/<repo-name>/` shows the new worktree directory.
5. Select the row, click **Archive**. The row disappears and the worktree directory is gone.
6. Quit. Relaunch — any sessions you left appear again (state persisted to `~/.conductor/local.json`).

- [ ] **Step 5: Commit**

```bash
git add Sources/Conductor
git commit -m "feat: sidebar UI wired to SessionStore (create/list/archive sessions)"
```

---

### Task 7: App — terminal surface auto-launches `claude` in the worktree

**Files:**
- Create: `Sources/Conductor/TerminalSurface.swift`
- Modify: `Sources/Conductor/AppDelegate.swift` (`select(_:)` shows a terminal for the session)

**Interfaces:**
- Consumes: SwiftTerm `LocalProcessTerminalView`, `Session` (ConductorCore).
- Produces: `TerminalSurface` (an `NSViewController`) with `init(workingDirectory: String, command: String)`.

- [ ] **Step 1: Write the TerminalSurface**

`Sources/Conductor/TerminalSurface.swift`:
```swift
import AppKit
import SwiftTerm

/// A view controller hosting one SwiftTerm terminal that runs `command` (via the
/// login shell) inside `workingDirectory`. For the slice, command defaults to `claude`.
final class TerminalSurface: NSViewController {
    private let workingDirectory: String
    private let command: String
    private var terminal: LocalProcessTerminalView!

    init(workingDirectory: String, command: String) {
        self.workingDirectory = workingDirectory
        self.command = command
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        terminal.autoresizingMask = [.width, .height]
        view = terminal
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard terminal.bounds.width > 0 else { return }
        // Run an interactive zsh that execs the command, so the user keeps a shell
        // after the command exits. `-i -c` keeps it interactive.
        let line = "cd \(shellQuote(workingDirectory)) && exec \(command)"
        terminal.startProcess(executable: "/bin/zsh",
                              args: ["-i", "-c", line],
                              environment: nil,
                              execName: "-zsh",
                              currentDirectory: workingDirectory)
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
```

- [ ] **Step 2: Update `select(_:)` in AppDelegate to embed the terminal**

Replace the placeholder `select(_:)` from Task 6 with:
```swift
    private func select(_ s: Session?) {
        guard let s else { detail.view = NSView(); return }
        let surface = TerminalSurface(workingDirectory: s.worktreePath, command: "claude")
        // Retain by parenting it as a child view controller of `detail`.
        detail.children.forEach { $0.removeFromParent() }
        detail.view = NSView()
        detail.addChild(surface)
        surface.view.frame = detail.view.bounds
        surface.view.autoresizingMask = [.width, .height]
        detail.view.addSubview(surface.view)
    }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Launch and verify the terminal surface**

Run: `swift run Conductor`
Verify:
1. Add a repo (if needed), create a New Session, select it.
2. The detail pane shows a live terminal. Its working directory is the worktree — type `pwd` and confirm it prints `~/.conductor/worktrees/<repo>/<branch>`.
3. If `claude` is installed, it launches automatically in that worktree. (To test without using Claude credits, temporarily change `command: "claude"` to `command: "echo ready; zsh"` in `select(_:)`, verify, then revert.)
4. Selecting a different session swaps the terminal to that worktree.

- [ ] **Step 5: Commit**

```bash
git add Sources/Conductor/TerminalSurface.swift Sources/Conductor/AppDelegate.swift
git commit -m "feat: terminal surface auto-launches claude in the session worktree"
```

---

### Task 8: End-to-end verification + slice closeout

**Files:**
- Modify: `DECISIONS.md` (mark vertical slice complete)

**Interfaces:**
- Consumes: everything above.
- Produces: a documented, verified end-to-end slice.

- [ ] **Step 1: Run the full test suite**

Run: `swift test`
Expected: PASS (all ConductorCore tests).

- [ ] **Step 2: Full manual end-to-end pass**

Run: `swift run Conductor`, then:
1. Add Repo… → pick a real git repo.
2. New Session "Try Approach A" → sidebar shows `Try Approach A  [try-approach-a]`; terminal opens in the new worktree; `claude` starts.
3. New Session "Try Approach B" → second worktree + session, independent terminal.
4. Switch between the two sessions — each terminal is its own worktree/PTY.
5. Archive "Try Approach A" → row gone, worktree directory removed (`ls ~/.conductor/worktrees/<repo>/`), branch deleted (`git -C <repo> branch` no longer lists it).
6. Quit and relaunch → remaining session(s) restored in the sidebar.

- [ ] **Step 3: Update DECISIONS.md**

Add under the spike verdict:
```markdown
## Vertical slice (Phase 1 spine) — ✅ COMPLETE

End-to-end: register repo → create worktree-session (branch + worktree + auto `claude`) → switch → archive (worktree removed, branch deleted). Core logic TDD-tested in `ConductorCore`; AppKit shell in `Conductor`. Next Phase-1 plans layer on: setupScript + copy-allowlist, theming/.itermcolors, snippets, agent-state badges, tab/surface colors, cmd+click, multi-surface, restore-on-relaunch.
```

- [ ] **Step 4: Commit**

```bash
git add DECISIONS.md
git commit -m "docs: mark Conductor vertical slice complete"
```

---

## Notes for the implementer

- **`swift test` uses Swift Testing** (`import Testing`, `@Test`, `#expect`). If the toolchain rejects it, fall back to XCTest with the same assertions.
- **GitWorktree tests shell out to real `git`** against throwaway repos in `NSTemporaryDirectory()` — this is intentional integration testing; do not mock git.
- **App tasks (6, 7) are verified by build + manual launch**, not unit tests — GUI/terminal behavior isn't cleanly unit-testable, and that's an accepted boundary for this slice.
- **The `vscode://` / LaunchServices and cmd+click learnings from the spike are NOT in this slice** — cmd+click arrives in a later Phase-1 plan once the spine is solid.
