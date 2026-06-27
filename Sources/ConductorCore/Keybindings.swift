import Foundation

public struct KeyModifiers: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let shift   = KeyModifiers(rawValue: 1 << 1)
    public static let option  = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)

    // Encode as a bare int so keybindings.json stays compact.
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(Int.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// A keyboard chord: the keyEquivalent character (lowercased) plus modifier flags.
/// Maps 1:1 onto NSMenuItem.keyEquivalent + keyEquivalentModifierMask.
public struct KeyChord: Codable, Equatable, Hashable, Sendable {
    public var key: String
    public var modifiers: KeyModifiers

    public init(key: String, modifiers: KeyModifiers) {
        self.key = key; self.modifiers = modifiers
    }

    public init(_ key: String, command: Bool = false, shift: Bool = false,
                option: Bool = false, control: Bool = false) {
        var m = KeyModifiers()
        if command { m.insert(.command) }
        if shift { m.insert(.shift) }
        if option { m.insert(.option) }
        if control { m.insert(.control) }
        self.init(key: key, modifiers: m)
    }

    /// Human-readable form, e.g. "⌥⌘R". Modifier order is the macOS canonical ⌃⌥⇧⌘.
    public var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option)  { s += "⌥" }
        if modifiers.contains(.shift)   { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + KeyChord.keySymbol(key)
    }

    static func keySymbol(_ key: String) -> String {
        switch key {
        case "\u{8}", "\u{7f}": return "⌫"
        case "\r": return "↩"
        case "\u{1b}": return "⎋"
        case " ": return "Space"
        case "\u{f700}": return "↑"
        case "\u{f701}": return "↓"
        case "\u{f702}": return "←"
        case "\u{f703}": return "→"
        case ",": return ","
        default: return key.uppercased()
        }
    }
}

public enum ShortcutCategory: String, CaseIterable, Sendable {
    case worktree, surface, repository, view, app
    public var displayName: String {
        switch self {
        case .worktree: return "Worktree"
        case .surface: return "Surfaces"
        case .repository: return "Repository"
        case .view: return "View"
        case .app: return "App"
        }
    }
    public var order: Int {
        switch self {
        case .worktree: return 0
        case .surface: return 1
        case .repository: return 2
        case .view: return 3
        case .app: return 4
        }
    }
}

public enum ShortcutCommand: String, Codable, CaseIterable, Sendable {
    case newWorktree, launchClaude, openInEditor, revealInFinder, archiveWorktree
    case addRepository, toggleSidebar, openSettings
    case newSurface, closeSurface, nextSurface, prevSurface, splitSurface
    case splitDown, focusPaneLeft, focusPaneRight, focusPaneUp, focusPaneDown
    case goToSurface1, goToSurface2, goToSurface3, goToSurface4, goToSurface5
    case goToSurface6, goToSurface7, goToSurface8, goToSurface9

    public var displayName: String {
        switch self {
        case .newWorktree: return "New Worktree"
        case .launchClaude: return "Launch Claude"
        case .openInEditor: return "Open in Editor"
        case .revealInFinder: return "Reveal in Finder"
        case .archiveWorktree: return "Archive Worktree"
        case .addRepository: return "Add Repository"
        case .toggleSidebar: return "Toggle Sidebar"
        case .openSettings: return "Settings"
        case .newSurface: return "New Tab"
        case .closeSurface: return "Close Tab"
        case .nextSurface: return "Next Tab"
        case .prevSurface: return "Previous Tab"
        case .splitSurface: return "Split Right"
        case .splitDown: return "Split Down"
        case .focusPaneLeft: return "Focus Pane Left"
        case .focusPaneRight: return "Focus Pane Right"
        case .focusPaneUp: return "Focus Pane Up"
        case .focusPaneDown: return "Focus Pane Down"
        case .goToSurface1: return "Go to Tab 1"
        case .goToSurface2: return "Go to Tab 2"
        case .goToSurface3: return "Go to Tab 3"
        case .goToSurface4: return "Go to Tab 4"
        case .goToSurface5: return "Go to Tab 5"
        case .goToSurface6: return "Go to Tab 6"
        case .goToSurface7: return "Go to Tab 7"
        case .goToSurface8: return "Go to Tab 8"
        case .goToSurface9: return "Go to Tab 9"
        }
    }

    public var category: ShortcutCategory {
        switch self {
        case .newWorktree, .launchClaude, .openInEditor, .revealInFinder, .archiveWorktree:
            return .worktree
        case .newSurface, .closeSurface, .nextSurface, .prevSurface, .splitSurface,
             .splitDown, .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown,
             .goToSurface1, .goToSurface2, .goToSurface3, .goToSurface4, .goToSurface5,
             .goToSurface6, .goToSurface7, .goToSurface8, .goToSurface9:
            return .surface
        case .addRepository: return .repository
        case .toggleSidebar: return .view
        case .openSettings: return .app
        }
    }

