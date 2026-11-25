import XCTest
@testable import CodaCore

final class ShellIntegrationTests: XCTestCase {
    private let zsh = ResolvedShell(executablePath: "/bin/zsh")
    private let bash = ResolvedShell(executablePath: "/bin/bash")
    private let bundleDir = URL(fileURLWithPath: "/Applications/Coda.app/Contents/Resources/Resources/shell-integration/zsh")
    private let userDir = URL(fileURLWithPath: "/Users/example")

    func testZshEnabledSetsBundleZdotdirAndPreservesUserDir() {
        let env = shellIntegrationEnv(enabled: true, shell: zsh,
                                      bundleZdotdir: bundleDir, userZdotdir: userDir)
        XCTAssertEqual(env["ZDOTDIR"], bundleDir.path)
        XCTAssertEqual(env["CODA_USER_ZDOTDIR"], userDir.path)
    }

    func testBashEnabledIsUnsupportedAndEmpty() {
        let env = shellIntegrationEnv(enabled: true, shell: bash,
                                      bundleZdotdir: bundleDir, userZdotdir: userDir)
        XCTAssertTrue(env.isEmpty)
    }

    func testZshDisabledIsEmpty() {
        let env = shellIntegrationEnv(enabled: false, shell: zsh,
                                      bundleZdotdir: bundleDir, userZdotdir: userDir)
        XCTAssertTrue(env.isEmpty)
    }

    // MARK: userZdotdir — whose dotfiles the wrapper chains

    private let home = URL(fileURLWithPath: "/Users/me")

    func testUserZdotdirDefaultsToHome() {
        XCTAssertEqual(userZdotdir(inheritedEnvironment: [:], home: home).path, "/Users/me")
    }

    func testUserZdotdirHonoursTheUsersOwnZdotdir() {
        XCTAssertEqual(userZdotdir(inheritedEnvironment: ["ZDOTDIR": "/Users/me/.config/zsh"], home: home).path,
                       "/Users/me/.config/zsh")
    }

    /// Coda launched from inside a Coda terminal (`open -n` a dev build, `open -a Coda` from a
    /// tab) inherits the parent's wrapper `ZDOTDIR`. Taking that as the user's dotfile dir chains
    /// the parent's wrapper instead of `~/.zshrc`, and the shell loses all integration (#84).
    /// The parent's `CODA_USER_ZDOTDIR` still holds the real one.
    func testUserZdotdirSeesThroughAnInheritedCodaWrapper() {
        let inherited = [
            "ZDOTDIR": "/Applications/Coda.app/Contents/Resources/Resources/shell-integration/zsh",
            "CODA_USER_ZDOTDIR": "/Users/me/.config/zsh",
        ]
        XCTAssertEqual(userZdotdir(inheritedEnvironment: inherited, home: home).path, "/Users/me/.config/zsh")
    }

    func testEmptyValuesAreIgnored() {
        XCTAssertEqual(userZdotdir(inheritedEnvironment: ["ZDOTDIR": "", "CODA_USER_ZDOTDIR": ""], home: home).path,
                       "/Users/me")
    }
}
