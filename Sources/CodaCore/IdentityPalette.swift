import Foundation

/// Curated worktree identity colors, auto-assigned by creation order (cycling so
/// neighbors differ). Hex strings — the shell converts to NSColor. The contrasting
/// text color for a bar fill comes from `RGB(hex:)?.contrastingText`.
///
/// The palette is the Dracula theme's accent colors (matching the bundled
/// `Dracula.itermcolors`): purple/green/pink/cyan + ANSI comment-blue, yellow,
/// red, plus Dracula's spec orange (`#FFB86C`, which has no ANSI slot). Ordered
/// so adjacent entries — and the cycle wrap — sit in different hue families.
public enum IdentityPalette {
    public static let colors: [String] = [
        "#BD93F9", // purple
        "#50FA7B", // green
        "#FF79C6", // pink
        "#8BE9FD", // cyan
        "#FFB86C", // orange
        "#6272A4", // comment blue
        "#F1FA8C", // yellow
        "#FF5555", // red
    ]

    /// The palette color for a zero-based creation index, cycling past the end.
    public static func color(at index: Int) -> String {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}
