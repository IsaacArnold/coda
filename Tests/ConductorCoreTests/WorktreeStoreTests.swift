import XCTest
import Foundation
@testable import ConductorCore

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
}
