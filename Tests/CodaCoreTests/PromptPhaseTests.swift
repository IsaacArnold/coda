import XCTest
@testable import CodaCore

final class PromptPhaseTests: XCTestCase {
    // MARK: - Fresh machine

    func testFreshMachineIsUnknown() {
        let machine = PromptPhaseMachine()
        XCTAssertEqual(machine.phase, .unknown)
        XCTAssertNil(machine.lastCommandExitCode)
    }

    // MARK: - Single markers

    func testAEntersAtPrompt() {
        var machine = PromptPhaseMachine()
        machine.consume("A")
        XCTAssertEqual(machine.phase, .atPrompt)
    }

    func testBEntersAtPrompt() {
        var machine = PromptPhaseMachine()
        machine.consume("B")
        XCTAssertEqual(machine.phase, .atPrompt)
    }

    func testCEntersExecuting() {
        var machine = PromptPhaseMachine()
        machine.consume("C")
        XCTAssertEqual(machine.phase, .executing)
    }

    func testDEntersUnknown() {
        var machine = PromptPhaseMachine()
        machine.consume("A")
        machine.consume("B")
        machine.consume("C")
        machine.consume("D")
        XCTAssertEqual(machine.phase, .unknown)
    }

    // MARK: - Full A, B, C, D cycle

    func testFullCycleTransitionsInOrder() {
        var machine = PromptPhaseMachine()

        machine.consume("A")
        XCTAssertEqual(machine.phase, .atPrompt)

        machine.consume("B")
        XCTAssertEqual(machine.phase, .atPrompt)

        machine.consume("C")
        XCTAssertEqual(machine.phase, .executing)

        machine.consume("D")
        XCTAssertEqual(machine.phase, .unknown)
    }

    // MARK: - Exit code capture from D;<code>

    func testDWithExitCodeZeroCapturesExitCode() {
        var machine = PromptPhaseMachine()
        machine.consume("D;0")
        XCTAssertEqual(machine.phase, .unknown)
        XCTAssertEqual(machine.lastCommandExitCode, 0)
    }

    func testDWithExitCodeOneCapturesExitCode() {
        var machine = PromptPhaseMachine()
        machine.consume("D;1")
        XCTAssertEqual(machine.lastCommandExitCode, 1)
    }

    func testDWithoutExitCodeLeavesExitCodeNil() {
        var machine = PromptPhaseMachine()
        machine.consume("D")
        XCTAssertNil(machine.lastCommandExitCode)
    }

    func testLargerExitCodeIsCaptured() {
        var machine = PromptPhaseMachine()
        machine.consume("D;127")
        XCTAssertEqual(machine.lastCommandExitCode, 127)
    }

    func testExitCodeIsClearedByASubsequentBareD() {
        // A stale exit code from a previous command must not leak into a run that reports none.
        var machine = PromptPhaseMachine()
        machine.consume("D;0")
        XCTAssertEqual(machine.lastCommandExitCode, 0)
        machine.consume("D")
        XCTAssertNil(machine.lastCommandExitCode)
    }

    // MARK: - Out-of-order / duplicate markers (must never crash, must resolve sensibly)

    func testDBeforeAnyPromptMarkerResolvesToUnknown() {
        var machine = PromptPhaseMachine()
        machine.consume("D;1")
        XCTAssertEqual(machine.phase, .unknown)
        XCTAssertEqual(machine.lastCommandExitCode, 1)
    }

    func testDuplicateAMarkersStayAtPrompt() {
        var machine = PromptPhaseMachine()
        machine.consume("A")
        machine.consume("A")
        machine.consume("A")
        XCTAssertEqual(machine.phase, .atPrompt)
    }

    func testDuplicateCMarkersStayExecuting() {
        var machine = PromptPhaseMachine()
        machine.consume("C")
        machine.consume("C")
        XCTAssertEqual(machine.phase, .executing)
    }

    func testCWithoutPrecedingPromptStillEntersExecuting() {
        // A shell that skips A/B (e.g. a subshell) shouldn't wedge the machine.
        var machine = PromptPhaseMachine()
        machine.consume("C")
        XCTAssertEqual(machine.phase, .executing)
    }

    func testUnrecognizedMarkerIsIgnoredWithoutCrashing() {
        var machine = PromptPhaseMachine()
        machine.consume("B")
        machine.consume("Z")
        XCTAssertEqual(machine.phase, .atPrompt)
    }

    func testEmptyPayloadIsIgnoredWithoutCrashing() {
        var machine = PromptPhaseMachine()
        machine.consume("B")
        machine.consume("")
        XCTAssertEqual(machine.phase, .atPrompt)
    }

    func testMalformedExitCodeIsIgnoredWithoutCrashing() {
        var machine = PromptPhaseMachine()
        machine.consume("D;not-a-number")
        XCTAssertEqual(machine.phase, .unknown)
        XCTAssertNil(machine.lastCommandExitCode)
    }

    func testBAfterDReentersAtPromptReadyForNextCommand() {
        var machine = PromptPhaseMachine()
        machine.consume("D;0")
        machine.consume("A")
        machine.consume("B")
        XCTAssertEqual(machine.phase, .atPrompt)
    }
}
