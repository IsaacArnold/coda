/// What a ⌘-modified keystroke means to a focused terminal.
public enum TerminalKeyAction: Equatable {
    /// ⌘K — clear the terminal screen.
    case clear
    /// ⌘⌫ — kill the current input line back to the prompt (readline Ctrl-U).
    case deleteToLineStart
    /// ⌘↵ / ⇧↵ / ⌥↵ — insert a soft newline (LF, 0x0a) instead of submitting. This is
    /// Claude Code's `chat:newline`; in a plain shell readline treats LF like Enter.
    case insertNewline
    /// Not a terminal key — let the menu bar / app handle it (⌘Q, ⌘N, ⌘R, ⌘C, …).
    case passThrough
}

/// Maps a modified keystroke to the action a real terminal owns, so a focused terminal
/// can claim those keys *before* the menu bar's key-equivalents see them — and explicitly
/// pass everything else through. `chars` is the event's `charactersIgnoringModifiers`
/// (Return is "\r" / U+000D regardless of Shift/Option).
public func terminalKeyAction(charactersIgnoringModifiers chars: String,
                              command: Bool, shift: Bool, option: Bool = false) -> TerminalKeyAction {
    // Return + any of ⌘/⇧/⌥ → soft newline (LF), never submit. Checked before the
    // bare-⌘ rules below so ⇧↵ and ⌥↵ (which have no Command) are still handled.
    if chars == "\r", command || shift || option {
        return .insertNewline
    }
    // Only bare ⌘ combos are ours; anything with Shift stays with the app (e.g. ⌘⇧⌫).
    guard command, !shift else { return .passThrough }
    switch chars {
    case "k": return .clear
    case "\u{7f}", "\u{8}": return .deleteToLineStart   // Delete / Backspace
    default: return .passThrough
    }
}

/// What a keystroke means to a visible completion popup.
public enum CompletionPopupKeyAction: Equatable {
    /// ↑ — move the selection up one row.
    case moveUp
    /// ↓ — move the selection down one row.
    case moveDown
    /// Tab — accept the selected candidate (and consume the key so zsh never also completes).
    case accept
    /// Esc — dismiss the popup and suppress it until the next edit.
    case dismiss
    /// Return / keypad Enter — close the popup, then let the key run the command.
    case runAndClose
    /// Anything else — hand the key to the shell unchanged (printable chars re-filter the
    /// query via the normal output-driven refresh; backspace edits the line).
    case passThrough
}

/// Maps a keystroke to a popup action, given the popup IS visible. `hasCommandOptionControl`
/// is true if ⌘/⌥/⌃ is held — those keep their existing meaning (⌘K, ⌘⌫, ⌘/⌥+Enter soft
/// newline), so we pass them through untouched. Shift alone does NOT disable nav.
///
/// Uses hardware key codes (layout-independent) rather than characters: the arrow keys and Esc
/// have no useful `charactersIgnoringModifiers`, and Tab/Return are cleaner to match by code.
public func completionPopupKeyAction(keyCode: UInt16, hasCommandOptionControl: Bool) -> CompletionPopupKeyAction {
    // ⌘/⌥/⌃ combos always fall through so their existing bindings survive with a visible popup.
    guard !hasCommandOptionControl else { return .passThrough }
    switch keyCode {
    case 126: return .moveUp        // ↑
    case 125: return .moveDown      // ↓
    case 48:  return .accept        // Tab
    case 53:  return .dismiss       // Esc
    case 36, 76: return .runAndClose // Return / keypad Enter
    default:  return .passThrough    // printable, 51 = Delete/Backspace, etc.
    }
}
