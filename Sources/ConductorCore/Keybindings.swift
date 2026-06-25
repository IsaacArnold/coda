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
    case worktree, repository, view, app
    public var displayName: String {
        switch self {
        case .worktree: return "Worktree"
        case .repository: return "Repository"
        case .view: return "View"
        case .app: return "App"
        }
    }
    public var order: Int {
        switch self {
        case .worktree: return 0
        case .repository: return 1
        case .view: return 2
        case .app: return 3
        }
    }
}

public enum ShortcutCommand: String, Codable, CaseIterable, Sendable {
    case newWorktree, launchClaude, openInEditor, revealInFinder, archiveWorktree
    case addRepository, toggleSidebar, openSettings

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
        }
    }

    public var category: ShortcutCategory {
        switch self {
        case .newWorktree, .launchClaude, .openInEditor, .revealInFinder, .archiveWorktree:
            return .worktree
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
        }
    }
}
