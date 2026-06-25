/// What a ⌘-modified keystroke means to a focused terminal.
public enum TerminalKeyAction: Equatable {
    /// ⌘K — clear the terminal screen.
    case clear
    /// ⌘⌫ — kill the current input line back to the prompt (readline Ctrl-U).
    case deleteToLineStart
    /// Not a terminal key — let the menu bar / app handle it (⌘Q, ⌘N, ⌘R, ⌘C, …).
    case passThrough
}

/// Maps a ⌘-modified keystroke to the action a real terminal owns, so a focused terminal
/// can claim those keys *before* the menu bar's key-equivalents see them — and explicitly
/// pass everything else through. `chars` is the event's `charactersIgnoringModifiers`.
public func terminalKeyAction(charactersIgnoringModifiers chars: String,
                              command: Bool, shift: Bool) -> TerminalKeyAction {
    // Only bare ⌘ combos are ours; anything with Shift stays with the app (e.g. ⌘⇧⌫).
    guard command, !shift else { return .passThrough }
    switch chars {
    case "k": return .clear
    case "\u{7f}", "\u{8}": return .deleteToLineStart   // Delete / Backspace
    default: return .passThrough
    }
}
