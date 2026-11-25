import XCTest
@testable import CodaCore

/// Holding PTY size updates back during a live window drag (#80). SwiftTerm re-wraps its own
/// buffer on every frame of the drag; without the gate each frame also became a SIGWINCH, and
/// Claude Code's TUI redrew dozens of times mid-reflow, leaving garbled frames behind.
final class LiveResizePtyGateTests: XCTestCase {
    private let small = PtySize(cols: 80, rows: 24, width: 640, height: 384)
    private let mid = PtySize(cols: 100, rows: 24, width: 800, height: 384)
    private let big = PtySize(cols: 120, rows: 30, width: 960, height: 480)

    func testOutsideLiveResizeReportsTheActualSize() {
        var gate = LiveResizePtyGate()
        XCTAssertEqual(gate.sizeToReport(actual: small, inLiveResize: false), small)
        XCTAssertEqual(gate.sizeToReport(actual: big, inLiveResize: false), big)
    }

    func testDuringLiveResizeKeepsReportingTheLastCommittedSize() {
        var gate = LiveResizePtyGate()
        _ = gate.sizeToReport(actual: small, inLiveResize: false)
        XCTAssertEqual(gate.sizeToReport(actual: mid, inLiveResize: true), small)
        XCTAssertEqual(gate.sizeToReport(actual: big, inLiveResize: true), small)
    }

    func testEndOfLiveResizeCommitsTheFinalSizeOnce() {
        var gate = LiveResizePtyGate()
        _ = gate.sizeToReport(actual: small, inLiveResize: false)
        _ = gate.sizeToReport(actual: big, inLiveResize: true)
        XCTAssertEqual(gate.endLiveResize(actual: big), big)
        XCTAssertNil(gate.endLiveResize(actual: big), "nothing more to push")
        XCTAssertEqual(gate.sizeToReport(actual: big, inLiveResize: false), big)
    }

    func testDragThatEndsWhereItStartedPushesNothing() {
        var gate = LiveResizePtyGate()
        _ = gate.sizeToReport(actual: small, inLiveResize: false)
        _ = gate.sizeToReport(actual: big, inLiveResize: true)
        XCTAssertNil(gate.endLiveResize(actual: small))
    }

    func testFirstReportDuringLiveResizeIsTheActualSize() {
        // A pane created mid-drag has no committed size yet; the PTY must still get a real one.
        var gate = LiveResizePtyGate()
        XCTAssertEqual(gate.sizeToReport(actual: mid, inLiveResize: true), mid)
        XCTAssertEqual(gate.sizeToReport(actual: big, inLiveResize: true), mid)
    }
}
