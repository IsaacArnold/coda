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
        let mixed = "✻ Working (esc to interrupt)\nDo you want to proceed?\n❯ 1. Yes\n  2. No"
        XCTAssertEqual(agentState(fromOutput: mixed), .needsYou)
    }

    func testProseQuestionIsNotAPermissionPrompt() {
        // Claude asking a question in prose (with its footer) is "done", not needs-you —
        // only the numbered approve option ("1. Yes") marks a real permission prompt.
        let prose = "Do you want me to add styling?\n────\nOpus 4.8 (1M context) | ctx: 3%\n← for agents"
        XCTAssertEqual(agentState(fromOutput: prose), .done)
    }

    func testDoneStaysDoneWhenFooterDropsAgentsHint() {
        // Some frames drop "← for agents" but keep the ctx footer — must not flap to idle.
        XCTAssertEqual(agentState(fromOutput: "────\nOpus 4.8 (1M context) | test | ctx: 3% | $0.11"), .done)
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

    func testWorkingFromSpinnerElapsedTimer() {
        // Real working frame (captured): the gerund spinner shows an elapsed timer,
        // and the ctx: footer is ALSO present — working must win over done.
        let frame = """
        ✽ Blanching… (4s · ↓ 125 tokens · thinking)
        ──────
        Opus 4.8 (1M context) | test | test | ctx: 3% | $0.11
        ← for agents
        """
        XCTAssertEqual(agentState(fromOutput: frame), .working)
    }

    func testWorkingTimerWithTokensCollapsed() {
        XCTAssertEqual(agentState(fromOutput: "✻Blanching…(6s·↑222tokens)\nctx:3%"), .working)
    }

    func testWorkingFromExactCapturedFrames() {
        // Exact frames captured from a live session (various separators/spacing).
        for frame in [
            "✽ Blanching… (10s · ↑ 254 tokens)\nctx: 3%",
            "✻Blanching…(7s·↑233tokens)\nctx:3%",
            "· Blanching… (2s · thinking)\n← for agents\nctx: --%",
        ] {
            XCTAssertEqual(agentState(fromOutput: frame), .working, "frame: \(frame)")
        }
    }

    func testPlainProseInSecondsIsNotMistakenForWorking() {
        // "(2 seconds)" collapses to "(2seconds)" — must NOT match the spinner timer.
        XCTAssertEqual(agentState(fromOutput: "It ran in (2 seconds).\nOpus (1M context) | ctx: 3%"), .done)
    }

    func testIdleWhenOnlyAPlainShellPrompt() {
        // A plain shell (incl. having just typed `claude` but not launched) → no badge.
        XCTAssertEqual(agentState(fromOutput: "~/.conductor/worktrees/html-css-starter/test   test  claude"), .idle)
    }

    func testIdleOnEmptyOutput() {
        XCTAssertEqual(agentState(fromOutput: "   \n  "), .idle)
    }
}
