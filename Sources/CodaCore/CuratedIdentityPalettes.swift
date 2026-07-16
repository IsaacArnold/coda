import Foundation

/// Hand-authored identity palettes per bundled theme: a hue → concrete colour
/// map so each bundled theme's repo/worktree/tab colours look intentional.
///
/// A theme with no curated entry (any imported `.itermcolors`) falls back to
/// deriving each hue from its ANSI colours — see `TerminalTheme.color(for:)`.
///
/// The map is keyed by theme *name* (the `.itermcolors` file's basename, which is
/// also `TerminalTheme.name`).
///
/// NOTE: **Dracula's values are a hard requirement** — they reproduce the exact
/// retired `IdentityPalette` hexes so a current daily Dracula user sees no change
/// (guarded by `CuratedIdentityPalettesTests`). The other five are best-effort
/// from each theme's recognisable accent set and should be eyeballed in a live
/// run; tweaking them is pure data.
public enum CuratedIdentityPalettes {
    /// Themes shipped in the app bundle. Every one must be fully curated below.
    public static let bundledThemeNames = [
        "Dracula", "Nord", "Solarized Light", "IsaacTheme", "Xcode Dark", "Rider Darcula",
        "Islands Dark",
    ]

    public static let map: [String: [IdentityHue: RGB]] = [
        // EXACT retired IdentityPalette — do not change without updating the
        // migration table + regression test.
        "Dracula": [
            .red: rgb("#FF5555"), .orange: rgb("#FFB86C"), .yellow: rgb("#F1FA8C"),
            .green: rgb("#50FA7B"), .cyan: rgb("#8BE9FD"), .blue: rgb("#6272A4"),
            .purple: rgb("#BD93F9"), .pink: rgb("#FF79C6"),
        ],
        // Nord — Aurora (red/orange/yellow/green/purple) + Frost (cyan/blue).
        // No native pink; a soft Aurora rose. [verify]
        "Nord": [
            .red: rgb("#BF616A"), .orange: rgb("#D08770"), .yellow: rgb("#EBCB8B"),
            .green: rgb("#A3BE8C"), .cyan: rgb("#8FBCBB"), .blue: rgb("#81A1C1"),
            .purple: rgb("#B48EAD"), .pink: rgb("#C99DBE"),
        ],
        // Solarized accent set — its eight named accents map cleanly to our hues.
        "Solarized Light": [
            .red: rgb("#DC322F"), .orange: rgb("#CB4B16"), .yellow: rgb("#B58900"),
            .green: rgb("#859900"), .cyan: rgb("#2AA198"), .blue: rgb("#268BD2"),
            .purple: rgb("#6C71C4"), .pink: rgb("#D33682"),
        ],
        // IsaacTheme — Dracula-family; from its own ANSI (ANSI4 is purple, ANSI5
        // pink). Orange blended, blue a comment-slate to stay distinct. [verify]
        "IsaacTheme": [
            .red: rgb("#F0776D"), .orange: rgb("#F5B678"), .yellow: rgb("#F4F8A8"),
            .green: rgb("#89F398"), .cyan: rgb("#ADEBFB"), .blue: rgb("#7A88C0"),
            .purple: rgb("#C4AAF5"), .pink: rgb("#F298CE"),
        ],
        // Xcode Default Dark — from its syntax palette (pink keywords, salmon
        // strings, purple types, teal). [verify]
        "Xcode Dark": [
            .red: rgb("#FF8170"), .orange: rgb("#FFA14F"), .yellow: rgb("#D9C97C"),
            .green: rgb("#78C2B3"), .cyan: rgb("#6BDFFF"), .blue: rgb("#4EB0CC"),
            .purple: rgb("#DABAFF"), .pink: rgb("#FF7AB2"),
        ],
        // JetBrains Darcula — keyword orange, method yellow, string green, etc. [verify]
        "Rider Darcula": [
            .red: rgb("#FF6B68"), .orange: rgb("#CC7832"), .yellow: rgb("#FFC66D"),
            .green: rgb("#6A8759"), .cyan: rgb("#299999"), .blue: rgb("#6897BB"),
            .purple: rgb("#9876AA"), .pink: rgb("#C0669E"),
        ],
        // JetBrains Islands Dark — New UI syntax palette: keyword orange, string
        // green, number teal, function blue, constant purple; red/yellow/pink from
        // the JetBrains console accents. [verify]
        "Islands Dark": [
            .red: rgb("#F0524F"), .orange: rgb("#CF8E6D"), .yellow: rgb("#E5BF00"),
            .green: rgb("#6AAB73"), .cyan: rgb("#2AACB8"), .blue: rgb("#56A8F5"),
            .purple: rgb("#C77DBB"), .pink: rgb("#ED7EED"),
        ],
    ]

    /// Force-unwrap a compile-time-constant hex literal. Guarded by the curated
    /// tests, so a typo'd literal fails a test rather than crashing at runtime.
    private static func rgb(_ hex: String) -> RGB { RGB(hex: hex)! }
}
