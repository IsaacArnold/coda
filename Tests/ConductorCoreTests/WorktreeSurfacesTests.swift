import XCTest
@testable import ConductorCore

final class WorktreeSurfacesTests: XCTestCase {
    private func make() -> WorktreeSurfaces<String> { WorktreeSurfaces<String>() }

    func testAddAppendsAfterActiveAndActivatesIt() {
        let s = make()
        s.add("hA", surface: Surface(id: "a"))
        s.add("hB", surface: Surface(id: "b"))
        // Re-activate a, then add c: it should land between a and b.
        s.setActive(id: "a")
        s.add("hC", surface: Surface(id: "c"))
        XCTAssertEqual(s.entries.map { $0.surface.id }, ["a", "c", "b"])
        XCTAssertEqual(s.activeSurfaceID, "c")
    }

    func testAddToEmptyActivatesAndAppends() {
        let s = make()
        s.add("hA", surface: Surface(id: "a"))
        XCTAssertEqual(s.activeSurfaceID, "a")
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.activeHandle, "hA")
    }

    func testCloseActiveSelectsRightNeighbor() {
        let s = make()
        ["a", "b", "c"].forEach { s.add("h\($0)", surface: Surface(id: $0)) }
        s.setActive(id: "b")
        let removed = s.close(id: "b")
        XCTAssertEqual(removed, "hb")
        XCTAssertEqual(s.activeSurfaceID, "c")   // right neighbor
        XCTAssertEqual(s.entries.map { $0.surface.id }, ["a", "c"])
    }

    func testClosingLastActiveSelectsLeftNeighbor() {
        let s = make()
        ["a", "b"].forEach { s.add("h\($0)", surface: Surface(id: $0)) }
        s.setActive(id: "b")
        _ = s.close(id: "b")
        XCTAssertEqual(s.activeSurfaceID, "a")   // no right → left
    }

    func testClosingOnlySurfaceEmptiesAndClearsActive() {
        let s = make()
        s.add("hA", surface: Surface(id: "a"))
        _ = s.close(id: "a")
        XCTAssertTrue(s.isEmpty)
        XCTAssertNil(s.activeSurfaceID)
    }

    func testClosingNonActiveLeavesActiveUntouched() {
        let s = make()
        ["a", "b", "c"].forEach { s.add("h\($0)", surface: Surface(id: $0)) }
        s.setActive(id: "a")
        _ = s.close(id: "c")
        XCTAssertEqual(s.activeSurfaceID, "a")
    }

    func testNextAndPrevWrapAround() {
        let s = make()
        ["a", "b", "c"].forEach { s.add("h\($0)", surface: Surface(id: $0)) }
        s.setActive(id: "c")
        XCTAssertEqual(s.next(), "a")   // wrap forward
        XCTAssertEqual(s.prev(), "c")   // wrap backward
    }

    func testGoToIndexIsBoundsChecked() {
        let s = make()
        ["a", "b"].forEach { s.add("h\($0)", surface: Surface(id: $0)) }
        XCTAssertEqual(s.goTo(index: 0), "a")
        XCTAssertEqual(s.goTo(index: 5), "a")   // out of range → no change
        XCTAssertEqual(s.activeSurfaceID, "a")
    }

    func testRenameAndSetColorMutateMetadata() {
        let s = make()
        s.add("hA", surface: Surface(id: "a"))
        s.rename(id: "a", to: "logs")
        s.setColor(id: "a", to: RGB(r: 0, g: 1, b: 0))
        XCTAssertEqual(s.entry(for: "a")?.surface.nameOverride, "logs")
        XCTAssertEqual(s.entry(for: "a")?.surface.colorOverride, RGB(r: 0, g: 1, b: 0))
    }

    func testSetActiveIgnoresUnknownID() {
        let s = make()
        s.add("hA", surface: Surface(id: "a"))
        s.setActive(id: "ghost")
        XCTAssertEqual(s.activeSurfaceID, "a")
    }
}
