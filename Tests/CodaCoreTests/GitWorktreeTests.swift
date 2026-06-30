import XCTest
import Foundation
@testable import CodaCore

final class GitWorktreeTests: XCTestCase {
    func testCurrentBranchIsMain() throws {
        let repo = try makeTempRepo()
        let git = GitWorktree(gitPath: "/usr/bin/git")
        XCTAssertEqual(try git.currentBranch(repo: repo), "main")
    }

    func testAddCreatesWorktreeAndBranchThenListsIt() throws {
        let repo = try makeTempRepo()
        let git = GitWorktree(gitPath: "/usr/bin/git")
        let wt = NSTemporaryDirectory() + "wt-" + UUID().uuidString
        try git.add(repo: repo, path: wt, branch: "feature-x", base: "main")

        XCTAssertTrue(FileManager.default.fileExists(atPath: wt + "/README.md"))
        let list = try git.list(repo: repo)
        let wtResolved = URL(fileURLWithPath: wt).resolvingSymlinksInPath().path
        XCTAssertTrue(list.contains { $0.path == wtResolved && $0.branch == "feature-x" })
    }

    func testRemoveDeletesWorktreeAndBranchCanBeDeleted() throws {
        let repo = try makeTempRepo()
        let git = GitWorktree(gitPath: "/usr/bin/git")
        let wt = NSTemporaryDirectory() + "wt-" + UUID().uuidString
        try git.add(repo: repo, path: wt, branch: "feature-y", base: "main")
        try git.remove(repo: repo, path: wt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wt))

        try git.deleteBranch(repo: repo, branch: "feature-y")
        let branches = try ProcessRunner.run("/usr/bin/git", ["-C", repo, "branch", "--list", "feature-y"], cwd: nil)
        XCTAssertTrue(branches.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testSymbolicRefReturnsBranchOnRepoWithNoCommits() throws {
        // `rev-parse --abbrev-ref HEAD` fails on an unborn branch; symbolic-ref still names it.
        let repo = try makeTempRepoNoCommits()
        let git = GitWorktree(gitPath: "/usr/bin/git")
        XCTAssertThrowsError(try git.currentBranch(repo: repo))
        XCTAssertEqual(try git.symbolicRef(repo: repo), "master")
    }

    func testShortHeadReturnsAbbreviatedSHA() throws {
        let repo = try makeTempRepo()
        let git = GitWorktree(gitPath: "/usr/bin/git")
        let sha = try git.shortHead(repo: repo)
        XCTAssertFalse(sha.isEmpty)
        // A short SHA is hex and reasonably short (git defaults to ~7 chars).
        XCTAssertLessThanOrEqual(sha.count, 40)
        XCTAssertTrue(sha.allSatisfy { $0.isHexDigit })
    }
}
