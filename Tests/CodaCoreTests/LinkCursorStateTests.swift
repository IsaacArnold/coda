import XCTest
@testable import CodaCore

/// ⌘-hover pointing-hand bookkeeping. Releasing ⌘ arrives as a `flagsChanged` event, for
/// which AppKit re-applies no cursor rects — so whoever set the hand must restore the cursor.
final class LinkCursorStateTests: XCTestCase {
    func testOverLinkShowsHand() {
        var s = LinkCursorState()
        XCTAssertEqual(s.update(overLink: true, overTerminal: true), .pointingHand)
    }

    func testNothingToDoWhenHandWasNeverShown() {
        var s = LinkCursorState()
        XCTAssertEqual(s.update(overLink: false, overTerminal: true), LinkCursorAction.none)
    }

    func testLeavingLinkOverTerminalRestoresIBeamOnce() {
        var s = LinkCursorState()
        _ = s.update(overLink: true, overTerminal: true)
        XCTAssertEqual(s.update(overLink: false, overTerminal: true), .iBeam)
        XCTAssertEqual(s.update(overLink: false, overTerminal: true), LinkCursorAction.none)
    }

    func testLeavingLinkOutsideTerminalRestoresArrow() {
        var s = LinkCursorState()
        _ = s.update(overLink: true, overTerminal: true)
        XCTAssertEqual(s.update(overLink: false, overTerminal: false), .arrow)
    }

    func testStayingOverLinkKeepsReassertingHand() {
        // The window re-applies SwiftTerm's I-beam rect on every mouse move, so the hand
        // must be re-set each time, not just on the first entry.
        var s = LinkCursorState()
        _ = s.update(overLink: true, overTerminal: true)
        XCTAssertEqual(s.update(overLink: true, overTerminal: true), .pointingHand)
    }
}
