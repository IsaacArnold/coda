import XCTest
@testable import CodaCore

final class SidebarHoverStateTests: XCTestCase {
    func testStartsWithNoHoveredRow() {
        let state = SidebarHoverState()
        XCTAssertNil(state.hoveredRow)
    }

    func testEnteringARowFromNothingRedrawsThatRow() {
        var state = SidebarHoverState()
        XCTAssertEqual(state.update(to: 3, rowCount: 10), [3])
        XCTAssertEqual(state.hoveredRow, 3)
    }

    func testMovingBetweenRowsRedrawsVacatedThenEntered() {
        // Both rows change appearance: one loses the wash, one gains it. Order is
        // vacated-first so a caller repainting in sequence never leaves two rows lit.
        var state = SidebarHoverState()
        _ = state.update(to: 3, rowCount: 10)
        XCTAssertEqual(state.update(to: 4, rowCount: 10), [3, 4])
        XCTAssertEqual(state.hoveredRow, 4)
    }

    func testReportingTheSameRowRedrawsNothing() {
        // The tracking area fires mouseMoved continuously while the pointer sits on one
        // row; re-reporting it must not churn needsDisplay every event.
        var state = SidebarHoverState()
        _ = state.update(to: 3, rowCount: 10)
        XCTAssertEqual(state.update(to: 3, rowCount: 10), [])
        XCTAssertEqual(state.hoveredRow, 3)
    }

    func testLeavingRedrawsOnlyTheVacatedRow() {
        var state = SidebarHoverState()
        _ = state.update(to: 3, rowCount: 10)
        XCTAssertEqual(state.update(to: nil, rowCount: 10), [3])
        XCTAssertNil(state.hoveredRow)
    }

    func testLeavingWhenNothingWasHoveredRedrawsNothing() {
        // mouseExited can arrive with no prior hover (e.g. the pointer crossed a gap).
        var state = SidebarHoverState()
        XCTAssertEqual(state.update(to: nil, rowCount: 10), [])
        XCTAssertNil(state.hoveredRow)
    }

    // MARK: - Bounds normalization (crash fix)

    func testRowAtOrAboveRowCountNormalizesToNoHover() {
        // A row index equal to rowCount is out of range (valid rows are 0..<rowCount).
        var state = SidebarHoverState()
        _ = state.update(to: 3, rowCount: 5)
        XCTAssertEqual(state.update(to: 5, rowCount: 5), [3])
        XCTAssertNil(state.hoveredRow)
    }

    func testRowWellAboveRowCountNormalizesToNoHover() {
        var state = SidebarHoverState()
        XCTAssertEqual(state.update(to: 999, rowCount: 5), [])
        XCTAssertNil(state.hoveredRow)
    }

    func testNegativeRowNormalizesToNoHover() {
        var state = SidebarHoverState()
        XCTAssertEqual(state.update(to: -1, rowCount: 5), [])
        XCTAssertNil(state.hoveredRow)
    }

    func testNegativeRowClearsAnExistingHover() {
        var state = SidebarHoverState()
        _ = state.update(to: 2, rowCount: 5)
        XCTAssertEqual(state.update(to: -1, rowCount: 5), [2])
        XCTAssertNil(state.hoveredRow)
    }

    func testRowCountZeroMeansNothingCanBeHovered() {
        var state = SidebarHoverState()
        XCTAssertEqual(state.update(to: 0, rowCount: 0), [])
        XCTAssertNil(state.hoveredRow)
    }

    func testRowCountZeroClearsAnExistingHoverWithoutReturningTheStaleIndex() {
        var state = SidebarHoverState()
        _ = state.update(to: 2, rowCount: 5)
        XCTAssertEqual(state.update(to: nil, rowCount: 0), [])
        XCTAssertNil(state.hoveredRow)
    }

    func testShrinkingRowCountDropsTheStaleVacatedRowFromTheRedrawList() {
        // The crash scenario: hover sits on a low-but-now-invalid row (14) while the
        // outline shrinks out from under it (e.g. a repo/section is removed). Any
        // subsequent update must never hand back 14 for repainting — it doesn't exist.
        var state = SidebarHoverState()
        XCTAssertEqual(state.update(to: 14, rowCount: 100), [14])
        XCTAssertEqual(state.hoveredRow, 14)

        XCTAssertEqual(state.update(to: nil, rowCount: 5), [])
        XCTAssertNil(state.hoveredRow)
    }

    func testShrinkingRowCountWhileEnteringAValidRowOmitsTheStaleVacatedRow() {
        var state = SidebarHoverState()
        _ = state.update(to: 14, rowCount: 100)

        // Row 2 is still valid under the shrunk count, so it's the sole redraw target;
        // 14 must not appear even though it's technically "vacated".
        XCTAssertEqual(state.update(to: 2, rowCount: 5), [2])
        XCTAssertEqual(state.hoveredRow, 2)
    }
}
