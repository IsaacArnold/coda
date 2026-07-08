import Foundation

/// Environment-variable names Coda seeds into every terminal's PTY so a Claude Code
/// hook (a child of that shell) can identify itself and reach Coda's socket. Shared by the
/// seeder (Coda) and the forwarder (CodaHook) so the two never drift.
public enum HookEnv {
    public static let socketPath = "CODA_SOCKET_PATH"
    public static let worktreeID = "CODA_WORKTREE_ID"
    public static let surfaceID  = "CODA_SURFACE_ID"
}

/// The full environment for a surface's PTY: the inherited environment plus the three
/// CODA_* keys, plus terminal defaults. Pure; performs no I/O.
///
/// Passing an explicit environment to SwiftTerm's `startProcess` bypasses the defaults it
/// would otherwise inject (`Terminal.getEnvironmentVariables`). A GUI app launched from
/// Finder/Homebrew inherits no `TERM`/`COLORTERM`, so without these Claude Code's color
/// detection sees a dumb terminal and emits colorless output. We supply the same defaults
/// SwiftTerm does, but only where the inherited environment hasn't already set them.
public func hookEnvironment(base: [String: String],
                            socketPath: String,
                            worktreeID: String,
                            surfaceID: String,
                            shellIntegration: [String: String] = [:]) -> [String: String] {
    var env = base
    env[HookEnv.socketPath] = socketPath
    env[HookEnv.worktreeID] = worktreeID
    env[HookEnv.surfaceID]  = surfaceID
    // Mirror SwiftTerm's default PTY environment (see Terminal.getEnvironmentVariables).
    for (key, value) in ["TERM": "xterm-256color",
                         "COLORTERM": "truecolor",
                         "LANG": "en_US.UTF-8"] where env[key] == nil {
        env[key] = value
    }
    // Bundled zsh ZDOTDIR wrapper env (ZDOTDIR/CODA_USER_ZDOTDIR), or empty when
    // unsupported/disabled — see ShellIntegration.swift. Applied last so it can override an
    // inherited ZDOTDIR (the whole point is to redirect zsh's dotfile lookup through Coda's
    // bundled wrapper, which then chains the user's real dotfiles itself).
    for (key, value) in shellIntegration {
        env[key] = value
    }
    return env
}
