import XCTest
@testable import CodaCore

final class HookEnvironmentTests: XCTestCase {
    func testSeedsTheThreeKeys() {
        let env = hookEnvironment(base: ["PATH": "/usr/bin"],
                                  socketPath: "/tmp/x.sock",
                                  worktreeID: "wt1", surfaceID: "s1")
        XCTAssertEqual(env[HookEnv.socketPath], "/tmp/x.sock")
        XCTAssertEqual(env[HookEnv.worktreeID], "wt1")
        XCTAssertEqual(env[HookEnv.surfaceID], "s1")
    }

    func testPreservesInheritedEnv() {
        let env = hookEnvironment(base: ["PATH": "/usr/bin", "TERM": "xterm"],
                                  socketPath: "/s", worktreeID: "w", surfaceID: "s")
        XCTAssertEqual(env["PATH"], "/usr/bin")
        XCTAssertEqual(env["TERM"], "xterm")
    }
}
