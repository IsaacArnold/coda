import XCTest
@testable import CodaCore

final class AgentHookEventTests: XCTestCase {
    func testRoundTrip() {
        let line = encodeHookMessage(worktreeID: "w", surfaceID: "s", event: .notification,
                                     message: "needs your input", transcriptPath: nil)
        XCTAssertEqual(decodeHookMessage(line),
            AgentHookEvent(worktreeID: "w", surfaceID: "s", event: .notification,
                           message: "needs your input", transcriptPath: nil))
    }

    func testCarriesTranscriptPath() {
        let line = encodeHookMessage(worktreeID: "w", surfaceID: "s", event: .stop,
                                     message: nil, transcriptPath: "/t/x.jsonl")
        XCTAssertEqual(decodeHookMessage(line)?.transcriptPath, "/t/x.jsonl")
        XCTAssertNil(decodeHookMessage(line)?.message)
    }

    func testDecodeBareEvent() {
        let line = encodeHookMessage(worktreeID: "w", surfaceID: "s", event: .preToolUse,
                                     message: nil, transcriptPath: nil)
        XCTAssertEqual(decodeHookMessage(line)?.event, .preToolUse)
    }

    func testRejectsUnknownEventName() {
        XCTAssertNil(decodeHookMessage(#"w s {"hook_event_name":"Bogus"}"#))
    }

    func testRejectsOversizedLine() {
        let huge = String(repeating: "a", count: 100_000)
        let line = #"w s {"hook_event_name":"Notification","message":"\#(huge)"}"#
        XCTAssertNil(decodeHookMessage(line, maxLength: 64_000))
    }

    func testRejectsMalformed() {
        XCTAssertNil(decodeHookMessage(""))
        XCTAssertNil(decodeHookMessage("only-two fields"))
        XCTAssertNil(decodeHookMessage("w s not-json"))
    }

    func testMessageWithSpacesAndNewlinesSurvives() {
        let msg = "line one\nline two with spaces"
        let line = encodeHookMessage(worktreeID: "w", surfaceID: "s", event: .notification,
                                     message: msg, transcriptPath: nil)
        XCTAssertEqual(decodeHookMessage(line)?.message, msg)
    }

    func testStateMapping() {
        XCTAssertEqual(agentState(for: .userPromptSubmit), .working)
        XCTAssertEqual(agentState(for: .preToolUse), .working)
        XCTAssertEqual(agentState(for: .postToolUse), .working)
        XCTAssertEqual(agentState(for: .notification), .needsYou)
        XCTAssertEqual(agentState(for: .stop), .done)
        XCTAssertEqual(agentState(for: .sessionEnd), .idle)
        XCTAssertNil(agentState(for: .sessionStart))   // presence handled separately
    }

    // MARK: - transcript parsing (for the done-notification body)

    func testLastAssistantTextFromTranscript() {
        // One assistant line per record; content is an array of typed blocks.
        let jsonl = """
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"first"}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"final answer"}]}}
        """
        XCTAssertEqual(lastAssistantText(fromTranscript: jsonl), "final answer")
    }

    func testLastAssistantTextSkipsToolUseBlocks() {
        // The last assistant record may contain a tool_use block plus text; take the text.
        let jsonl = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}},{"type":"text","text":"ran it"}]}}
        """
        XCTAssertEqual(lastAssistantText(fromTranscript: jsonl), "ran it")
    }

    func testLastAssistantTextNilWhenNoAssistant() {
        let jsonl = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}"#
        XCTAssertNil(lastAssistantText(fromTranscript: jsonl))
    }
}
