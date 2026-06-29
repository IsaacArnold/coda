import Foundation

public enum ThemeAppearance: Equatable { case light, dark }

/// Named chrome color slots. Views read these via `ChromeTheme.color(_:)` — never a
/// raw color literal — so the future granular-chrome milestone only fills in overrides.
public enum ChromeRole: CaseIterable {
    case windowBackground, primaryText, secondaryText, accent, glyphTint
}

/// Chrome colors derived from the active terminal theme (iTerm2-style: the window
/// blends into the terminal background). `overrides` is the seam for future
/// user-customizable chrome — empty today, so every role derives.
public struct ChromeTheme {
    private let terminal: TerminalTheme
    private let overrides: [ChromeRole: RGB]

    public init(terminal: TerminalTheme, overrides: [ChromeRole: RGB] = [:]) {
        self.terminal = terminal
        self.overrides = overrides
    }

    public var appearance: ThemeAppearance {
        terminal.background.luminance < 0.5 ? .dark : .light
    }

    public func color(_ role: ChromeRole) -> RGB {
        if let override = overrides[role] { return override }
        return derived(role)
    }

    private func derived(_ role: ChromeRole) -> RGB {
        switch role {
        case .windowBackground: return terminal.background
        case .primaryText:      return terminal.foreground
        case .secondaryText:    return blend(terminal.foreground, terminal.background, 0.45)
        case .accent:           return terminal.ansi.indices.contains(4) ? terminal.ansi[4] : terminal.foreground
        case .glyphTint:        return blend(terminal.foreground, terminal.background, 0.35)
        }
    }

    /// Linear interpolation: `t = 0` → a, `t = 1` → b.
    private func blend(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        RGB(r: a.r + (b.r - a.r) * t,
            g: a.g + (b.g - a.g) * t,
            b: a.b + (b.b - a.b) * t)
    }
}
