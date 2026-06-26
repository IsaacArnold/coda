import XCTest
@testable import ConductorCore

final class PaneGeometryTests: XCTestCase {
    // Layout (top-left origin, y down):
    //   A(0,0,100,100)  B(100,0,100,100)   ← A left of B
    //   C(0,100,100,100)                    ← C below A
    private let frames = [
        PaneRect(id: "A", x: 0, y: 0, width: 100, height: 100),
        PaneRect(id: "B", x: 100, y: 0, width: 100, height: 100),
        PaneRect(id: "C", x: 0, y: 100, width: 100, height: 100),
    ]

    func testRightOfAIsB() {
        XCTAssertEqual(nearestPane(from: "A", direction: .right, frames: frames), "B")
    }
    func testDownOfAIsC() {
        XCTAssertEqual(nearestPane(from: "A", direction: .down, frames: frames), "C")
    }
    func testLeftOfBIsA() {
        XCTAssertEqual(nearestPane(from: "B", direction: .left, frames: frames), "A")
    }
    func testUpOfCIsA() {
        XCTAssertEqual(nearestPane(from: "C", direction: .up, frames: frames), "A")
    }
    func testNothingToTheLeftOfAReturnsNil() {
        XCTAssertNil(nearestPane(from: "A", direction: .left, frames: frames))
    }
    func testUnknownFocusReturnsNil() {
        XCTAssertNil(nearestPane(from: "Z", direction: .right, frames: frames))
    }
    func testPicksNearestByCenterDistance() {
        // Two panes to the right; the closer one wins.
        let fs = [
            PaneRect(id: "A", x: 0, y: 0, width: 50, height: 50),
            PaneRect(id: "near", x: 60, y: 0, width: 50, height: 50),
            PaneRect(id: "far", x: 200, y: 0, width: 50, height: 50),
        ]
        XCTAssertEqual(nearestPane(from: "A", direction: .right, frames: fs), "near")
    }
}
