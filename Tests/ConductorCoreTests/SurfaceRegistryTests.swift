import XCTest
@testable import ConductorCore

final class SurfaceRegistryTests: XCTestCase {
    func testRegisterThenLookupReturnsHandle() {
        let registry = SurfaceRegistry<String>()
        registry.register("surface-A", for: "wt1")
        XCTAssertEqual(registry.handle(for: "wt1"), "surface-A")
    }

    func testLookupMissingWorktreeReturnsNil() {
        let registry = SurfaceRegistry<String>()
        XCTAssertNil(registry.handle(for: "nope"))
    }

    func testRegisteringSameWorktreeKeepsASingleEntry() {
        let registry = SurfaceRegistry<String>()
        registry.register("first", for: "wt1")
        registry.register("second", for: "wt1")
        XCTAssertEqual(registry.count, 1)
        XCTAssertEqual(registry.handle(for: "wt1"), "second")
    }

    func testActiveSelectionTracksTheActiveWorktree() {
        let registry = SurfaceRegistry<String>()
        XCTAssertNil(registry.activeWorktreeID)
        registry.setActive("wt1")
        XCTAssertEqual(registry.activeWorktreeID, "wt1")
        registry.setActive("wt2")
        XCTAssertEqual(registry.activeWorktreeID, "wt2")
    }

    func testReselectingTheSameActiveWorktreeIsIdempotent() {
        let registry = SurfaceRegistry<String>()
        registry.register("surface-A", for: "wt1")
        registry.setActive("wt1")
        registry.setActive("wt1")
        XCTAssertEqual(registry.activeWorktreeID, "wt1")
        XCTAssertEqual(registry.count, 1)
        XCTAssertEqual(registry.handle(for: "wt1"), "surface-A")
    }

    func testEvictRemovesAndReturnsHandle() {
        let registry = SurfaceRegistry<String>()
        registry.register("surface-A", for: "wt1")
        let evicted = registry.evict(worktreeID: "wt1")
        XCTAssertEqual(evicted, "surface-A")
        XCTAssertNil(registry.handle(for: "wt1"))
        XCTAssertEqual(registry.count, 0)
    }

    func testEvictingTheActiveWorktreeClearsActive() {
        let registry = SurfaceRegistry<String>()
        registry.register("surface-A", for: "wt1")
        registry.setActive("wt1")
        _ = registry.evict(worktreeID: "wt1")
        XCTAssertNil(registry.activeWorktreeID)
    }

    func testEvictingANonActiveWorktreeLeavesActiveUntouched() {
        let registry = SurfaceRegistry<String>()
        registry.register("a", for: "wt1")
        registry.register("b", for: "wt2")
        registry.setActive("wt1")
        _ = registry.evict(worktreeID: "wt2")
        XCTAssertEqual(registry.activeWorktreeID, "wt1")
        XCTAssertEqual(registry.handle(for: "wt1"), "a")
    }

    func testEvictingMissingWorktreeReturnsNil() {
        let registry = SurfaceRegistry<String>()
        XCTAssertNil(registry.evict(worktreeID: "ghost"))
    }
}
