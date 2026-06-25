// Sources/Conductor/HotkeyRecorderView.swift
import AppKit
import ConductorCore

/// Captures the next key chord the user presses. Overrides performKeyEquivalent so the
/// chord doesn't trigger a menu item; requires ≥1 modifier (handled by KeyChord(event:));
/// Esc cancels.
final class HotkeyRecorderView: NSView {
    var onRecorded: ((KeyChord) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }   // Esc
        if let chord = KeyChord(event: event) { onRecorded?(chord) }
        // otherwise (no modifier / unsupported key): keep waiting
    }
}
