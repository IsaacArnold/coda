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
}

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
