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
}
