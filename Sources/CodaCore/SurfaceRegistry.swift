import Foundation

/// Tracks each worktree's ordered list of terminal surfaces plus the active worktree,
/// so the shell keeps surfaces alive across sidebar switches and tears them all down on
/// archive. Pure: `Handle` is whatever the shell stores (a `TerminalSurface`).
public final class SurfaceRegistry<Handle> {
    private var worktrees: [String: WorktreeSurfaces<Handle>] = [:]
    public private(set) var activeWorktreeID: String?

    public init() {}

    /// The surface list for a worktree, creating an empty one on first access. Returns the
    /// same class instance each time, so mutations through it persist.
    public func surfaces(for worktreeID: String) -> WorktreeSurfaces<Handle> {
        if let existing = worktrees[worktreeID] { return existing }
        let fresh = WorktreeSurfaces<Handle>()
        worktrees[worktreeID] = fresh
        return fresh
    }

    /// Peek without creating — nil if the worktree has never had a surface.
    public func existingSurfaces(for worktreeID: String) -> WorktreeSurfaces<Handle>? {
        worktrees[worktreeID]
    }

    /// Mark the active worktree (the one whose surfaces are on screen). Idempotent.
    public func setActive(_ worktreeID: String?) { activeWorktreeID = worktreeID }

    /// Remove a worktree's entire surface list (on archive); returns all handles so the
    /// shell can tear down every PTY. Clears the active selection if it was this worktree.
    @discardableResult
    public func evict(worktreeID: String) -> [Handle] {
        let removed = worktrees.removeValue(forKey: worktreeID)
        if activeWorktreeID == worktreeID { activeWorktreeID = nil }
        return removed?.handles ?? []
    }

    /// Worktree ids that currently have a surface list (for badge polling).
    public var worktreeIDs: [String] { Array(worktrees.keys) }
}
