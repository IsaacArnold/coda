import XCTest
@testable import CodaCore

final class SidebarLayoutTests: XCTestCase {
    private func repo(_ id: String) -> Repository {
        Repository(id: id, path: "/tmp/\(id)", name: id)
    }

    // MARK: reconcileSidebarLayout

    func testFreshUpgradeAppendsAllReposLooseInOrder() {
        // No sections, empty rootOrder → every repo becomes a loose .repo ref in array order.
        let r = reconcileSidebarLayout(repositories: [repo("r1"), repo("r2"), repo("r3")],
                                       sections: [], rootOrder: [])
        XCTAssertEqual(r.rootOrder, [.repo("r1"), .repo("r2"), .repo("r3")])
        XCTAssertTrue(r.sections.isEmpty)
    }

    func testRepoInSectionIsNotAlsoLoose() {
        let sections = [SidebarSection(id: "s1", name: "Work", repoIDs: ["r1"])]
        let r = reconcileSidebarLayout(repositories: [repo("r1"), repo("r2")],
                                       sections: sections,
                                       rootOrder: [.section("s1")])
        // r1 lives in s1; only r2 is appended loose. s1 stays at root, r2 after it.
        XCTAssertEqual(r.rootOrder, [.section("s1"), .repo("r2")])
        XCTAssertEqual(r.sections.first?.repoIDs, ["r1"])
    }

    func testDanglingRepoIDsAreDroppedFromSections() {
        let sections = [SidebarSection(id: "s1", name: "Work", repoIDs: ["r1", "gone"])]
        let r = reconcileSidebarLayout(repositories: [repo("r1")],
                                       sections: sections, rootOrder: [.section("s1")])
        XCTAssertEqual(r.sections.first?.repoIDs, ["r1"])
    }

    func testDanglingRootRefsAreDropped() {
        // rootOrder references a missing section and a missing repo.
        let r = reconcileSidebarLayout(repositories: [repo("r1")],
                                       sections: [],
                                       rootOrder: [.section("ghost"), .repo("missing"), .repo("r1")])
        XCTAssertEqual(r.rootOrder, [.repo("r1")])
    }

    func testRepoClaimedByFirstSectionWhenListedInTwo() {
        let sections = [
            SidebarSection(id: "s1", name: "A", repoIDs: ["r1"]),
            SidebarSection(id: "s2", name: "B", repoIDs: ["r1"]),
        ]
        let r = reconcileSidebarLayout(repositories: [repo("r1")],
                                       sections: sections,
                                       rootOrder: [.section("s1"), .section("s2")])
        XCTAssertEqual(r.sections.first(where: { $0.id == "s1" })?.repoIDs, ["r1"])
        XCTAssertEqual(r.sections.first(where: { $0.id == "s2" })?.repoIDs, [])
    }

    func testUnreferencedSectionAppendedAtRoot() {
        let sections = [SidebarSection(id: "s1", name: "Orphan", repoIDs: [])]
        let r = reconcileSidebarLayout(repositories: [repo("r1")],
                                       sections: sections, rootOrder: [.repo("r1")])
        XCTAssertEqual(r.rootOrder, [.repo("r1"), .section("s1")])
    }

    func testInterleavedOrderPreserved() {
        let sections = [SidebarSection(id: "s1", name: "Work", repoIDs: ["r2"])]
        let r = reconcileSidebarLayout(repositories: [repo("r1"), repo("r2"), repo("r3")],
                                       sections: sections,
                                       rootOrder: [.repo("r1"), .section("s1"), .repo("r3")])
        XCTAssertEqual(r.rootOrder, [.repo("r1"), .section("s1"), .repo("r3")])
    }

    func testDuplicateRootRefsCollapseToFirst() {
        let r = reconcileSidebarLayout(repositories: [repo("r1")],
                                       sections: [],
                                       rootOrder: [.repo("r1"), .repo("r1")])
        XCTAssertEqual(r.rootOrder, [.repo("r1")])
    }

    func testDuplicateRepoIDsInInputAppearOnceLoose() {
        // Two `repositories` entries sharing an id (distinct paths), unreferenced
        // by any section/rootOrder, must still surface exactly once loose.
        let repos = [
            Repository(id: "r1", path: "/tmp/r1-a", name: "r1-a"),
            Repository(id: "r1", path: "/tmp/r1-b", name: "r1-b"),
        ]
        let r = reconcileSidebarLayout(repositories: repos, sections: [], rootOrder: [])
        XCTAssertEqual(r.rootOrder, [.repo("r1")])
    }

