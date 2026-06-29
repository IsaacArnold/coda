import Foundation

/// POSIX single-quote a string (the only fully safe quoting): wrap in '...' and
/// replace embedded ' with '\''.
public func shellSingleQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// The command the explicit "Launch Claude" action sends into a worktree's live
/// shell. Default `claude`; leaves room for per-repo flags/variants later.
public func launchCommand(for repo: Repository) -> String {
    "claude"
}

/// Build the `zsh -i -c` line for a terminal surface.
/// - Empty `command` (shell-first): exec a live interactive shell (`zsh -i`) so the
///   worktree drops into a plain shell rather than a command-then-dead terminal.
/// - Non-empty `command`: `exec <command>` (the command replaces the shell).
/// - With setupScript: run setup first; on success exec the target; on failure
///   drop into an interactive shell so the user can investigate, instead of the
///   terminal dying. `exec` must NOT precede the setup chain, so it sits only in
///   front of the final target.
/// `command` is intentionally not quoted (it is a single token like `claude`).
public func terminalLaunchLine(workingDirectory: String, setupScript: String, command: String) -> String {
    let dir = shellSingleQuote(workingDirectory)
    let setup = setupScript.trimmingCharacters(in: .whitespacesAndNewlines)
    let target = command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "zsh -i" : command
    if setup.isEmpty {
        return "cd \(dir) && exec \(target)"
    }
    return "cd \(dir) && { \(setup) && exec \(target) || exec zsh; }"
}
