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

    /// A GUI app launched from Finder/Homebrew inherits no TERM/COLORTERM. When we pass an
    /// explicit environment to the PTY we bypass SwiftTerm's defaults, so we must supply them
    /// ourselves — otherwise Claude Code's color detection sees a dumb terminal (regression:
    /// colorless output that shipped with the hook env override in v0.1.8).
    func testSuppliesTerminalColorDefaultsWhenAbsent() {
        let env = hookEnvironment(base: ["PATH": "/usr/bin"],
                                  socketPath: "/s", worktreeID: "w", surfaceID: "s")
        XCTAssertEqual(env["TERM"], "xterm-256color")
        XCTAssertEqual(env["COLORTERM"], "truecolor")
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
    }

    /// Defaults never clobber values the inheriting environment already set.
    func testDoesNotOverrideExistingColorEnv() {
        let env = hookEnvironment(base: ["TERM": "screen-256color",
                                         "COLORTERM": "24bit",
                                         "LANG": "en_GB.UTF-8"],
                                  socketPath: "/s", worktreeID: "w", surfaceID: "s")
        XCTAssertEqual(env["TERM"], "screen-256color")
        XCTAssertEqual(env["COLORTERM"], "24bit")
        XCTAssertEqual(env["LANG"], "en_GB.UTF-8")
    }
}
