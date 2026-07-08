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
}
