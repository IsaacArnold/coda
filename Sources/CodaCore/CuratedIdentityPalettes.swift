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
        "Dracula", "Nord", "Solarized Light", "IsaacTheme", "JetBrains Islands Dark",
        "Atom One Dark", "Brogrammer",
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
        // JetBrains Islands Dark (canonical iTerm2 scheme) — ANSI red/green/blue/
        // magenta/cyan, plus the Islands keyword-orange and a lightened rose pink. [verify]
        "JetBrains Islands Dark": [
            .red: rgb("#E4656E"), .orange: rgb("#CF8E6D"), .yellow: rgb("#D59637"),
            .green: rgb("#6DB083"), .cyan: rgb("#6AAEA6"), .blue: rgb("#538AF9"),
            .purple: rgb("#967BEF"), .pink: rgb("#C77DBB"),
        ],
        // Atom One Dark — its recognisable syntax set: ANSI accents plus the
        // #D19A66 constant-orange and a lightened purple-rose for pink. [verify]
        "Atom One Dark": [
            .red: rgb("#E06C75"), .orange: rgb("#D19A66"), .yellow: rgb("#E5C07B"),
            .green: rgb("#98C379"), .cyan: rgb("#56B6C2"), .blue: rgb("#61AFEF"),
            .purple: rgb("#C678DD"), .pink: rgb("#D782BA"),
        ],
        // Brogrammer — vivid ANSI red/green/yellow/blue/indigo; orange blended from
        // red⊕yellow, cyan nudged teal, pink a lightened red-magenta. [verify]
        "Brogrammer": [
            .red: rgb("#F81118"), .orange: rgb("#F26311"), .yellow: rgb("#ECBA0F"),
            .green: rgb("#2DC55E"), .cyan: rgb("#17A0B8"), .blue: rgb("#2A84D2"),
            .purple: rgb("#4E5AB7"), .pink: rgb("#B45C9E"),
        ],
    ]

    /// Force-unwrap a compile-time-constant hex literal. Guarded by the curated
    /// tests, so a typo'd literal fails a test rather than crashing at runtime.
    private static func rgb(_ hex: String) -> RGB { RGB(hex: hex)! }
}
