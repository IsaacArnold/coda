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

    func testLocalBranchesListsEveryLocalBranch() throws {
        let repo = try makeTempRepo()   // starts with branch "main"
        _ = try ProcessRunner.run("/usr/bin/git", ["-C", repo, "branch", "feature-a"], cwd: nil)
        _ = try ProcessRunner.run("/usr/bin/git", ["-C", repo, "branch", "feature-b"], cwd: nil)
        let git = GitWorktree(gitPath: "/usr/bin/git")
        XCTAssertEqual(Set(try git.localBranches(repo: repo)), ["main", "feature-a", "feature-b"])
    }

    func testDiffSinceForkShowsCommittedAndUncommitted() throws {
        let repo = try makeTempRepo()                       // one commit on main, README.md="hello"
        let git = GitWorktree(gitPath: "/usr/bin/git")
        // Branch off, commit a change, then leave an uncommitted change.
        _ = try ProcessRunner.run("/usr/bin/git", ["-C", repo, "checkout", "-b", "feat"], cwd: nil)
        try "hello\ncommitted".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run("/usr/bin/git", ["-C", repo, "commit", "-am", "c"], cwd: nil)
        try "hello\ncommitted\nuncommitted".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)

        let mb = try git.mergeBase(dir: repo, "main", "HEAD")
        XCTAssertNotNil(mb)
        let patch = try git.diffPatch(dir: repo, against: mb!)
        XCTAssertTrue(patch.contains("+committed"))
        XCTAssertTrue(patch.contains("+uncommitted"))
    }

    func testMergeBaseNilForUnrelatedRef() throws {
        let repo = try makeTempRepo()
        let git = GitWorktree(gitPath: "/usr/bin/git")
        XCTAssertNil(try git.mergeBase(dir: repo, "HEAD", "does-not-exist"))
    }

    func testUntrackedEnumerationAndPatch() throws {
        let repo = try makeTempRepo()
        let git = GitWorktree(gitPath: "/usr/bin/git")
        try "brand new".write(toFile: repo + "/fresh.txt", atomically: true, encoding: .utf8)
        XCTAssertEqual(try git.untrackedFiles(dir: repo), ["fresh.txt"])
        let patch = try git.untrackedPatch(dir: repo, path: "fresh.txt")
        XCTAssertTrue(patch.contains("+brand new"))
        XCTAssertTrue(patch.contains("fresh.txt"))
    }

    func testNumstatCounts() throws {
        let repo = try makeTempRepo()
        let git = GitWorktree(gitPath: "/usr/bin/git")
        try "hello\nmore".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        let ns = try git.numstat(dir: repo, against: "HEAD")
        XCTAssertTrue(ns.contains("README.md"))
    }

    func testDiffPatchLeavesNonASCIIFilenamesUnquoted() throws {
        // git's default core.quotePath=true octal-escapes non-ASCII paths in `diff --git` headers
        // (e.g. "a/caf\303\251.txt"), which the pane's parser cannot split on " b/" to find. Confirm
        // diffPatch passes `-c core.quotePath=false` so the header comes through unquoted.
        let repo = try makeTempRepo()
        let git = GitWorktree(gitPath: "/usr/bin/git")
        try "café".write(toFile: repo + "/café.txt", atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run("/usr/bin/git", ["-C", repo, "add", "café.txt"], cwd: nil)
        _ = try ProcessRunner.run("/usr/bin/git", ["-C", repo, "commit", "-m", "add café.txt"], cwd: nil)
        try "café\nmodified".write(toFile: repo + "/café.txt", atomically: true, encoding: .utf8)

        let patch = try git.diffPatch(dir: repo, against: "HEAD")
        XCTAssertTrue(patch.contains("café.txt"), "expected unquoted café.txt in patch, got:\n\(patch)")
        XCTAssertFalse(patch.contains("caf\\303\\251"), "path should not be octal-quoted:\n\(patch)")
    }
}
