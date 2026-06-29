import XCTest
@testable import CodaCore

final class LaunchCommandTests: XCTestCase {
    func testNoSetupExecsCommandDirectly() {
        let line = terminalLaunchLine(workingDirectory: "/tmp/wt", setupScript: "", command: "claude")
        XCTAssertEqual(line, "cd '/tmp/wt' && exec claude")
    }

    func testWhitespaceOnlySetupTreatedAsEmpty() {
        let line = terminalLaunchLine(workingDirectory: "/tmp/wt", setupScript: "   \n", command: "claude")
        XCTAssertEqual(line, "cd '/tmp/wt' && exec claude")
    }

    func testSetupRunsThenExecsCommandWithShellFallback() {
        let line = terminalLaunchLine(workingDirectory: "/tmp/wt", setupScript: "npm install", command: "claude")
        XCTAssertEqual(line, "cd '/tmp/wt' && { npm install && exec claude || exec zsh; }")
    }

    func testWorkingDirectoryIsSingleQuoted() {
        let line = terminalLaunchLine(workingDirectory: "/tmp/a b's", setupScript: "", command: "claude")
        XCTAssertEqual(line, "cd '/tmp/a b'\\''s' && exec claude")
    }

    // Shell-first: an empty command yields a live interactive shell, not a dead terminal.
    func testEmptyCommandExecsInteractiveShell() {
        let line = terminalLaunchLine(workingDirectory: "/tmp/wt", setupScript: "", command: "")
        XCTAssertEqual(line, "cd '/tmp/wt' && exec zsh -i")
    }

    func testEmptyCommandWithSetupRunsSetupThenInteractiveShell() {
        let line = terminalLaunchLine(workingDirectory: "/tmp/wt", setupScript: "npm install", command: "")
        XCTAssertEqual(line, "cd '/tmp/wt' && { npm install && exec zsh -i || exec zsh; }")
    }

    // What the explicit "Launch Claude" action sends into a worktree's live shell.
    func testLaunchCommandDefaultsToClaude() {
        let repo = Repository(id: "r1", path: "/tmp/repo", name: "repo")
        XCTAssertEqual(launchCommand(for: repo), "claude")
    }
}
