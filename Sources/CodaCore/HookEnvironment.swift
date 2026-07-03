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
/// CODA_* keys. Pure; performs no I/O.
public func hookEnvironment(base: [String: String],
                            socketPath: String,
                            worktreeID: String,
                            surfaceID: String) -> [String: String] {
    var env = base
    env[HookEnv.socketPath] = socketPath
    env[HookEnv.worktreeID] = worktreeID
    env[HookEnv.surfaceID]  = surfaceID
    return env
}
