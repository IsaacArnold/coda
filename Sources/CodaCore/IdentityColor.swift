import Foundation

/// Resolve the identity-color *base* for a worktree: its own color, falling back to its
/// repository's color. The per-surface (tab) override is layered on top separately via
/// `Surface.effectiveColor(worktreeColor:)`, so the full chain is
/// `surface override → worktree → repo → default`.
///
/// A malformed worktree hex falls through to the repo color rather than resolving to nil,
/// so a bad override never suppresses an otherwise-valid repo default.
public func identityBaseColor(worktreeColorHex: String?, repoColorHex: String?) -> RGB? {
    worktreeColorHex.flatMap(RGB.init(hex:)) ?? repoColorHex.flatMap(RGB.init(hex:))
}

/// Resolve the full identity-colour chain to a concrete colour under a theme:
/// the first non-nil of `surface → worktree → repo`, resolved through `theme`
/// (a `.hue` follows the theme, a `.pinned` colour ignores it). nil when no
/// level sets a colour, so the caller can apply its own default.
public func resolvedIdentityColor(surface: IdentityColorValue?,
                                  worktree: IdentityColorValue?,
                                  repo: IdentityColorValue?,
                                  theme: TerminalTheme) -> RGB? {
    (surface ?? worktree ?? repo)?.resolved(theme)
}
