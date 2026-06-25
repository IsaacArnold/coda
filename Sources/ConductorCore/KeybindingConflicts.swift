import Foundation

public struct ReservedChord: Equatable, Sendable {
    public let chord: KeyChord
    public let label: String
    public init(chord: KeyChord, label: String) { self.chord = chord; self.label = label }
}

public enum ConflictReason: Equatable, Sendable {
    case command(ShortcutCommand)
    case reserved(String)
}

public struct ShortcutConflict: Equatable, Sendable {
    public let command: ShortcutCommand
    public let reason: ConflictReason
    public init(command: ShortcutCommand, reason: ConflictReason) {
        self.command = command; self.reason = reason
    }
}

public extension Keybindings {
    /// Chords a focused terminal or the standard menus shadow. ⌘⌫ is intentionally absent:
    /// it's Archive's default and coexists with the terminal's delete-to-line-start via
    /// focus-gating, so it must not raise a (permanent) warning.
    static let reservedChords: [ReservedChord] = [
        ReservedChord(chord: KeyChord("k", command: true), label: "Clear"),
        ReservedChord(chord: KeyChord("c", command: true), label: "Copy"),
        ReservedChord(chord: KeyChord("v", command: true), label: "Paste"),
        ReservedChord(chord: KeyChord("x", command: true), label: "Cut"),
        ReservedChord(chord: KeyChord("a", command: true), label: "Select All"),
        ReservedChord(chord: KeyChord("q", command: true), label: "Quit"),
        ReservedChord(chord: KeyChord("h", command: true), label: "Hide"),
        ReservedChord(chord: KeyChord("w", command: true), label: "Close"),
    ]
}

/// Conflicts among enabled commands and against reserved chords. A command conflicts when
/// its effective chord equals a reserved chord, or another enabled command's chord.
/// Disabled commands (nil effective chord) never participate.
public func keybindingConflicts(_ bindings: Keybindings,
                                reserved: [ReservedChord] = Keybindings.reservedChords)
    -> [ShortcutCommand: ShortcutConflict] {
    let enabled: [(ShortcutCommand, KeyChord)] = ShortcutCommand.allCases.compactMap { cmd in
        bindings.effectiveChord(for: cmd).map { (cmd, $0) }
    }
    var result: [ShortcutCommand: ShortcutConflict] = [:]
    for (cmd, chord) in enabled {
        if let r = reserved.first(where: { $0.chord == chord }) {
            result[cmd] = ShortcutConflict(command: cmd, reason: .reserved(r.label))
        } else if let other = enabled.first(where: { $0.0 != cmd && $0.1 == chord }) {
            result[cmd] = ShortcutConflict(command: cmd, reason: .command(other.0))
        }
    }
    return result
}
