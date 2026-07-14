import Foundation

/// A theme-independent identity colour *role*. Each theme resolves a hue to its
/// own concrete colour (via `TerminalTheme.color(for:)`), so identity colours
/// restyle live when the theme changes — "my red repo" stays red-ish everywhere.
public enum IdentityHue: String, CaseIterable, Codable {
    case red, orange, yellow, green, cyan, blue, purple, pink

    /// Order used when auto-assigning a hue by creation index. Spread so adjacent
    /// entries — and the cycle wrap — sit in different hue families. Matches the
    /// retired `IdentityPalette` order so upgrading users keep their colours.
    public static let assignmentOrder: [IdentityHue] =
        [.purple, .green, .pink, .cyan, .orange, .blue, .yellow, .red]

    /// The hue for a zero-based creation index, cycling past the end.
    public static func autoAssigned(index: Int) -> IdentityHue {
        let o = assignmentOrder
        return o[((index % o.count) + o.count) % o.count]
    }
}

/// The stored value of an identity colour: either a theme-following `hue` or a
/// theme-ignoring `pinned` exact colour (the "Custom…" escape hatch).
///
/// Serialized form (stored in JSON):
///   - `.hue(.red)`   → `"red"`            (a bare hue name)
///   - `.pinned(rgb)` → `"pin:#RRGGBB"`    (tagged, so it can never be mistaken
///                                          for a legacy bare `#RRGGBB`)
/// A legacy bare `#RRGGBB` is deliberately NOT valid new-format input — it is
/// handled once, on load, by `migrating(from:)`.
public enum IdentityColorValue: Equatable {
    case hue(IdentityHue)
    case pinned(RGB)

    private static let pinPrefix = "pin:"

    public var serialized: String {
        switch self {
        case .hue(let h):    return h.rawValue
        case .pinned(let c): return Self.pinPrefix + c.hexString
        }
    }

    /// Parse a *new-format* serialized value. Returns nil for anything else
    /// (unknown names, malformed pins, legacy bare hexes).
    public init?(serialized: String) {
        if serialized.hasPrefix(Self.pinPrefix) {
            let hex = String(serialized.dropFirst(Self.pinPrefix.count))
            guard let rgb = RGB(hex: hex) else { return nil }
            self = .pinned(rgb)
        } else if let hue = IdentityHue(rawValue: serialized) {
            self = .hue(hue)
        } else {
            return nil
        }
    }

    /// The retired `IdentityPalette` (Dracula-derived), mapped 1:1 to hues. This
    /// is the migration table for legacy bare `#hex` values; the Dracula curated
    /// palette reproduces these same hexes, closing the loop.
    static let legacyHexToHue: [String: IdentityHue] = [
        "#BD93F9": .purple, "#50FA7B": .green, "#FF79C6": .pink, "#8BE9FD": .cyan,
        "#FFB86C": .orange, "#6272A4": .blue, "#F1FA8C": .yellow, "#FF5555": .red,
    ]

    /// Interpret a stored identity string across formats. New-format values
    /// (`init(serialized:)`) pass through; a legacy bare `#hex` maps to its hue
    /// via `legacyHexToHue`, falling through to `.pinned` for an unrecognized
    /// colour; anything unparseable (and nil) yields nil.
    public static func migrating(from stored: String?) -> IdentityColorValue? {
        guard let stored else { return nil }
        if let value = IdentityColorValue(serialized: stored) { return value }
        guard let rgb = RGB(hex: stored) else { return nil }
        if let hue = legacyHexToHue[rgb.hexString] { return .hue(hue) }
        return .pinned(rgb)
    }

    /// Resolve to a concrete colour under `theme`: a hue follows the theme; a
    /// pinned colour ignores it.
    public func resolved(_ theme: TerminalTheme) -> RGB {
        switch self {
        case .hue(let h):    return theme.color(for: h)
        case .pinned(let c): return c
        }
    }
}
