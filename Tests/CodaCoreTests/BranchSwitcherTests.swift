import XCTest
@testable import CodaCore

final class BranchSwitcherTests: XCTestCase {
    private let gitPath = "/usr/bin/git"
    private var git: GitWorktree { GitWorktree(gitPath: gitPath) }
    private var switcher: BranchSwitcher { BranchSwitcher(git: git) }

    private func run(_ dir: String, _ args: [String]) throws {
        _ = try ProcessRunner.run(gitPath, ["-C", dir] + args, cwd: nil)
    }

    private func read(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    // MARK: switching

    func testCleanSwitchDoesNotStash() throws {
        let repo = try makeTempRepo()
        try run(repo, ["branch", "b"])
        let outcome = try switcher.switchBranch(in: repo, to: "b")
        XCTAssertEqual(outcome, .switched)
        XCTAssertEqual(try git.currentBranch(repo: repo), "b")
        XCTAssertTrue(try git.stashList(repo: repo).isEmpty)
    }

    func testDirtySwitchStashesAndSwitchesWithoutAsking() throws {
        let repo = try makeTempRepo()
        try run(repo, ["branch", "b"])
        try "edited".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        try "new".write(toFile: repo + "/untracked.txt", atomically: true, encoding: .utf8)

        let outcome = try switcher.switchBranch(in: repo, to: "b")

        XCTAssertEqual(outcome, .switchedAndStashed(from: "main"))
        XCTAssertEqual(try git.currentBranch(repo: repo), "b")
        XCTAssertFalse(try git.hasUncommittedChanges(repo: repo))
    }

    func testAutoStashIsKeyedToTheBranchYouLeft() throws {
        let repo = try makeTempRepo()
        try run(repo, ["branch", "b"])
        try "edited".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        _ = try switcher.switchBranch(in: repo, to: "b")

        let stashed = try switcher.branchesWithAutoStash(in: repo)
        XCTAssertEqual(stashed, ["main"])
    }

    func testFailedSwitchPutsChangesBack() throws {
        let repo = try makeTempRepo()
        try "edited".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try switcher.switchBranch(in: repo, to: "does-not-exist"))

        XCTAssertEqual(try git.currentBranch(repo: repo), "main")
        XCTAssertEqual(read(repo + "/README.md"), "edited")
        XCTAssertTrue(try git.stashList(repo: repo).isEmpty)
    }

    func testManualStashesAreNotTreatedAsAutoStashes() throws {
        let repo = try makeTempRepo()
        try "edited".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        try git.stashSave(repo: repo, message: "my own stash")
        XCTAssertTrue(try switcher.branchesWithAutoStash(in: repo).isEmpty)
    }

    // MARK: restoring

    func testComingBackAndRestoringBringsChangesBackAndDeletesStash() throws {
        let repo = try makeTempRepo()
        try run(repo, ["branch", "b"])
        try "edited".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        try "new".write(toFile: repo + "/untracked.txt", atomically: true, encoding: .utf8)
        _ = try switcher.switchBranch(in: repo, to: "b")
        _ = try switcher.switchBranch(in: repo, to: "main")

        try switcher.restoreAutoStash(for: "main", in: repo)

        XCTAssertEqual(read(repo + "/README.md"), "edited")
        XCTAssertEqual(read(repo + "/untracked.txt"), "new")
        XCTAssertTrue(try git.stashList(repo: repo).isEmpty)
        XCTAssertTrue(try switcher.branchesWithAutoStash(in: repo).isEmpty)
    }

    func testRestorePicksTheStashForThatBranchNotTheNewest() throws {
        let repo = try makeTempRepo()
        try run(repo, ["branch", "b"])
        try "from main".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        _ = try switcher.switchBranch(in: repo, to: "b")           // stash for main
        try "from b".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        _ = try switcher.switchBranch(in: repo, to: "main")        // stash for b (now newest)

        try switcher.restoreAutoStash(for: "main", in: repo)

        XCTAssertEqual(read(repo + "/README.md"), "from main")
        XCTAssertEqual(try switcher.branchesWithAutoStash(in: repo), ["b"])
    }

    func testRestoreWithNoAutoStashThrows() throws {
        let repo = try makeTempRepo()
        XCTAssertThrowsError(try switcher.restoreAutoStash(for: "main", in: repo)) { error in
            XCTAssertEqual(error as? BranchSwitchError, .nothingToRestore("main"))
        }
    }

