import Foundation

/// The app accent colour used to highlight the focused worktree/branch row in the sidebar.
/// Pure/UI-free (Core never imports AppKit); the AppKit shell converts the hex to NSColor.
public enum AccentColor {
    /// Default accent — Dracula purple, the first identity-palette swatch.
    public static let defaultHex = "#BD93F9"

    /// The swatches offered in Settings — the curated identity palette.
    public static var swatches: [String] { IdentityPalette.colors }

    /// Resolve a stored preference (nil → default) to a concrete hex.
    public static func resolve(_ stored: String?) -> String { stored ?? defaultHex }
}
