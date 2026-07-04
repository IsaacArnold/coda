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

/// Build the `<shell> -i -c` line for a terminal surface.
/// - Empty `command` (shell-first): exec a live interactive shell (`<shell> -i`).
/// - Non-empty `command`: `exec <command>` (the command replaces the shell).
/// - With setupScript: run setup first; on success exec the target; on failure drop into
///   an interactive shell (`exec <shell>`) so the user can investigate.
/// `shell` is the interactive shell's name (e.g. "zsh", "bash"); it only appears in the
/// shell-first target and the setup-failure fallback. `command` is not quoted (a single
/// token like `claude`).
public func terminalLaunchLine(workingDirectory: String, setupScript: String,
                               command: String, shell: String = "zsh") -> String {
    let dir = shellSingleQuote(workingDirectory)
    let setup = setupScript.trimmingCharacters(in: .whitespacesAndNewlines)
    let target = command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(shell) -i" : command
    if setup.isEmpty {
        return "cd \(dir) && exec \(target)"
    }
    return "cd \(dir) && { \(setup) && exec \(target) || exec \(shell); }"
}

/// The argv (after the shell executable, whose argv0 is the login `-<shell>`) for a terminal
/// surface. `currentDirectory` is set on the spawn, so no `cd` is needed for the shell-first
/// path.
/// - Shell-first (no setup, no command): a single interactive login shell (`-i`), NO `-c`
///   wrapper — a `-c` form would nest a second interactive shell and source rc files twice.
/// - With setup and/or command: keep the `-i -c <line>` form; a directly-exec'd target
///   (e.g. `claude`) needs the outer shell's `-i` to source the interactive environment.
public func terminalShellArgs(workingDirectory: String, setupScript: String,
                              command: String, shell: String = "zsh") -> [String] {
    let setup = setupScript.trimmingCharacters(in: .whitespacesAndNewlines)
    let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
    if setup.isEmpty && cmd.isEmpty {
        return ["-i"]
    }
    return ["-i", "-c", terminalLaunchLine(workingDirectory: workingDirectory,
                                           setupScript: setupScript,
                                           command: command, shell: shell)]
}
