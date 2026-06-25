import XCTest
@testable import ConductorCore

final class AgentStateTests: XCTestCase {
    // MARK: - 🟡 working

    func testWorkingFromInterruptHint() {
        XCTAssertEqual(agentState(fromOutput: "✻ Crunching… (esc to interrupt)"), .working)
    }

    func testWorkingFromInterruptHintCollapsed() {
        XCTAssertEqual(agentState(fromOutput: "✻ Sautéing… (esctointerrupt)"), .working)
    }

    func testWorkingFromSpinnerElapsedTimer() {
        // Real working frame (captured): the gerund spinner shows an elapsed timer, and the
        // ctx: footer is ALSO present — working must win over the your-turn footer check.
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
        for frame in [
            "✽ Blanching… (10s · ↑ 254 tokens)\nctx: 3%",
            "✻Blanching…(7s·↑233tokens)\nctx:3%",
            "· Blanching… (2s · thinking)\n← for agents\nctx: --%",
        ] {
            XCTAssertEqual(agentState(fromOutput: frame), .working, "frame: \(frame)")
        }
    }

    // MARK: - 🔴 your turn (Claude open but not working: finished, asking, or a permission prompt)

    func testYourTurnWhenClaudeOpenAndWaiting() {
        let footer = "❯ \n──────\nOpus 4.8 (1M context) | test | test | ctx: 3% | $0.11\n← for agents"
        XCTAssertEqual(agentState(fromOutput: footer), .needsYou)
    }

    func testYourTurnWhenAskingANumberedQuestion() {
        let q = "Which fits best?\n  1. Navigate\n  2. Trigger an action\n────\nOpus (1M context) | ctx: 3%\n← for agents"
        XCTAssertEqual(agentState(fromOutput: q), .needsYou)
    }

    func testYourTurnOnPermissionPrompt() {
        let prompt = "Do you want to proceed?\n❯ 1. Yes\n  2. No\n────\nOpus (1M context) | ctx: 3%"
        XCTAssertEqual(agentState(fromOutput: prompt), .needsYou)
    }

    func testYourTurnStaysWhenFooterDropsAgentsHint() {
        // Some frames drop "← for agents" but keep the ctx footer — must not flap to idle.
        XCTAssertEqual(agentState(fromOutput: "────\nOpus 4.8 (1M context) | test | ctx: 3% | $0.11"), .needsYou)
    }

    func testYourTurnWhenFooterSpacingCollapsed() {
        XCTAssertEqual(agentState(fromOutput: "Opus4.8(1Mcontext) |test |ctx:3%\n←foragents"), .needsYou)
    }

    // MARK: - ⚪️ idle / guards

    func testProseMentioningSecondsIsNotWorking() {
        // "(2 seconds)" must NOT match the spinner timer; with a Claude footer it's your-turn.
        XCTAssertEqual(agentState(fromOutput: "It ran in (2 seconds).\nOpus (1M context) | ctx: 3%"), .needsYou)
    }

    func testIdleWhenOnlyAPlainShellPrompt() {
        // A plain shell (incl. having just typed `claude` but not launched) → no badge.
        XCTAssertEqual(agentState(fromOutput: "~/.conductor/worktrees/html-css-starter/test   test  claude"), .idle)
    }

    func testIdleOnEmptyOutput() {
        XCTAssertEqual(agentState(fromOutput: "   \n  "), .idle)
    }
}
