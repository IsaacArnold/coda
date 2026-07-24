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

    func testCurrentBranchOnRepoWithNoCommits() throws {
        // A freshly `git init`'d repo has an unborn branch: `rev-parse --abbrev-ref HEAD`
        // fails, but the branch name (master) is still knowable via symbolic-ref.
        let repo = try makeTempRepoNoCommits()
        let (store, _) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r = try store.addRepository(path: repo)
        XCTAssertEqual(try store.currentBranch(repoID: r.id), "master")
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
        // Auto-assigned as a theme-following hue (index 0 → purple), stored serialized.
        XCTAssertEqual(wt.color, IdentityColorValue.hue(IdentityHue.autoAssigned(index: 0)).serialized)
        XCTAssertEqual(wt.color, "purple")
    }

    func testSecondWorktreeGetsNextPaletteColor() throws {
        let repo = try makeTempRepo()
        let (store, _) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r = try store.addRepository(path: repo)
        _ = try store.createWorktree(repoID: r.id, title: "First")
        let second = try store.createWorktree(repoID: r.id, title: "Second")
        XCTAssertEqual(second.color, IdentityColorValue.hue(IdentityHue.autoAssigned(index: 1)).serialized)
        XCTAssertEqual(second.color, "green")
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

    func testCreateWorktreeStoresPickedBase() throws {
        let repo = try makeTempRepo()
        let (store, _) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r = try store.addRepository(path: repo)
        let wt = try store.createWorktree(repoID: r.id, title: "Feature X", base: "main")
        XCTAssertEqual(wt.base, "main")
        XCTAssertEqual(store.state.worktrees.first { $0.id == wt.id }?.base, "main")
    }

    // MARK: - Sections: lifecycle + collapse (Task 4)

    func testCreateSectionAppendsToStateAndRootOrder() throws {
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let s = try store.createSection(name: "Work")
        XCTAssertEqual(s.name, "Work")
        XCTAssertTrue(s.repoIDs.isEmpty)
        XCTAssertFalse(s.isCollapsed)
        let loaded = cfg.load()
        XCTAssertTrue(loaded.sections.contains { $0.id == s.id })
        XCTAssertEqual(loaded.rootOrder, [.section(s.id)])
    }

    func testRenameSectionPersists() throws {
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let s = try store.createSection(name: "Work")
        _ = try store.renameSection(id: s.id, name: "Side Projects")
        XCTAssertEqual(cfg.load().sections.first { $0.id == s.id }?.name, "Side Projects")
    }

    func testRenameSectionIgnoresBlankName() throws {
        let (store, _) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let s = try store.createSection(name: "Work")
        let back = try store.renameSection(id: s.id, name: "   ")
        XCTAssertEqual(back.name, "Work")   // blank reverts to previous
    }

    func testDeleteSectionReleasesReposLooseAtFormerPosition() throws {
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r1 = try store.addRepository(path: "/tmp/sec-r1")
        let r2 = try store.addRepository(path: "/tmp/sec-r2")
        let s = try store.createSection(name: "Work")
        try store.moveRepo(id: r1.id, toSection: s.id, atIndex: 0)
        try store.moveRepo(id: r2.id, toSection: s.id, atIndex: 1)
        // rootOrder is now [.section(s)]; r1,r2 live inside it.
        try store.deleteSection(id: s.id)
        let loaded = cfg.load()
        XCTAssertFalse(loaded.sections.contains { $0.id == s.id })
        // Both repos released loose, in the section's slot, preserving their order.
        XCTAssertEqual(loaded.rootOrder, [.repo(r1.id), .repo(r2.id)])
    }

    func testSetSectionCollapsedPersists() throws {
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let s = try store.createSection(name: "Work")
        try store.setSectionCollapsed(id: s.id, collapsed: true)
        XCTAssertEqual(cfg.load().sections.first { $0.id == s.id }?.isCollapsed, true)
    }

    func testSetRepositoryCollapsedPersists() throws {
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r = try store.addRepository(path: "/tmp/collapse-r")
        try store.setRepositoryCollapsed(id: r.id, collapsed: true)
        XCTAssertEqual(cfg.load().repositories.first { $0.id == r.id }?.isCollapsed, true)
    }

    func testDeleteMissingSectionThrows() throws {
        let (store, _) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        XCTAssertThrowsError(try store.deleteSection(id: "nope"))
    }

    // MARK: - Sections: movement (Task 5)

    func testMoveRepoIntoSection() throws {
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r = try store.addRepository(path: "/tmp/mv-r1")
        let s = try store.createSection(name: "Work")
        try store.moveRepo(id: r.id, toSection: s.id, atIndex: 0)
        let loaded = cfg.load()
        XCTAssertEqual(loaded.sections.first { $0.id == s.id }?.repoIDs, [r.id])
        // The repo's loose root ref is gone; only the section remains at root.
        XCTAssertEqual(loaded.rootOrder, [.section(s.id)])
    }

    func testMoveRepoOutOfSectionToRoot() throws {
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r = try store.addRepository(path: "/tmp/mv-r1")
        let s = try store.createSection(name: "Work")
        try store.moveRepo(id: r.id, toSection: s.id, atIndex: 0)
        try store.moveRepo(id: r.id, toSection: nil, atIndex: 0)   // back to loose, at root index 0
        let loaded = cfg.load()
        XCTAssertEqual(loaded.sections.first { $0.id == s.id }?.repoIDs, [])
        XCTAssertEqual(loaded.rootOrder, [.repo(r.id), .section(s.id)])
    }

    func testMoveRepoBetweenSections() throws {
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r = try store.addRepository(path: "/tmp/mv-r1")
        let a = try store.createSection(name: "A")
        let b = try store.createSection(name: "B")
        try store.moveRepo(id: r.id, toSection: a.id, atIndex: 0)
        try store.moveRepo(id: r.id, toSection: b.id, atIndex: 0)
        let loaded = cfg.load()
        XCTAssertEqual(loaded.sections.first { $0.id == a.id }?.repoIDs, [])
        XCTAssertEqual(loaded.sections.first { $0.id == b.id }?.repoIDs, [r.id])
    }

    func testReorderReposWithinSection() throws {
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r1 = try store.addRepository(path: "/tmp/mv-r1")
        let r2 = try store.addRepository(path: "/tmp/mv-r2")
        let s = try store.createSection(name: "Work")
        try store.moveRepo(id: r1.id, toSection: s.id, atIndex: 0)
        try store.moveRepo(id: r2.id, toSection: s.id, atIndex: 1)   // [r1, r2]
        try store.moveRepo(id: r1.id, toSection: s.id, atIndex: 2)   // move r1 to the end
        XCTAssertEqual(cfg.load().sections.first { $0.id == s.id }?.repoIDs, [r2.id, r1.id])
    }

    func testReorderLooseReposAtRoot() throws {
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r1 = try store.addRepository(path: "/tmp/mv-r1")
        let r2 = try store.addRepository(path: "/tmp/mv-r2")
        // Prime rootOrder to [r1, r2] via reconciliation-independent explicit moves.
        try store.moveRepo(id: r1.id, toSection: nil, atIndex: 0)
        try store.moveRepo(id: r2.id, toSection: nil, atIndex: 1)
        try store.moveRepo(id: r1.id, toSection: nil, atIndex: 2)   // r1 to the end
        XCTAssertEqual(cfg.load().rootOrder, [.repo(r2.id), .repo(r1.id)])
    }

    func testMoveSectionReordersAmongRootItems() throws {
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r = try store.addRepository(path: "/tmp/mv-r1")
        try store.moveRepo(id: r.id, toSection: nil, atIndex: 0)     // rootOrder: [repo r]
        let s = try store.createSection(name: "Work")               // rootOrder: [repo r, section s]
        try store.moveSection(id: s.id, toIndex: 0)                 // section to the front
        XCTAssertEqual(cfg.load().rootOrder, [.section(s.id), .repo(r.id)])
    }

    func testMoveRepoMissingThrows() throws {
        let (store, _) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        XCTAssertThrowsError(try store.moveRepo(id: "nope", toSection: nil, atIndex: 0))
    }

    // MARK: - Reconcile-and-persist (Task 5b)

    func testAddRepositoryAppendsLooseRootRef() throws {
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r1 = try store.addRepository(path: "/tmp/rp-r1")
        let r2 = try store.addRepository(path: "/tmp/rp-r2")
        XCTAssertEqual(store.state.rootOrder, [.repo(r1.id), .repo(r2.id)])
        XCTAssertEqual(cfg.load().rootOrder, [.repo(r1.id), .repo(r2.id)])   // persisted
    }

    func testInitReconcilesLegacyStateWithEmptyRootOrder() throws {
        // Simulate a pre-sections local.json: repositories present, no rootOrder/sections.
        let cfgURL = URL(fileURLWithPath: NSTemporaryDirectory() + "legacy-" + UUID().uuidString + ".json")
        let seed = LocalState(repositories: [Repository(id: "r1", path: "/tmp/l1", name: "l1"),
                                             Repository(id: "r2", path: "/tmp/l2", name: "l2")],
                              worktrees: [])
        try Config(url: cfgURL).save(seed)
        // Fresh store over that file reconciles on init and persists the full rootOrder.
        let store = WorktreeStore(config: Config(url: cfgURL),
                                  git: GitWorktree(gitPath: "/usr/bin/git"),
                                  worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        XCTAssertEqual(store.state.rootOrder, [.repo("r1"), .repo("r2")])
        XCTAssertEqual(Config(url: cfgURL).load().rootOrder, [.repo("r1"), .repo("r2")])
    }

    func testRemoveRepositoryDropsRootRef() throws {
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r1 = try store.addRepository(path: "/tmp/rr-r1")
        let r2 = try store.addRepository(path: "/tmp/rr-r2")
        _ = try store.removeRepository(id: r1.id)
        XCTAssertEqual(store.state.rootOrder, [.repo(r2.id)])
        XCTAssertEqual(cfg.load().rootOrder, [.repo(r2.id)])
    }

    func testRemoveRepositoryDropsSectionMembership() throws {
        let (store, _) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r1 = try store.addRepository(path: "/tmp/rm-r1")
        let s = try store.createSection(name: "Work")
        try store.moveRepo(id: r1.id, toSection: s.id, atIndex: 0)
        _ = try store.removeRepository(id: r1.id)
        XCTAssertEqual(store.state.sections.first { $0.id == s.id }?.repoIDs, [])
    }

    func testInitDoesNotRewriteAlreadyCanonicalState() throws {
        // Second construction over already-canonical state should be a no-op (idempotent).
        let (store, cfg) = makeStore(worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        let r1 = try store.addRepository(path: "/tmp/idem-r1")
        let before = cfg.load().rootOrder
        // Re-open a store over the same config; rootOrder is already canonical → unchanged.
        let store2 = WorktreeStore(config: cfg,
                                   git: GitWorktree(gitPath: "/usr/bin/git"),
                                   worktreeRoot: NSTemporaryDirectory() + "wtr-" + UUID().uuidString)
        XCTAssertEqual(store2.state.rootOrder, before)
        XCTAssertEqual(store2.state.rootOrder, [.repo(r1.id)])
    }
}
