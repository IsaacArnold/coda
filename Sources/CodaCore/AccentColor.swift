import Foundation

/// The app accent colour used to highlight the focused worktree/branch row in the sidebar.
/// Pure/UI-free (Core never imports AppKit); the AppKit shell converts the hex to NSColor.
public enum AccentColor {
    /// Default accent hex — Dracula purple. Kept as the NSColor fallback literal
    /// for the sidebar highlight before a theme resolves.
    public static let defaultHex = "#BD93F9"

    /// The default accent as a theme-following value: the purple hue (which
    /// resolves to `defaultHex` under Dracula, so the out-of-box look is unchanged).
    public static let defaultValue: IdentityColorValue = .hue(.purple)

    /// Resolve a stored accent preference to a concrete colour under `theme`.
    /// A legacy hex migrates to a hue (or a pin); nil → the default purple hue.
    public static func resolve(_ stored: String?, theme: TerminalTheme) -> RGB {
        (IdentityColorValue.migrating(from: stored) ?? defaultValue).resolved(theme)
    }
}
