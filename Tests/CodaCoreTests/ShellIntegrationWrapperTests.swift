import XCTest
@testable import CodaCore

/// End-to-end tests for the *shell side* of the integration: the real bundled `ZDOTDIR` wrapper
/// under `Sources/Coda/Resources/shell-integration/zsh`, driven by a real zsh in a real pty.
///
/// These exist because the wrapper is plain shell script that no Swift unit test touches, and its
/// failure mode is silent: if the wrapper never reaches its `.zshrc`, no OSC 133 markers are ever
/// emitted, `promptPhase` stays `.unknown`, and the completion popup simply never appears with no
/// error anywhere. That shipped undetected.
///
/// Everything runs against a throwaway `CODA_USER_ZDOTDIR`/`HOME`, never the developer's real
/// dotfiles, so the result doesn't depend on what's installed on the machine.
final class ShellIntegrationWrapperTests: XCTestCase {
    private var wrapperDir: URL {
        URL(fileURLWithPath: #filePath)          // Tests/CodaCoreTests/<this file>
            .deletingLastPathComponent()          // Tests/CodaCoreTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("Sources/Coda/Resources/shell-integration/zsh")
    }

    func testPromptMarkersArriveThroughTheBundledWrapper() throws {
        let run = try runZshThroughWrapper(userDotfiles: [:])
        XCTAssertTrue(run.output.contains("\u{1b}]133;A"),
                      "no OSC 133 prompt-start marker in output:\n\(run.output.debugDescription)")
    }

    /// The regression that broke completions in the field. `kiro-cli` (also Amazon Q / Fig) hooks
    /// `~/.zprofile` — which the wrapper chains *before* it reaches `.zshrc` — and `exec`s its own
    /// pty wrapper over the shell. That replaces the process mid-dotfile, so the wrapper's `.zshrc`
    /// (the only place the OSC 133 hooks are installed) is never reached; and because the pty
    /// wrapper does not propagate `ZDOTDIR` to the shell it then spawns, the replacement shell
    /// escapes Coda's integration permanently.
    ///
    /// The `.zprofile` below is a faithful stand-in for that launcher's real gate: it re-execs
    /// unless `Q_TERM` is already set. The wrapper must set that opt-out before chaining any user
    /// dotfile, so the `exec` never happens inside a Coda terminal.
    func testPromptMarkersSurviveADotfileThatExecsAPtyWrapper() throws {
        let hijackingZprofile = """
        if [[ -z ${Q_TERM:-} ]]; then
          export Q_TERM=1
          unset ZDOTDIR
          exec /bin/zsh -l -i
        fi
        """
        let run = try runZshThroughWrapper(userDotfiles: [".zprofile": hijackingZprofile])
        XCTAssertTrue(run.output.contains("\u{1b}]133;A"),
                      "a dotfile exec'd a pty wrapper and Coda's integration was lost — "
                      + "no OSC 133 markers in output:\n\(run.output.debugDescription)")
    }

    /// Stock macOS `/etc/zshrc` line 16 does `HISTFILE=${ZDOTDIR:-$HOME}/.zsh_history`, and it runs
    /// after our `.zshenv` but before our `.zshrc`. Since `ZDOTDIR` is Coda's bundle while the
    /// wrapper is active, an uncorrected shell writes the user's history *inside the .app* — lost
    /// on every update, and a write into a notarized bundle. The wrapper has to point it back at
    /// the user's own dotfile directory.
    func testShellHistoryIsWrittenToTheUsersHomeNotTheAppBundle() throws {
        let strayHistory = wrapperDir.appendingPathComponent(".zsh_history")
        try? FileManager.default.removeItem(at: strayHistory)

        let run = try runZshThroughWrapper(userDotfiles: [:])

        XCTAssertFalse(FileManager.default.fileExists(atPath: strayHistory.path),
                       "shell history was written into the bundled resource directory at "
                       + strayHistory.path)
        // Asserted so the check above can't pass merely because history saving was off entirely.
        let userHistory = run.home.appendingPathComponent(".zsh_history")
        XCTAssertTrue(FileManager.default.fileExists(atPath: userHistory.path),
                      "no history was saved anywhere, so this test proves nothing")
    }

    // MARK: Harness

    /// What one wrapper run produced: everything the shell wrote, plus the throwaway home it ran
    /// against (kept alive for the duration of the test so assertions can inspect it).
    private struct Run {
        let output: String
        let home: URL
    }

    /// Spawns `/bin/zsh -l -i` in a pty with `ZDOTDIR` pointed at the real bundled wrapper and
    /// `HOME`/`CODA_USER_ZDOTDIR` pointed at a temp dir seeded with `userDotfiles`, then returns
    /// everything the shell wrote. `/usr/bin/script` supplies the pty (zsh installs `precmd`
    /// hooks and prints a prompt only when interactive, so a plain pipe won't do).
    ///
    /// `HISTFILE` is deliberately *not* pinned here: `/etc/zshrc` would overwrite it anyway, and
    /// pinning it would hide exactly the bug
    /// `testShellHistoryIsWrittenToTheUsersHomeNotTheAppBundle` exists to catch.
    private func runZshThroughWrapper(userDotfiles: [String: String]) throws -> Run {
        guard FileManager.default.fileExists(atPath: "/bin/zsh") else {
            throw XCTSkip("no /bin/zsh on this machine")
        }
        let fakeHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("coda-shell-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: fakeHome) }
        for (name, body) in userDotfiles {
            try body.write(to: fakeHome.appendingPathComponent(name), atomically: true,
                           encoding: .utf8)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/zsh", "-l", "-i"]
        process.currentDirectoryURL = fakeHome
        process.environment = [
            "ZDOTDIR": wrapperDir.path,
            "CODA_USER_ZDOTDIR": fakeHome.path,
            "HOME": fakeHome.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "xterm-256color",
        ]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        var collected = Data()
        let done = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { done.signal() } else { collected.append(chunk) }
        }
        try process.run()

        // Let the dotfiles settle, run one command so a full prompt cycle is exercised, then quit.
        Thread.sleep(forTimeInterval: 1.5)
        input.fileHandleForWriting.write("echo coda-probe\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.75)
        input.fileHandleForWriting.write("exit\n".data(using: .utf8)!)

        _ = done.wait(timeout: .now() + 10)
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        return Run(output: String(decoding: collected, as: UTF8.self), home: fakeHome)
    }
}
