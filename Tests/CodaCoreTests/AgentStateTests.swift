import XCTest
@testable import CodaCore

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

    // MARK: - 🔴 needs you (Claude stopped, awaiting your decision)

    func testNeedsYouWhenAskingAQuestion() {
        // Captured "brainstorming" turn: the last message line is a question.
        let q = """
        ● This is a clean HTML/CSS starter.
        First question: What should this button do when clicked?
          1. Navigate to another page
          2. Trigger a JavaScript action
        Which fits best?
        ✻ Cooked for 15s

        ──────
        ❯
        ──────
        Opus 4.8 (1M context) | test | ctx: 3% | $0.11
        ← for agents
        """
        XCTAssertEqual(agentState(fromOutput: q), .needsYou)
    }

    func testNeedsYouOnNumberedPermissionPrompt() {
        let prompt = "Do you want to proceed?\n❯ 1. Yes\n  2. No\n────\nOpus (1M context) | ctx: 3%"
        XCTAssertEqual(agentState(fromOutput: prompt), .needsYou)
    }

    // MARK: - 🟢 done (Claude stopped after a clean finish — nothing pending)

    func testDoneWhenFinishedWithoutAQuestion() {
        // Captured sign-off turn: last message is a statement, not a question → not red.
        let finished = """
        ● You're welcome! Happy coding. 👋
        ✻ Cogitated for 1s

        ──────
        ❯
        ──────
        Opus 4.8 (1M context) | test | test | ctx: 3% | $0.09
        ← for agents
        """
        XCTAssertEqual(agentState(fromOutput: finished), .done)
    }

    func testDoneAtAFreshIdlePrompt() {
        let footer = "❯ \n──────\nOpus 4.8 (1M context) | test | ctx: 3% | $0.11\n← for agents"
        XCTAssertEqual(agentState(fromOutput: footer), .done)
    }

    func testDoneStaysOpenWhenFooterDropsAgentsHint() {
        // Some frames drop "← for agents" but keep the ctx footer — must not flap to idle.
        XCTAssertEqual(agentState(fromOutput: "────\nOpus 4.8 (1M context) | test | ctx: 3% | $0.11"), .done)
    }

    // MARK: - ⚪️ idle / guards

    func testProseMentioningSecondsIsNotWorking() {
        // "(2 seconds)" must NOT match the spinner timer; with a Claude footer it's stopped (done).
        XCTAssertEqual(agentState(fromOutput: "It ran in (2 seconds).\nOpus (1M context) | ctx: 3%"), .done)
    }

    func testIdleWhenOnlyAPlainShellPrompt() {
        // A plain shell (incl. having just typed `claude` but not launched) → no badge.
        XCTAssertEqual(agentState(fromOutput: "~/.coda/worktrees/html-css-starter/test   test  claude"), .idle)
    }

    func testIdleOnEmptyOutput() {
        XCTAssertEqual(agentState(fromOutput: "   \n  "), .idle)
    }

    func testNeedsYouCountEmpty() {
        XCTAssertEqual(needsYouCount([:]), 0)
    }

    func testNeedsYouCountCountsOnlyNeedsYou() {
        let rollups: [String: AgentState] = [
            "a": .needsYou, "b": .working, "c": .needsYou, "d": .done, "e": .idle,
        ]
        XCTAssertEqual(needsYouCount(rollups), 2)
    }

    func testNeedsYouCountNoneNeedYou() {
        XCTAssertEqual(needsYouCount(["a": .working, "b": .idle, "c": .done]), 0)
    }
}

final class AgentStateRollupTests: XCTestCase {
    func testEmptyRollsUpToIdle() {
        XCTAssertEqual(rollup([]), .idle)
    }
    func testNeedsYouWinsOverEverything() {
        XCTAssertEqual(rollup([.idle, .working, .done, .needsYou]), .needsYou)
    }
    func testWorkingWinsOverDoneAndIdle() {
        XCTAssertEqual(rollup([.idle, .done, .working]), .working)
    }
    func testDoneWinsOverIdle() {
        XCTAssertEqual(rollup([.idle, .done, .idle]), .done)
    }
    func testAllIdleRollsUpToIdle() {
        XCTAssertEqual(rollup([.idle, .idle]), .idle)
    }
}
