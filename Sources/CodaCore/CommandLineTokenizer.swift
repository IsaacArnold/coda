import Foundation

/// A single shell-style token parsed from a command line, plus its raw span in the original
/// line.
///
/// `text` is the token's *logical* value — quotes stripped and backslash-escapes resolved
/// (e.g. `my dir` for the raw `"my dir"` or `my\ dir`). `range` is the *raw* span instead: the
/// exact characters on screen, including any quote or backslash characters. The two can have
/// different lengths whenever the token is quoted or escaped. `range` is what Task 4 uses as the
/// replacement span when a completion is accepted, so it must match what's actually in the
/// terminal line, not the unescaped `text`.
public struct CommandToken: Equatable {
    public let text: String
    public let range: Range<Int>

    public init(text: String, range: Range<Int>) {
        self.text = text
        self.range = range
    }
}

/// The result of tokenizing a command line from its start up to the cursor.
public struct TokenizedLine: Equatable {
    /// Tokens fully or partially consumed before/at the cursor, in order. If the cursor sits
    /// inside a token (mid-word, or inside an unterminated quote), that token is included here
    /// too, truncated as of the cursor — see `cursorTokenIndex`.
    public let tokens: [CommandToken]

    /// Index into `tokens` of the token the cursor is inside, or `nil` when the cursor sits
    /// between tokens (e.g. right after an unquoted separator) and so is starting a fresh one.
    public let cursorTokenIndex: Int?

    /// The part of the cursor's token before the cursor — i.e. `tokens[cursorTokenIndex].text`
    /// when `cursorTokenIndex` isn't `nil`, or `""` when it is. Convenience for callers that
    /// only care about the completion query, not the index.
    public let cursorPrefix: String

    /// True when the character immediately before the cursor is *unquoted* whitespace, meaning
    /// the cursor is starting a new token (e.g. after `git `, offer subcommands). Whitespace
    /// inside an open quote is content, not a separator, so this is false there.
    public let endsWithSeparator: Bool

    public init(tokens: [CommandToken], cursorTokenIndex: Int?, cursorPrefix: String, endsWithSeparator: Bool) {
        self.tokens = tokens
        self.cursorTokenIndex = cursorTokenIndex
        self.cursorPrefix = cursorPrefix
        self.endsWithSeparator = endsWithSeparator
    }
}

/// Splits `line` — from its start up to `cursorOffset` — into shell-style tokens, honoring
/// `'…'` (single quotes, fully literal), `"…"` (double quotes, backslash still escapes inside),
/// and backslash-escapes outside quotes, and identifies which token (if any) the cursor sits
/// inside.
///
/// ### Offsets
/// `cursorOffset` and every `CommandToken.range` are **character offsets** into `line`
/// (`Character`-counted, matching `line.count` — not `String.Index`, UTF-16, or UTF-8). `0`
/// means "before the first character"; `line.count` means "at the end". An out-of-range
/// `cursorOffset` (negative, or past the end) is clamped into `0...line.count` rather than
/// trapping.
///
/// Only `line[0..<cursorOffset]` (post-clamp) is ever inspected — this function implements "the
/// current command line, from the start of the editable command to the cursor", so text after
/// the cursor is invisible to it and never appears in `tokens`. A `CommandToken.range` therefore
/// never extends past the (clamped) cursor offset.
///
/// ### Cursor inside quotes
/// A cursor sitting inside an unterminated `'…'`/`"…"` is still "inside its token": that token
/// is finalized as of the cursor (its `range` upper bound is the cursor offset, not a closing
/// quote — which, being after the cursor, was never inspected), `cursorPrefix` is its unescaped
/// text so far, and `endsWithSeparator` is false, since whitespace *inside* an open quote is
/// content, not a separator.
public func tokenizeCommandLine(_ line: String, cursorOffset: Int) -> TokenizedLine {
    let characters = Array(line)
    let cursor = max(0, min(cursorOffset, characters.count))

    enum QuoteState {
        case none
        case single
        case double
    }

    var tokens: [CommandToken] = []
    var buffer = ""
    var tokenStart: Int?
    var quoteState: QuoteState = .none
    var lastCharWasUnquotedWhitespace = false

    func closeToken(at end: Int) {
        guard let start = tokenStart else { return }
        tokens.append(CommandToken(text: buffer, range: start..<end))
        buffer = ""
        tokenStart = nil
    }

    var i = 0
    while i < cursor {
        let char = characters[i]

        switch quoteState {
        case .single:
            // Single quotes are fully literal in POSIX shells: no escaping happens inside them.
            if char == "'" {
                quoteState = .none
            } else {
                buffer.append(char)
            }
            lastCharWasUnquotedWhitespace = false
            i += 1

        case .double:
            if char == "\"" {
                quoteState = .none
                i += 1
            } else if char == "\\", i + 1 < cursor {
                // Simplified double-quote escaping: backslash escapes whatever follows it. (A
                // real shell only special-cases `\`, `"`, `$`, and backtick here; that
                // distinction doesn't matter for completion purposes.)
                buffer.append(characters[i + 1])
                i += 2
            } else {
                buffer.append(char)
                i += 1
            }
            lastCharWasUnquotedWhitespace = false

        case .none:
            if char.isWhitespace {
                closeToken(at: i)
                lastCharWasUnquotedWhitespace = true
                i += 1
            } else if char == "'" {
                if tokenStart == nil { tokenStart = i }
                quoteState = .single
                lastCharWasUnquotedWhitespace = false
                i += 1
            } else if char == "\"" {
                if tokenStart == nil { tokenStart = i }
                quoteState = .double
                lastCharWasUnquotedWhitespace = false
                i += 1
            } else if char == "\\" {
                if tokenStart == nil { tokenStart = i }
                if i + 1 < cursor {
                    buffer.append(characters[i + 1])
                    i += 2
                } else {
                    // Trailing backslash with nothing (yet) to escape: keep it literal.
                    buffer.append(char)
                    i += 1
                }
                lastCharWasUnquotedWhitespace = false
            } else {
                if tokenStart == nil { tokenStart = i }
                buffer.append(char)
                lastCharWasUnquotedWhitespace = false
                i += 1
            }
        }
    }

    // Whatever's left open at the cursor (mid-token, or mid-quote) is the current token.
    let cursorTokenIndex: Int?
    let cursorPrefix: String
    if tokenStart != nil {
        cursorPrefix = buffer
        closeToken(at: cursor)
        cursorTokenIndex = tokens.count - 1
    } else {
        cursorPrefix = ""
        cursorTokenIndex = nil
    }

    return TokenizedLine(
        tokens: tokens,
        cursorTokenIndex: cursorTokenIndex,
        cursorPrefix: cursorPrefix,
        endsWithSeparator: lastCharWasUnquotedWhitespace
    )
}
