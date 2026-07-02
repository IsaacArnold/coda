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

/// The argv (after `/bin/zsh`, whose argv0 is always the login `-zsh`) for a terminal
/// surface. `currentDirectory` is set on the spawn, so the working directory is handled
/// out-of-band and needs no `cd` for the shell-first path.
///
/// - Shell-first (no setup, no command): a single interactive login shell (`-i`), with
///   NO `-c` wrapper. The previous form `-i -c "cd … && exec zsh -i"` sourced `.zshrc`
///   twice — once for the outer `-i` shell, once for the exec'd inner `zsh -i` — which
///   roughly doubled new-tab startup on machines with heavy dotfiles. A single shell
///   sources `.zprofile`/`.zshrc` exactly once.
/// - With setup and/or command: keep the `-i -c <line>` form. The `-i` is load-bearing
///   here — a non-shell target like `claude` is `exec`'d directly (no inner interactive
///   shell), so the outer shell must source `.zshrc` for it to inherit the interactive
///   environment (PATH, etc.).
public func terminalShellArgs(workingDirectory: String, setupScript: String, command: String) -> [String] {
    let setup = setupScript.trimmingCharacters(in: .whitespacesAndNewlines)
    let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
    if setup.isEmpty && cmd.isEmpty {
        return ["-i"]
    }
    return ["-i", "-c", terminalLaunchLine(workingDirectory: workingDirectory,
                                           setupScript: setupScript,
                                           command: command)]
}
