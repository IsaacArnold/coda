import Foundation

/// A single shell-style token parsed from a command line, plus its span in the original line.
///
/// `text` is the token's *logical* value — quotes stripped and backslash-escapes resolved
/// (e.g. `my dir` for the raw `"my dir"` or `my\ dir`). `range` is a character-offset span into
/// the original line, defined as **the replacement span for accepting a completion**: replacing
/// `line[range]` with a plain (unquoted) candidate must yield a well-formed line with the
/// surrounding quoting preserved. See `tokenizeCommandLine`'s "Accept contract" for the exact
/// rules and why `range` and `text` can differ in length.
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
///
/// ### Accept contract (how `range` is defined)
/// `range` is the span a caller replaces with a plain (unquoted) completion candidate on accept:
/// `line.replacingCharacters(in: <range as String.Index>, with: candidate)` must produce a
/// well-formed line with the surrounding quoting intact. Concretely:
///
/// - **Cursor inside an open quote** (`"…`/`'…` still open at the cursor, *wherever* in the
///   token that quote opened): `range` and `cursorPrefix` are quote-relative — `range` starts
///   just *after* the opening quote, so the quote is preserved by the replacement and stays
///   balanced against any closing quote sitting after the cursor. This covers both a quote that
///   opens the token and one that opens mid-token:
///     - `cd "my dir"` with the cursor before the closing `"` (offset 10): the quoted token's
///       `range` is `4..<10` (`my dir`, not `"my dir`); replacing it with `my directory` yields
///       `cd "my directory"`, never the orphaned-quote `cd my directory"`.
///     - `cd my"dir"` (a concatenation) with the cursor before the closing `"`: the token's
///       `range` is `6..<9` (`dir`) and `cursorPrefix` is `dir`; replacing that span with
///       `directory` yields `cd my"directory"`, again well-formed and orphan-free.
/// - **Any other token** (unquoted, escaped, or a quote that already closed): `range` is the
///   token's full raw span, including any interior backslashes or already-balanced quotes.
///   Replacing it wholesale with a plain candidate drops those raw markers cleanly — e.g.
///   accepting on the escaped `cd my\ di` (`range` `3..<9`, the raw `my\ di`) with `my dir`
///   yields `cd my dir`; the backslash-escape is not re-added, and the result is well-formed.
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
    // Character offset at which the currently-open quote began (nil when not inside a quote), and
    // the length of `buffer` at that moment. Together they make the cursor token's `range` and
    // `cursorPrefix` quote-relative when the cursor is inside an open quote (see the "Accept
    // contract" doc-comment), whether the quote opened at the token's first char or after it.
    var openQuoteStart: Int?
    var openQuoteBufferLength = 0

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
                openQuoteStart = nil
            } else {
                buffer.append(char)
            }
            lastCharWasUnquotedWhitespace = false
            i += 1

        case .double:
            if char == "\"" {
                quoteState = .none
                openQuoteStart = nil
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
                openQuoteStart = i
                openQuoteBufferLength = buffer.count
                lastCharWasUnquotedWhitespace = false
                i += 1
            } else if char == "\"" {
                if tokenStart == nil { tokenStart = i }
                quoteState = .double
                openQuoteStart = i
                openQuoteBufferLength = buffer.count
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
    if let start = tokenStart {
        if let quoteStart = openQuoteStart {
            // The cursor sits inside an open quote. Make `range` and `cursorPrefix` quote-relative:
            // start `range` just after the opening quote so a plain-candidate replacement preserves
            // that quote (balancing any closing quote after the cursor), and take `cursorPrefix` as
            // the content typed since the quote. This holds regardless of where in the token the
            // quote opened — at its first char (`cd "my dir`) or after other content (`cd my"dir`).
            let quoteRelative = String(buffer.dropFirst(openQuoteBufferLength))
            cursorPrefix = quoteRelative
            tokens.append(CommandToken(text: quoteRelative, range: (quoteStart + 1)..<cursor))
        } else {
            cursorPrefix = buffer
            tokens.append(CommandToken(text: buffer, range: start..<cursor))
        }
        buffer = ""
        tokenStart = nil
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
