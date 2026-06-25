import Foundation

/// Curated worktree identity colors, auto-assigned by creation order (cycling so
/// neighbors differ). Hex strings — the shell converts to NSColor. The contrasting
/// text color for a bar fill comes from `RGB(hex:)?.contrastingText`.
public enum IdentityPalette {
    public static let colors: [String] = [
        "#4CAF50", // green
        "#2196F3", // blue
        "#FF9800", // orange
        "#9C27B0", // purple
        "#009688", // teal
        "#E91E63", // pink
        "#FFC107", // amber
        "#3F51B5", // indigo
    ]

    /// The palette color for a zero-based creation index, cycling past the end.
    public static func color(at index: Int) -> String {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}
