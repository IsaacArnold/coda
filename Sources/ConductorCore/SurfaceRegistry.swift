import Foundation

/// Tracks which worktree owns which (opaque) terminal-surface handle, plus the
/// active worktree, so the shell can keep surfaces alive across sidebar switches
/// and tear them down on archive. Pure: the `Handle` is whatever the shell stores
/// (a `TerminalSurface`); Core never touches AppKit.
public final class SurfaceRegistry<Handle> {
    private var handles: [String: Handle] = [:]
    public private(set) var activeWorktreeID: String?

    public init() {}

    /// Associate a surface handle with a worktree. One handle per worktree: a
    /// later registration for the same worktree replaces the earlier one.
    public func register(_ handle: Handle, for worktreeID: String) {
        handles[worktreeID] = handle
    }

    public func handle(for worktreeID: String) -> Handle? { handles[worktreeID] }

    /// Mark the active worktree (the one whose surface is on screen). Idempotent.
    public func setActive(_ worktreeID: String?) { activeWorktreeID = worktreeID }

    /// Remove and return a worktree's handle (on archive), so the shell can tear
    /// the surface down. Clears the active selection if it was the evicted worktree.
    @discardableResult
    public func evict(worktreeID: String) -> Handle? {
        let removed = handles.removeValue(forKey: worktreeID)
        if activeWorktreeID == worktreeID { activeWorktreeID = nil }
        return removed
    }

    public var count: Int { handles.count }
}
