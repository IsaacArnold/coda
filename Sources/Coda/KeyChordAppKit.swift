// Sources/Coda/KeyChordAppKit.swift
import AppKit
import CodaCore

extension KeyModifiers {
    /// The AppKit modifier mask for an NSMenuItem / recorder.
    var eventModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift)   { flags.insert(.shift) }
        if contains(.option)  { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }
}

extension KeyChord {
    /// Build a chord from a recorded key event. Requires at least one modifier and a
    /// bindable key; returns nil otherwise (caller keeps waiting).
    init?(event: NSEvent) {
        guard let key = normalizedKeyEquivalent(
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "") else { return nil }
        var m = KeyModifiers()
        let f = event.modifierFlags
        if f.contains(.command) { m.insert(.command) }
        if f.contains(.shift)   { m.insert(.shift) }
        if f.contains(.option)  { m.insert(.option) }
        if f.contains(.control) { m.insert(.control) }
        guard !m.isEmpty else { return nil }
        // A shifted symbol/number (e.g. ⇧1 → "!") can't match as a menu keyEquivalent; only
        // shifted letters (⇧N → "n"+shift) are valid. Reject the rest so the recorder waits.
        if m.contains(.shift), key.count == 1, let c = key.first, !c.isLetter { return nil }
        self.init(key: key, modifiers: m)
    }
}
