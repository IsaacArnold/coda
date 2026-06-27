import XCTest
@testable import ConductorCore

final class WorktreeGroupingTests: XCTestCase {
    private func repo(_ id: String) -> Repository {
        Repository(id: id, path: "/tmp/\(id)", name: id)
    }
    private func wt(_ id: String, _ repoID: String) -> Worktree {
        Worktree(id: id, repoID: repoID, title: id, branch: id, worktreePath: "/tmp/wt/\(id)")
    }

    func testGroupsWorktreesUnderTheirRepositories() {
        let repos = [repo("r1"), repo("r2")]
        let worktrees = [wt("a", "r1"), wt("b", "r2"), wt("c", "r1")]
        let sections = groupWorktreesByRepository(repositories: repos, worktrees: worktrees)

        XCTAssertEqual(sections.map(\.repository.id), ["r1", "r2"])
        XCTAssertEqual(sections[0].worktrees.map(\.id), ["a", "c"])
        XCTAssertEqual(sections[1].worktrees.map(\.id), ["b"])
    }

    func testEmptyRepositoryStillAppearsWithNoWorktrees() {
        let sections = groupWorktreesByRepository(repositories: [repo("r1")], worktrees: [])
        XCTAssertEqual(sections.map(\.repository.id), ["r1"])
        XCTAssertTrue(sections[0].worktrees.isEmpty)
    }

    func testRepositoryAndWorktreeOrderingArePreserved() {
        // Repos keep their given order; worktrees keep their given order within a repo.
        let repos = [repo("r2"), repo("r1")]
        let worktrees = [wt("c", "r1"), wt("a", "r2"), wt("b", "r2")]
        let sections = groupWorktreesByRepository(repositories: repos, worktrees: worktrees)
        XCTAssertEqual(sections.map(\.repository.id), ["r2", "r1"])
        XCTAssertEqual(sections[0].worktrees.map(\.id), ["a", "b"])
        XCTAssertEqual(sections[1].worktrees.map(\.id), ["c"])
    }

    func testWorktreesWithNoMatchingRepositoryAreOmitted() {
        let sections = groupWorktreesByRepository(repositories: [repo("r1")],
                                                  worktrees: [wt("a", "r1"), wt("orphan", "gone")])
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].worktrees.map(\.id), ["a"])
    }

    func testMainCheckoutIsPrependedPerRepo() {
        let r1 = Repository(id: "R1", path: "/tmp/r1", name: "r1")
        let r2 = Repository(id: "R2", path: "/tmp/r2", name: "r2")
        let w = Worktree(id: "W1", repoID: "R1", title: "Feat", branch: "feat",
                         worktreePath: "/tmp/wt/feat")
        let sections = sectionsWithMainCheckouts(
            repositories: [r1, r2], worktrees: [w],
            branchForRepo: ["R1": "main", "R2": "develop"])

        XCTAssertEqual(sections.count, 2)
        // R1: main checkout first, then the real worktree.
        XCTAssertEqual(sections[0].worktrees.map(\.id), ["R1#main", "W1"])
        XCTAssertTrue(sections[0].worktrees[0].isMain)
        XCTAssertEqual(sections[0].worktrees[0].branch, "main")
        XCTAssertEqual(sections[0].worktrees[0].title, "Default")
        XCTAssertFalse(sections[0].worktrees[1].isMain)
        // R2: only its main checkout (no real worktrees), with its own branch.
        XCTAssertEqual(sections[1].worktrees.map(\.id), ["R2#main"])
        XCTAssertEqual(sections[1].worktrees[0].branch, "develop")
    }

    func testMainCheckoutBranchFallsBackToEmptyWhenUnknown() {
        let r1 = Repository(id: "R1", path: "/tmp/r1", name: "r1")
        let sections = sectionsWithMainCheckouts(
            repositories: [r1], worktrees: [], branchForRepo: [:])
        XCTAssertEqual(sections[0].worktrees.count, 1)
        XCTAssertEqual(sections[0].worktrees[0].branch, "")
    }
}
