import XCTest
@testable import CodaCore

final class SidebarHoverStateTests: XCTestCase {
    func testStartsWithNoHoveredRow() {
        let state = SidebarHoverState()
        XCTAssertNil(state.hoveredRow)
    }

    func testEnteringARowFromNothingRedrawsThatRow() {
        var state = SidebarHoverState()
        XCTAssertEqual(state.update(to: 3), [3])
        XCTAssertEqual(state.hoveredRow, 3)
    }

    func testMovingBetweenRowsRedrawsVacatedThenEntered() {
        // Both rows change appearance: one loses the wash, one gains it. Order is
        // vacated-first so a caller repainting in sequence never leaves two rows lit.
        var state = SidebarHoverState()
        _ = state.update(to: 3)
        XCTAssertEqual(state.update(to: 4), [3, 4])
        XCTAssertEqual(state.hoveredRow, 4)
    }

    func testReportingTheSameRowRedrawsNothing() {
        // The tracking area fires mouseMoved continuously while the pointer sits on one
        // row; re-reporting it must not churn needsDisplay every event.
        var state = SidebarHoverState()
        _ = state.update(to: 3)
        XCTAssertEqual(state.update(to: 3), [])
        XCTAssertEqual(state.hoveredRow, 3)
    }

    func testLeavingRedrawsOnlyTheVacatedRow() {
        var state = SidebarHoverState()
        _ = state.update(to: 3)
        XCTAssertEqual(state.update(to: nil), [3])
        XCTAssertNil(state.hoveredRow)
    }

    func testLeavingWhenNothingWasHoveredRedrawsNothing() {
        // mouseExited can arrive with no prior hover (e.g. the pointer crossed a gap).
        var state = SidebarHoverState()
        XCTAssertEqual(state.update(to: nil), [])
        XCTAssertNil(state.hoveredRow)
    }
}