    public var defaultChord: KeyChord {
        switch self {
        case .newWorktree:     return KeyChord("n", command: true)
        case .launchClaude:    return KeyChord("r", command: true)
        case .openInEditor:    return KeyChord("o", command: true)
        case .revealInFinder:  return KeyChord("r", command: true, option: true)
        case .archiveWorktree: return KeyChord("\u{8}", command: true)
        case .addRepository:   return KeyChord("n", command: true, shift: true)
        case .toggleSidebar:   return KeyChord("s", command: true, control: true)
        case .openSettings:    return KeyChord(",", command: true)
        case .newSurface:      return KeyChord("t", command: true)
        case .closeSurface:    return KeyChord("w", command: true)
        case .nextSurface:     return KeyChord("]", command: true, shift: true)
        case .prevSurface:     return KeyChord("[", command: true, shift: true)
        case .splitSurface:    return KeyChord("d", command: true)
        case .splitDown:       return KeyChord("d", command: true, shift: true)
        case .focusPaneLeft:   return KeyChord("\u{f702}", command: true, option: true)
        case .focusPaneRight:  return KeyChord("\u{f703}", command: true, option: true)
        case .focusPaneUp:     return KeyChord("\u{f700}", command: true, option: true)
        case .focusPaneDown:   return KeyChord("\u{f701}", command: true, option: true)
        case .goToSurface1:    return KeyChord("1", command: true)
        case .goToSurface2:    return KeyChord("2", command: true)
        case .goToSurface3:    return KeyChord("3", command: true)
        case .goToSurface4:    return KeyChord("4", command: true)
        case .goToSurface5:    return KeyChord("5", command: true)
        case .goToSurface6:    return KeyChord("6", command: true)
        case .goToSurface7:    return KeyChord("7", command: true)
        case .goToSurface8:    return KeyChord("8", command: true)
        case .goToSurface9:    return KeyChord("9", command: true)
        }
    }
}

public struct ShortcutOverride: Codable, Equatable, Sendable {
    public var chord: KeyChord
    public var isEnabled: Bool
    public init(chord: KeyChord, isEnabled: Bool = true) {
        self.chord = chord; self.isEnabled = isEnabled
    }
}

/// User overrides keyed by `ShortcutCommand.rawValue`. A command with no override uses its
/// default chord; an override may change the chord and/or disable it entirely.
public struct Keybindings: Codable, Equatable, Sendable {
    public var overrides: [String: ShortcutOverride]
    public init(overrides: [String: ShortcutOverride] = [:]) { self.overrides = overrides }

    public func effectiveChord(for command: ShortcutCommand) -> KeyChord? {
        if let o = overrides[command.rawValue] { return o.isEnabled ? o.chord : nil }
        return command.defaultChord
    }

    public func isEnabled(_ command: ShortcutCommand) -> Bool {
        overrides[command.rawValue]?.isEnabled ?? true
    }

    public func chord(for command: ShortcutCommand) -> KeyChord {
        overrides[command.rawValue]?.chord ?? command.defaultChord
    }

    public mutating func setChord(_ chord: KeyChord, for command: ShortcutCommand) {
        let enabled = overrides[command.rawValue]?.isEnabled ?? true
        overrides[command.rawValue] = ShortcutOverride(chord: chord, isEnabled: enabled)
    }

    public mutating func setEnabled(_ enabled: Bool, for command: ShortcutCommand) {
        let chord = overrides[command.rawValue]?.chord ?? command.defaultChord
        overrides[command.rawValue] = ShortcutOverride(chord: chord, isEnabled: enabled)
    }

    public mutating func reset(_ command: ShortcutCommand) { overrides[command.rawValue] = nil }
    public mutating func resetAll() { overrides = [:] }
}

/// Maps a recorded event's `charactersIgnoringModifiers` to the keyEquivalent form an
/// NSMenuItem expects, or nil for keys we don't allow binding (empty / control chars).
public func normalizedKeyEquivalent(charactersIgnoringModifiers chars: String) -> String? {
    guard let first = chars.first else { return nil }
    switch first {
    case "\u{7f}", "\u{8}": return "\u{8}"     // Delete → backspace (⌫)
    case "\r", "\u{3}": return "\r"            // Return / Enter
    case "\u{1b}": return "\u{1b}"             // Escape
    case " ": return " "
    case "\u{f700}", "\u{f701}", "\u{f702}", "\u{f703}": return String(first)  // arrows
    default:
        let lower = String(first).lowercased()
        guard lower.unicodeScalars.count == 1,
              let scalar = lower.unicodeScalars.first, scalar.value >= 0x20 else { return nil }
        return lower
    }
}
