import XCTest
import Foundation
@testable import CodaCore

final class WorktreeStoreTests: XCTestCase {
    private func makeStore(worktreeRoot: String) -> (WorktreeStore, Config) {
        let cfgURL = URL(fileURLWithPath: NSTemporaryDirectory() + "store-" + UUID().uuidString + ".json")
        let cfg = Config(url: cfgURL)
        let store = WorktreeStore(config: cfg,
                                  git: GitWorktree(gitPath: "/usr/bin/git"),
                                  worktreeRoot: worktreeRoot)
        return (store, cfg)
    }

    func testAddRepositoryDerivesNameAndPersists() throws {
        let repo = try makeTempRepo()
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r = try store.addRepository(path: repo)
        XCTAssertEqual(r.path, repo)
        XCTAssertFalse(r.name.isEmpty)
        XCTAssertTrue(cfg.load().repositories.contains(r))
    }

    func testCreateWorktreeMakesWorktreeAndPersists() throws {
        let repo = try makeTempRepo()
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r = try store.addRepository(path: repo)
        let s = try store.createWorktree(repoID: r.id, title: "Add Login Flow")

        XCTAssertEqual(s.branch, "add-login-flow")
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.worktreePath + "/README.md"))
        XCTAssertTrue(cfg.load().worktrees.contains(s))
    }

    func testArchiveWorktreeRemovesWorktreeAndEntry() throws {
        let repo = try makeTempRepo()
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r = try store.addRepository(path: repo)
        let s = try store.createWorktree(repoID: r.id, title: "Temp Work")
        try store.archiveWorktree(id: s.id, deleteBranch: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: s.worktreePath))
        XCTAssertFalse(cfg.load().worktrees.contains { $0.id == s.id })
    }

    func testDuplicateTitlesGetUniqueBranches() throws {
        let repo = try makeTempRepo()
        let (store, _) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r = try store.addRepository(path: repo)
        let a = try store.createWorktree(repoID: r.id, title: "Same")
        let b = try store.createWorktree(repoID: r.id, title: "Same")
        XCTAssertNotEqual(a.branch, b.branch)
    }

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

    func testUpdateRepositoryPersistsAutoLaunchClaude() throws {
        let repo = try makeTempRepo()
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r = try store.addRepository(path: repo)
        XCTAssertFalse(r.autoLaunchClaude, "repos default to shell-first")

        let updated = try store.updateRepository(id: r.id, setupScript: "",
                                                 copyAllowlist: [], autoLaunchClaude: true)
        XCTAssertTrue(updated.autoLaunchClaude)
        // Persisted to disk, so newly created worktrees in this repo will auto-run Claude.
        XCTAssertEqual(cfg.load().repositories.first { $0.id == r.id }?.autoLaunchClaude, true)
    }

    func testCreateWorktreeCopiesAllowlistedFilesIntoWorktree() throws {
        let repo = try makeTempRepo()
        // An untracked, gitignored-style file that git worktree add would NOT bring over.
        try "SECRET=1".write(toFile: repo + "/.env", atomically: true, encoding: .utf8)

        let (store, _) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r = try store.addRepository(path: repo)
        _ = try store.updateRepository(id: r.id, setupScript: "", copyAllowlist: [".env"])
        let s = try store.createWorktree(repoID: r.id, title: "Needs Env")

        let copiedEnv = s.worktreePath + "/.env"
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedEnv))
        XCTAssertEqual(try String(contentsOfFile: copiedEnv, encoding: .utf8), "SECRET=1")
    }

    func testBranchUniquenessIsScopedPerRepo() throws {
        let repoA = try makeTempRepo()
        let repoB = try makeTempRepo()
        let (store, _) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let rA = try store.addRepository(path: repoA)
        let rB = try store.addRepository(path: repoB)
        // The same title in a different repo must NOT be bumped to a `-2` suffix:
        // uniqueness is scoped per repo, so both branches are the plain slug.
        let a = try store.createWorktree(repoID: rA.id, title: "Same")
        let b = try store.createWorktree(repoID: rB.id, title: "Same")
        XCTAssertEqual(a.branch, "same")
        XCTAssertEqual(b.branch, "same")
    }

    func testCreateWorktreeAutoAssignsFirstPaletteColor() throws {
        let repo = try makeTempRepo()
        let (store, _) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r = try store.addRepository(path: repo)
        let wt = try store.createWorktree(repoID: r.id, title: "First")
        XCTAssertEqual(wt.color, IdentityPalette.color(at: 0))
    }

    func testSecondWorktreeGetsNextPaletteColor() throws {
        let repo = try makeTempRepo()
        let (store, _) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r = try store.addRepository(path: repo)
        _ = try store.createWorktree(repoID: r.id, title: "First")
        let second = try store.createWorktree(repoID: r.id, title: "Second")
        XCTAssertEqual(second.color, IdentityPalette.color(at: 1))
    }

    func testSetWorktreeColorPersists() throws {
        let repo = try makeTempRepo()
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r = try store.addRepository(path: repo)
        let wt = try store.createWorktree(repoID: r.id, title: "First")
        _ = try store.setWorktreeColor(id: wt.id, color: "#E91E63")
        // Persisted to disk: a fresh load of the same config sees the override.
        XCTAssertEqual(cfg.load().worktrees.first(where: { $0.id == wt.id })?.color, "#E91E63")
    }

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

    func testSetRepositoryDisplayNameUnknownIDThrows() throws {
        let (store, _) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        XCTAssertThrowsError(try store.setRepositoryDisplayName(id: "nope", displayName: "X"))
    }

    // MARK: - readable errors (#1) + create/archive atomicity (#4)

    func testStoreErrorsHaveReadableDescriptions() {
        XCTAssertEqual(String(describing: WorktreeStoreError.repoNotFound("R1")), "Repository not found: R1")
        XCTAssertEqual(String(describing: WorktreeStoreError.worktreeNotFound("W1")), "Worktree not found: W1")
    }

    /// A store whose config lives in its own directory, so a test can make that directory
    /// read-only to force `config.save` to throw (the on-disk worktree root stays writable).
    private func makeStoreInOwnConfigDir() throws -> (WorktreeStore, cfgDir: URL, worktreeRoot: String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory() + "cfgdir-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let worktreeRoot = NSTemporaryDirectory() + "wtr-" + UUID().uuidString
        let store = WorktreeStore(config: Config(url: dir.appendingPathComponent("store.json")),
                                  git: GitWorktree(gitPath: "/usr/bin/git"),
                                  worktreeRoot: worktreeRoot)
        return (store, dir, worktreeRoot)
    }

    func testCreateWorktreeRollsBackWhenSaveFails() throws {
        let repo = try makeTempRepo()
        let (store, cfgDir, worktreeRoot) = try makeStoreInOwnConfigDir()
        let r = try store.addRepository(path: repo)   // saves while the dir is still writable
        // Make the config dir read-only so the save inside createWorktree throws.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: cfgDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cfgDir.path) }

        XCTAssertThrowsError(try store.createWorktree(repoID: r.id, title: "Doomed"))
        // Rolled back: no in-memory entry, and the on-disk worktree was removed (no orphan).
        XCTAssertTrue(store.state.worktrees.isEmpty)
        let orphan = worktreeRoot + "/" + URL(fileURLWithPath: repo).lastPathComponent + "/doomed"
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan), "orphaned worktree left on disk")
    }

    func testArchiveRollsBackWhenSaveFails() throws {
        let repo = try makeTempRepo()
        let (store, cfgDir, _) = try makeStoreInOwnConfigDir()
        let r = try store.addRepository(path: repo)
        let s = try store.createWorktree(repoID: r.id, title: "Keep Me")
        // Read-only config dir → the save inside archive throws before the irreversible removal.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: cfgDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cfgDir.path) }

        XCTAssertThrowsError(try store.archiveWorktree(id: s.id, deleteBranch: true))
        // Restored: the entry is still tracked and its files are intact.
        XCTAssertTrue(store.state.worktrees.contains { $0.id == s.id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.worktreePath))
    }

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
}
