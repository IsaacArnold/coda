import XCTest
@testable import CodaCore

final class ShellIntegrationStatusTests: XCTestCase {
    private let grace: TimeInterval = 5

    func testActiveOnceAnyPromptMarkerHasArrived() {
        let status = shellIntegrationStatus(sawAnyPromptMarker: true, sawOutput: true,
                                            elapsed: 0.1, grace: grace)
        XCTAssertEqual(status, .active)
    }

    /// A `D` marker resets `PromptPhase` to `.unknown`, so the live phase can't be the signal:
    /// a shell that reached a prompt and then ran a command is still integrated.
    func testStaysActiveAfterAMarkerEvenPastTheGraceWindow() {
        let status = shellIntegrationStatus(sawAnyPromptMarker: true, sawOutput: true,
                                            elapsed: 60, grace: grace)
        XCTAssertEqual(status, .active)
    }

    func testNotDetectedWhenTheShellPrintedButNeverSentAMarker() {
        let status = shellIntegrationStatus(sawAnyPromptMarker: false, sawOutput: true,
                                            elapsed: 5, grace: grace)
        XCTAssertEqual(status, .notDetected)
    }

    func testPendingBeforeTheGraceWindowElapses() {
        let status = shellIntegrationStatus(sawAnyPromptMarker: false, sawOutput: true,
                                            elapsed: 4.9, grace: grace)
        XCTAssertEqual(status, .pending)
    }

    /// A surface whose shell hasn't printed anything yet (slow spawn) must never be accused of
    /// missing integration — there's been no opportunity to send a marker.
    func testPendingWhileTheShellHasProducedNoOutput() {
        let status = shellIntegrationStatus(sawAnyPromptMarker: false, sawOutput: false,
                                            elapsed: 600, grace: grace)
        XCTAssertEqual(status, .pending)
    }
}
