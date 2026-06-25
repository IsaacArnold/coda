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
