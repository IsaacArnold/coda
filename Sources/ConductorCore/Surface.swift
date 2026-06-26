import Foundation

/// Whether a surface belongs to a worktree or is a worktree-less scratch shell.
/// `.scratch` is reserved for Phase 1.5 PR C; PR A only constructs `.worktree`.
public enum SurfaceKind: String, Codable, Equatable {
    case worktree, scratch
}

/// One terminal surface ("tab") inside a worktree. The live PTY/terminal is held by
/// the shell as the registry's `Handle`; this value type carries only the metadata
/// Core reasons about. All fields are in-memory only (no restore).
public struct Surface: Equatable {
    public let id: String
    public var nameOverride: String?
    public var colorOverride: RGB?
    public var kind: SurfaceKind

    public init(id: String, nameOverride: String? = nil,
                colorOverride: RGB? = nil, kind: SurfaceKind = .worktree) {
        self.id = id
        self.nameOverride = nameOverride
        self.colorOverride = colorOverride
        self.kind = kind
    }

    /// The color this surface contributes to chrome: its own override, else the worktree's.
    public func effectiveColor(worktreeColor: RGB?) -> RGB? { colorOverride ?? worktreeColor }
}

/// The label to show for a surface tab: an explicit rename wins; otherwise the live
/// terminal title (OSC-set by the shell/claude) if non-empty; otherwise "Terminal N"
/// (1-based). Pure so the shell's labeling is unit-testable.
public func surfaceLabel(nameOverride: String?, terminalTitle: String?, index: Int) -> String {
    if let n = nameOverride, !n.trimmingCharacters(in: .whitespaces).isEmpty { return n }
    if let t = terminalTitle?.trimmingCharacters(in: .whitespaces), !t.isEmpty { return t }
    return "Terminal \(index + 1)"
}
