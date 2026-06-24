import XCTest
import Foundation
@testable import ConductorCore

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
}
