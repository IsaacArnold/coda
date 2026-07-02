import Foundation

/// Pure logic for turning a drag-and-drop payload into text to insert into the terminal.
/// No AppKit / no pasteboard access — the AppKit glue lives in `ClickableTerminalView`.
public enum TerminalDrop {
    /// ASCII characters that never need escaping in a POSIX shell.
    private static let safeASCII = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/+-")

    /// Backslash-escape each ASCII character that isn't in `safeASCII`. Non-ASCII scalars
    /// (accented letters, emoji, …) are left as-is — a backslash before them is pointless
    /// and only makes the inserted text ugly; they aren't shell-special.
    public static func shellEscape(_ path: String) -> String {
        var out = ""
        out.reserveCapacity(path.count)
        for ch in path {
            if needsEscape(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    private static func needsEscape(_ ch: Character) -> Bool {
        let scalars = ch.unicodeScalars
        guard scalars.count == 1, let s = scalars.first, s.value < 128 else { return false }
        return !safeASCII.contains(ch)
    }
}
