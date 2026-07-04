import XCTest
@testable import CodaCore

final class ShellTests: XCTestCase {
    func testExplicitZsh() {
        let s = resolveShell(choice: .zsh, loginShell: "/bin/bash")
        XCTAssertEqual(s.executablePath, "/bin/zsh")
        XCTAssertEqual(s.name, "zsh")
        XCTAssertEqual(s.loginArgv0, "-zsh")
    }

    func testExplicitBash() {
        let s = resolveShell(choice: .bash, loginShell: "/bin/zsh")
        XCTAssertEqual(s.executablePath, "/bin/bash")
        XCTAssertEqual(s.name, "bash")
        XCTAssertEqual(s.loginArgv0, "-bash")
    }

    func testAutomaticUsesLoginShell() {
        let s = resolveShell(choice: .automatic, loginShell: "/bin/bash")
        XCTAssertEqual(s.executablePath, "/bin/bash")
        XCTAssertEqual(s.name, "bash")
        XCTAssertEqual(s.loginArgv0, "-bash")
    }

    func testAutomaticSupportsHomebrewAndExoticShells() {
        let s = resolveShell(choice: .automatic, loginShell: "/opt/homebrew/bin/fish")
        XCTAssertEqual(s.executablePath, "/opt/homebrew/bin/fish")
        XCTAssertEqual(s.name, "fish")
        XCTAssertEqual(s.loginArgv0, "-fish")
    }

    func testAutomaticFallsBackToZshWhenLoginShellMissing() {
        XCTAssertEqual(resolveShell(choice: .automatic, loginShell: nil).executablePath, "/bin/zsh")
        XCTAssertEqual(resolveShell(choice: .automatic, loginShell: "").executablePath, "/bin/zsh")
    }

    func testAutomaticFallsBackToZshForNonAbsoluteLoginShell() {
        // A relative/garbage $SHELL is not a spawnable path — fall back to a known-good one.
        XCTAssertEqual(resolveShell(choice: .automatic, loginShell: "bash").executablePath, "/bin/zsh")
    }
}
