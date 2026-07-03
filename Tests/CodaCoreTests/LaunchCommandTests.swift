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

    // Regression: shell-first tabs must launch a SINGLE interactive shell, not the old
    // `-i -c "… exec zsh -i"` that sourced .zshrc twice (~2x new-tab startup on heavy
    // dotfiles). No `-c` means no nested shell means one .zshrc pass.
    func testShellFirstArgsAvoidDoubleInit() {
        let args = terminalShellArgs(workingDirectory: "/tmp/wt", setupScript: "", command: "")
        XCTAssertEqual(args, ["-i"])
        XCTAssertFalse(args.contains("-c"), "shell-first must not wrap in -c (that nests a second zsh -i)")
    }

    // A directly-exec'd command (auto-launch Claude) still needs the outer shell to
    // source .zshrc, so it keeps the -i -c form — there's no inner shell to source it.
    func testCommandArgsKeepInteractiveSourcing() {
        let args = terminalShellArgs(workingDirectory: "/tmp/wt", setupScript: "", command: "claude")
        XCTAssertEqual(args, ["-i", "-c", "cd '/tmp/wt' && exec claude"])
    }

    func testSetupArgsKeepInteractiveSourcing() {
        let args = terminalShellArgs(workingDirectory: "/tmp/wt", setupScript: "npm install", command: "")
        XCTAssertEqual(args, ["-i", "-c", "cd '/tmp/wt' && { npm install && exec zsh -i || exec zsh; }"])
    }

    func testBashEmptyCommandExecsBashInteractive() {
        let line = terminalLaunchLine(workingDirectory: "/tmp/wt", setupScript: "", command: "", shell: "bash")
        XCTAssertEqual(line, "cd '/tmp/wt' && exec bash -i")
    }

    func testBashSetupFallsBackToBash() {
        let line = terminalLaunchLine(workingDirectory: "/tmp/wt", setupScript: "npm install",
                                      command: "", shell: "bash")
        XCTAssertEqual(line, "cd '/tmp/wt' && { npm install && exec bash -i || exec bash; }")
    }

    func testBashCommandArgs() {
        let args = terminalShellArgs(workingDirectory: "/tmp/wt", setupScript: "",
                                     command: "claude", shell: "bash")
        // A non-empty command is exec'd directly; the shell name only affects the fallback path.
        XCTAssertEqual(args, ["-i", "-c", "cd '/tmp/wt' && exec claude"])
    }

    func testShellNameDefaultsToZsh() {
        // Existing call sites that omit `shell:` keep zsh behavior.
        let line = terminalLaunchLine(workingDirectory: "/tmp/wt", setupScript: "", command: "")
        XCTAssertEqual(line, "cd '/tmp/wt' && exec zsh -i")
    }
}
