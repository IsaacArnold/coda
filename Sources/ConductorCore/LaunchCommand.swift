import Foundation

/// POSIX single-quote a string (the only fully safe quoting): wrap in '...' and
/// replace embedded ' with '\''.
public func shellSingleQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Build the `zsh -i -c` line for a terminal surface.
/// - No setupScript: `cd <dir> && exec <command>` (command replaces the shell).
/// - With setupScript: run setup first; on success exec the command; on failure
///   drop into an interactive shell so the user can investigate, instead of the
///   terminal dying. `exec` must NOT precede the setup chain, so it sits only in
///   front of the final command.
/// `command` is intentionally not quoted (it is a single token like `claude`).
public func terminalLaunchLine(workingDirectory: String, setupScript: String, command: String) -> String {
    let dir = shellSingleQuote(workingDirectory)
    let setup = setupScript.trimmingCharacters(in: .whitespacesAndNewlines)
    if setup.isEmpty {
        return "cd \(dir) && exec \(command)"
    }
    return "cd \(dir) && { \(setup) && exec \(command) || exec zsh; }"
}
