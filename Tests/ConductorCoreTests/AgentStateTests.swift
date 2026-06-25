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

    func testDoneFromRealClaudeFooter() {
        // Real Claude Code v2.x footer when finished/waiting (captured from a session).
        // Spacing is collapsed in the terminal snapshot, so matching must be space-insensitive.
        let footer = "❯ \n──────\nOpus 4.8 (1M context) | test | test | ctx: 3% | $0.11\n← for agents"
        XCTAssertEqual(agentState(fromOutput: footer), .done)
    }

    func testDoneEvenWhenFooterSpacingIsCollapsed() {
        XCTAssertEqual(agentState(fromOutput: "Opus4.8(1Mcontext) |test |ctx:3%\n←foragents"), .done)
    }

    func testWorkingMatchesInterruptEvenIfSpacingCollapsed() {
        XCTAssertEqual(agentState(fromOutput: "✻ Sautéing… (esctointerrupt)"), .working)
    }

    func testIdleWhenOnlyAPlainShellPrompt() {
        // A plain shell (incl. having just typed `claude` but not launched) → no badge.
        XCTAssertEqual(agentState(fromOutput: "~/.conductor/worktrees/html-css-starter/test   test  claude"), .idle)
    }

    func testIdleOnEmptyOutput() {
        XCTAssertEqual(agentState(fromOutput: "   \n  "), .idle)
    }
}
