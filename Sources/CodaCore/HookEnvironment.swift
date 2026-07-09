import Foundation

/// Environment-variable names Coda seeds into every terminal's PTY so a Claude Code
/// hook (a child of that shell) can identify itself and reach Coda's socket. Shared by the
/// seeder (Coda) and the forwarder (CodaHook) so the two never drift.
public enum HookEnv {
    public static let socketPath = "CODA_SOCKET_PATH"
    public static let worktreeID = "CODA_WORKTREE_ID"
    public static let surfaceID  = "CODA_SURFACE_ID"
}

/// The full environment for a surface's PTY: the inherited environment, plus the three
/// CODA_* hook-correlation keys *when this surface is wired to the hook socket*, plus the
/// bundled-zsh shell-integration keys *when completions are enabled*, plus terminal defaults.
/// Pure; performs no I/O.
///
/// The hook vars and the shell integration are INDEPENDENT: a surface may have completions
/// without hook wiring (e.g. a scratch terminal, or an app launched without a bundle id, so
/// the hook socket never started) and vice-versa. Each `CODA_*` var is therefore seeded only
/// when its value is non-empty — an empty id means "not wired", not "set me to empty" — so this
/// function builds a correct PTY env for every combination.
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
    if !socketPath.isEmpty { env[HookEnv.socketPath] = socketPath }
    if !worktreeID.isEmpty { env[HookEnv.worktreeID] = worktreeID }
    if !surfaceID.isEmpty  { env[HookEnv.surfaceID]  = surfaceID }
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