    func testDuplicateSectionIDsFoldFirstWins() {
        // Two sections share id "s1"; first-wins folding happens before repos are
        // claimed, so the second section's repo (r2) is never claimed by the
        // dropped duplicate and must be appended loose instead of vanishing.
        let sections = [
            SidebarSection(id: "s1", name: "First", repoIDs: ["r1"]),
            SidebarSection(id: "s1", name: "Second", repoIDs: ["r2"]),
        ]
        let r = reconcileSidebarLayout(repositories: [repo("r1"), repo("r2")],
                                       sections: sections,
                                       rootOrder: [.section("s1")])
        let matching = r.sections.filter { $0.id == "s1" }
        XCTAssertEqual(matching.count, 1)
        XCTAssertEqual(matching.first?.repoIDs, ["r1"])
        XCTAssertTrue(r.rootOrder.contains(.repo("r2")))
    }

    // MARK: buildSidebarTree

    private func wt(_ id: String, _ repoID: String) -> Worktree {
        Worktree(id: id, repoID: repoID, title: id, branch: id, worktreePath: "/tmp/wt/\(id)")
    }

    func testTreeGroupsReposUnderSectionsAndKeepsLooseReposAtRoot() {
        let repos = [repo("r1"), repo("r2"), repo("r3")]
        let sections = [SidebarSection(id: "s1", name: "Work", repoIDs: ["r1", "r2"])]
        let tree = buildSidebarTree(repositories: repos, worktrees: [],
                                    sections: sections,
                                    rootOrder: [.section("s1"), .repo("r3")],
                                    branchForRepo: ["r1": "main", "r2": "main", "r3": "main"])
        guard case let .section(sd) = tree[0] else { return XCTFail("expected section first") }
        XCTAssertEqual(sd.section.name, "Work")
        XCTAssertEqual(sd.repos.map { $0.repository.id }, ["r1", "r2"])
        guard case let .repo(rs) = tree[1] else { return XCTFail("expected loose repo second") }
        XCTAssertEqual(rs.repository.id, "r3")
    }

    func testTreeReposCarryMainCheckoutFirst() {
        let tree = buildSidebarTree(repositories: [repo("r1")], worktrees: [wt("w1", "r1")],
                                    sections: [], rootOrder: [.repo("r1")],
                                    branchForRepo: ["r1": "main"])
        guard case let .repo(rs) = tree[0] else { return XCTFail() }
        XCTAssertEqual(rs.worktrees.map { $0.id }, ["r1#main", "w1"])
        XCTAssertTrue(rs.worktrees[0].isMain)
        XCTAssertEqual(rs.worktrees[0].branch, "main")
    }

    func testBuildTreeToleratesDuplicateRepoIDs() {
        // Two `repositories` entries sharing id "r1" (distinct paths). Must not
        // trap when buildSidebarTree constructs its repo lookup, and must yield
        // exactly one `.repo` root item whose repository is the first "r1" entry.
        let repos = [
            Repository(id: "r1", path: "/tmp/r1-a", name: "r1-a"),
            Repository(id: "r1", path: "/tmp/r1-b", name: "r1-b"),
        ]
        let tree = buildSidebarTree(repositories: repos, worktrees: [],
                                    sections: [], rootOrder: [],
                                    branchForRepo: [:])
        XCTAssertEqual(tree.count, 1)
        guard case let .repo(rs) = tree[0] else { return XCTFail("expected a loose repo item") }
        XCTAssertEqual(rs.repository.id, "r1")
        XCTAssertEqual(rs.repository.path, "/tmp/r1-a")
    }

    func testTreeReconcilesUnreferencedRepoAsLoose() {
        // r2 exists but is referenced nowhere → appears loose at the end.
        let tree = buildSidebarTree(repositories: [repo("r1"), repo("r2")], worktrees: [],
                                    sections: [], rootOrder: [.repo("r1")],
                                    branchForRepo: [:])
        XCTAssertEqual(tree.count, 2)
        guard case let .repo(rs) = tree[1] else { return XCTFail() }
        XCTAssertEqual(rs.repository.id, "r2")
    }
}
