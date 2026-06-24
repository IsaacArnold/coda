import XCTest
@testable import ConductorCore

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
}
