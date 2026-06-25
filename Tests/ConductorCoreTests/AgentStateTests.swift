import XCTest
@testable import ConductorCore

final class AgentStateTests: XCTestCase {
    func testWorkingSignalWhenInterruptHintPresent() {
        // Claude shows "(esc to interrupt)" while it's working.
        XCTAssertEqual(agentState(fromOutput: "✻ Crunching… (esc to interrupt)"), .working)
    }

    func testNeedsYouOnPermissionPrompt() {
        let prompt = """
        Do you want to proceed?
        ❯ 1. Yes
          2. No, and tell Claude what to do differently
        """
        XCTAssertEqual(agentState(fromOutput: prompt), .needsYou)
    }

    func testNeedsYouTakesPriorityOverWorking() {
        // A permission prompt is the user's turn even if a stale spinner line lingers.
        let mixed = "✻ Working (esc to interrupt)\nDo you want to proceed?\n❯ 1. Yes"
        XCTAssertEqual(agentState(fromOutput: mixed), .needsYou)
    }

    func testDoneWhenClaudeIsWaitingIdle() {
        // After finishing, Claude's input box footer shows the shortcuts hint and no spinner.
        XCTAssertEqual(agentState(fromOutput: "│ > \n⏵⏵ ? for shortcuts"), .done)
    }

    func testIdleWhenOnlyAPlainShellPrompt() {
        XCTAssertEqual(agentState(fromOutput: "isaac@mac terminal-snippets % "), .idle)
    }

    func testIdleOnEmptyOutput() {
        XCTAssertEqual(agentState(fromOutput: "   \n  "), .idle)
    }
}
