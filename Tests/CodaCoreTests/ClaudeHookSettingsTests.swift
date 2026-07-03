import XCTest
@testable import CodaCore

final class ClaudeHookSettingsTests: XCTestCase {
    func testAddThenContains() {
        let out = addCodaHook(to: [:], forwarderPath: "/App/coda-hook")
        XCTAssertTrue(containsCodaHook(out))
        let hooks = out["hooks"] as? [String: Any]
        XCTAssertNotNil(hooks?["Stop"])
        XCTAssertNotNil(hooks?["Notification"])
    }

    func testAddIsIdempotent() {
        let once = addCodaHook(to: [:], forwarderPath: "/App/coda-hook")
        let twice = addCodaHook(to: once, forwarderPath: "/App/coda-hook")
        let stop = ((twice["hooks"] as? [String: Any])?["Stop"]) as? [[String: Any]]
        XCTAssertEqual(stop?.count, 1)   // not duplicated
    }

    func testPreservesForeignHooks() {
        let existing: [String: Any] = ["hooks": ["Stop": [["matcher": "",
            "hooks": [["type": "command", "command": "echo mine"]]]]]]
        let out = addCodaHook(to: existing, forwarderPath: "/App/coda-hook")
        let stop = ((out["hooks"] as? [String: Any])?["Stop"]) as? [[String: Any]]
        XCTAssertEqual(stop?.count, 2)   // user's block + coda's block
    }

    func testRemoveLeavesForeignHooks() {
        let withCoda = addCodaHook(to: ["hooks": ["Stop": [["matcher": "",
            "hooks": [["type": "command", "command": "echo mine"]]]]]],
            forwarderPath: "/App/coda-hook")
        let out = removeCodaHook(from: withCoda)
        XCTAssertFalse(containsCodaHook(out))
        let stop = ((out["hooks"] as? [String: Any])?["Stop"]) as? [[String: Any]]
        XCTAssertEqual(stop?.count, 1)
        let cmd = ((stop?.first?["hooks"] as? [[String: Any]])?.first?["command"]) as? String
        XCTAssertEqual(cmd, "echo mine")
    }

    func testCommandIsMarkedAndNotAShellString() {
        let cmd = codaHookCommand(forwarderPath: "/App/coda-hook")
        XCTAssertTrue(cmd.contains(codaHookMarker))
        XCTAssertTrue(cmd.contains("/App/coda-hook"))
    }
}
