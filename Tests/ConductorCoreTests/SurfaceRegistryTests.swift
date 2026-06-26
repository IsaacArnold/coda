import XCTest
@testable import ConductorCore

final class SurfaceRegistryTests: XCTestCase {
    func testSurfacesForNewWorktreeIsCreatedEmpty() {
        let registry = SurfaceRegistry<String>()
        let list = registry.surfaces(for: "wt1")
        XCTAssertTrue(list.isEmpty)
        // Same instance returned on re-access (mutations persist).
        registry.surfaces(for: "wt1").add("h", surface: Surface(id: "s1"))
        XCTAssertEqual(registry.surfaces(for: "wt1").count, 1)
    }

    func testExistingSurfacesIsNilUntilCreated() {
        let registry = SurfaceRegistry<String>()
        XCTAssertNil(registry.existingSurfaces(for: "wt1"))
        _ = registry.surfaces(for: "wt1")
        XCTAssertNotNil(registry.existingSurfaces(for: "wt1"))
    }

    func testActiveSelectionTracksTheActiveWorktree() {
        let registry = SurfaceRegistry<String>()
        XCTAssertNil(registry.activeWorktreeID)
        registry.setActive("wt1")
        XCTAssertEqual(registry.activeWorktreeID, "wt1")
        registry.setActive(nil)
        XCTAssertNil(registry.activeWorktreeID)
    }

    func testEvictReturnsAllHandlesAndRemovesTheWorktree() {
        let registry = SurfaceRegistry<String>()
        let list = registry.surfaces(for: "wt1")
        list.add("h1", surface: Surface(id: "s1"))
        list.add("h2", surface: Surface(id: "s2"))
        let evicted = registry.evict(worktreeID: "wt1")
        XCTAssertEqual(evicted.sorted(), ["h1", "h2"])
        XCTAssertNil(registry.existingSurfaces(for: "wt1"))
    }

    func testEvictingTheActiveWorktreeClearsActive() {
        let registry = SurfaceRegistry<String>()
        _ = registry.surfaces(for: "wt1")
        registry.setActive("wt1")
        _ = registry.evict(worktreeID: "wt1")
        XCTAssertNil(registry.activeWorktreeID)
    }

    func testEvictingNonActiveLeavesActiveUntouched() {
        let registry = SurfaceRegistry<String>()
        _ = registry.surfaces(for: "wt1")
        _ = registry.surfaces(for: "wt2")
        registry.setActive("wt1")
        _ = registry.evict(worktreeID: "wt2")
        XCTAssertEqual(registry.activeWorktreeID, "wt1")
    }

    func testEvictingMissingWorktreeReturnsEmpty() {
        let registry = SurfaceRegistry<String>()
        XCTAssertEqual(registry.evict(worktreeID: "ghost"), [])
    }

    func testWorktreeIDsListsWorktreesWithSurfaceLists() {
        let registry = SurfaceRegistry<String>()
        _ = registry.surfaces(for: "wt1")
        _ = registry.surfaces(for: "wt2")
        XCTAssertEqual(Set(registry.worktreeIDs), ["wt1", "wt2"])
    }
}