    /// Stash on main, hop to b and back, then commit a clashing edit to README on main.
    private func makeRepoWithClashingAutoStash() throws -> String {
        let repo = try makeTempRepo()
        try run(repo, ["branch", "b"])
        try "stashed edit".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        try "kept".write(toFile: repo + "/other.txt", atomically: true, encoding: .utf8)
        _ = try switcher.switchBranch(in: repo, to: "b")
        _ = try switcher.switchBranch(in: repo, to: "main")
        try "conflicting commit".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        try run(repo, ["commit", "-am", "move on"])
        return repo
    }

    func testClashingRestoreReportsTheConflictedFiles() throws {
        let repo = try makeRepoWithClashingAutoStash()
        XCTAssertThrowsError(try switcher.restoreAutoStash(for: "main", in: repo)) { error in
            XCTAssertEqual(error as? BranchSwitchError,
                           .partiallyRestored("main", conflicted: ["README.md"], skipped: []))
        }
        XCTAssertEqual(read(repo + "/other.txt"), "kept")   // the non-clashing part came back
    }

    func testClashingRestoreStopsOfferingTheStashButKeepsABackup() throws {
        let repo = try makeRepoWithClashingAutoStash()
        _ = try? switcher.restoreAutoStash(for: "main", in: repo)

        XCTAssertTrue(try switcher.branchesWithAutoStash(in: repo).isEmpty)
        let stashes = try git.stashList(repo: repo)
        XCTAssertEqual(stashes.count, 1)
        XCTAssertEqual(stashes.first?.branch, "main")
        XCTAssertTrue(stashes.first?.message.contains(BranchSwitcher.backupMarker) == true)
    }

    func testRestoreSkippingAnExistingNewFileReportsItAndKeepsABackup() throws {
        let repo = try makeTempRepo()
        try run(repo, ["branch", "b"])
        try "edited".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        try "stashed".write(toFile: repo + "/new.txt", atomically: true, encoding: .utf8)
        _ = try switcher.switchBranch(in: repo, to: "b")
        _ = try switcher.switchBranch(in: repo, to: "main")
        try "already here".write(toFile: repo + "/new.txt", atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try switcher.restoreAutoStash(for: "main", in: repo)) { error in
            XCTAssertEqual(error as? BranchSwitchError,
                           .partiallyRestored("main", conflicted: [], skipped: ["new.txt"]))
        }
        XCTAssertEqual(read(repo + "/README.md"), "edited")
        XCTAssertEqual(read(repo + "/new.txt"), "already here")
        XCTAssertTrue(try switcher.branchesWithAutoStash(in: repo).isEmpty)
    }

    func testRestoreBlockedByNewEditsChangesNothingAndKeepsOffering() throws {
        let repo = try makeTempRepo()
        try run(repo, ["branch", "b"])
        try "stashed edit".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        _ = try switcher.switchBranch(in: repo, to: "b")
        _ = try switcher.switchBranch(in: repo, to: "main")
        try "fresh edit".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try switcher.restoreAutoStash(for: "main", in: repo)) { error in
            XCTAssertEqual(error as? BranchSwitchError, .restoreBlocked("main"))
        }
        XCTAssertEqual(read(repo + "/README.md"), "fresh edit")
        XCTAssertEqual(try switcher.branchesWithAutoStash(in: repo), ["main"])
    }

    // MARK: worktrees

    func testSwitchActsOnTheWorktreeItIsGiven() throws {
        let repo = try makeTempRepo()
        let wt = NSTemporaryDirectory() + "coda-wt-" + UUID().uuidString
        try git.add(repo: repo, path: wt, branch: "feature", base: "main")
        try run(repo, ["branch", "other"])
        try "wt edit".write(toFile: wt + "/README.md", atomically: true, encoding: .utf8)

        _ = try switcher.switchBranch(in: wt, to: "other")

        XCTAssertEqual(try git.currentBranch(repo: wt), "other")
        XCTAssertEqual(try git.currentBranch(repo: repo), "main")
        XCTAssertFalse(try git.hasUncommittedChanges(repo: repo))
        XCTAssertEqual(try switcher.branchesWithAutoStash(in: repo), ["feature"])
    }
}
