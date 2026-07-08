import XCTest
@testable import CodaCore

final class CommandLineTokenizerTests: XCTestCase {
    // MARK: - Empty line

    func testEmptyLineProducesNoTokens() {
        let result = tokenizeCommandLine("", cursorOffset: 0)
        XCTAssertEqual(result.tokens, [])
        XCTAssertNil(result.cursorTokenIndex)
        XCTAssertEqual(result.cursorPrefix, "")
        XCTAssertFalse(result.endsWithSeparator)
    }

    // MARK: - Cursor mid-token ("git ch|")

    func testCursorMidTokenProducesPrefixAndCurrentTokenIndex() {
        let result = tokenizeCommandLine("git ch", cursorOffset: 6)
        XCTAssertEqual(result.tokens, [
            CommandToken(text: "git", range: 0..<3),
            CommandToken(text: "ch", range: 4..<6),
        ])
        XCTAssertEqual(result.cursorTokenIndex, 1)
        XCTAssertEqual(result.cursorPrefix, "ch")
        XCTAssertFalse(result.endsWithSeparator)
    }

    // MARK: - Cursor after a trailing separator ("git |")

    func testCursorAfterTrailingSpaceStartsNewToken() {
        let result = tokenizeCommandLine("git ", cursorOffset: 4)
        XCTAssertEqual(result.tokens, [CommandToken(text: "git", range: 0..<3)])
        XCTAssertNil(result.cursorTokenIndex)
        XCTAssertEqual(result.cursorPrefix, "")
        XCTAssertTrue(result.endsWithSeparator)
    }

    func testMultipleTrailingSpacesStillEndsWithSeparator() {
        let result = tokenizeCommandLine("git   ", cursorOffset: 6)
        XCTAssertEqual(result.tokens, [CommandToken(text: "git", range: 0..<3)])
        XCTAssertNil(result.cursorTokenIndex)
        XCTAssertEqual(result.cursorPrefix, "")
        XCTAssertTrue(result.endsWithSeparator)
    }

    // MARK: - Cursor inside an unterminated quote

    func testCursorInsideDoubleQuotedTokenIsNotASeparator() {
        // Raw line as it sits on screen: cd "my dir"  — cursor is positioned right before the
        // closing quote, so only `cd "my dir` (offsets 0..<10) is ever inspected. The quoted
        // token's range starts at `m` (offset 4), NOT the opening `"` (offset 3) — see the
        // accept contract.
        let result = tokenizeCommandLine("cd \"my dir\"", cursorOffset: 10)
        XCTAssertEqual(result.tokens, [
            CommandToken(text: "cd", range: 0..<2),
            CommandToken(text: "my dir", range: 4..<10),
        ])
        XCTAssertEqual(result.cursorTokenIndex, 1)
        XCTAssertEqual(result.cursorPrefix, "my dir")
        XCTAssertFalse(result.endsWithSeparator)
    }

    func testCursorInsideSingleQuotedTokenIsNotASeparator() {
        let result = tokenizeCommandLine("cd 'my dir'", cursorOffset: 10)
        XCTAssertEqual(result.tokens, [
            CommandToken(text: "cd", range: 0..<2),
            CommandToken(text: "my dir", range: 4..<10),
        ])
        XCTAssertEqual(result.cursorTokenIndex, 1)
        XCTAssertEqual(result.cursorPrefix, "my dir")
        XCTAssertFalse(result.endsWithSeparator)
    }

    // MARK: - Backslash-escaped separator

    func testEscapedSpaceDoesNotSplitToken() {
        // Raw text: cd my\ di  (a literal backslash followed by a space).
        let result = tokenizeCommandLine("cd my\\ di", cursorOffset: 9)
        XCTAssertEqual(result.tokens, [
            CommandToken(text: "cd", range: 0..<2),
            CommandToken(text: "my di", range: 3..<9),
        ])
        XCTAssertEqual(result.cursorTokenIndex, 1)
        XCTAssertEqual(result.cursorPrefix, "my di")
        XCTAssertFalse(result.endsWithSeparator)
    }

    // MARK: - Cursor mid-line (text after the cursor is invisible to the tokenizer)

    func testTextAfterCursorIsIgnored() {
        let result = tokenizeCommandLine("git checkout main", cursorOffset: 7)
        XCTAssertEqual(result.tokens, [
            CommandToken(text: "git", range: 0..<3),
            CommandToken(text: "che", range: 4..<7),
        ])
        XCTAssertEqual(result.cursorTokenIndex, 1)
        XCTAssertEqual(result.cursorPrefix, "che")
        XCTAssertFalse(result.endsWithSeparator)
    }

    // MARK: - Multiple already-closed tokens before the cursor's token

    func testMultipleClosedTokensBeforeCursorToken() {
        let result = tokenizeCommandLine("git checkout ma", cursorOffset: 15)
        XCTAssertEqual(result.tokens, [
            CommandToken(text: "git", range: 0..<3),
            CommandToken(text: "checkout", range: 4..<12),
            CommandToken(text: "ma", range: 13..<15),
        ])
        XCTAssertEqual(result.cursorTokenIndex, 2)
        XCTAssertEqual(result.cursorPrefix, "ma")
        XCTAssertFalse(result.endsWithSeparator)
    }

    // MARK: - Out-of-range cursorOffset is clamped, not a crash

    func testNegativeCursorOffsetClampsToZero() {
        let result = tokenizeCommandLine("git", cursorOffset: -3)
        XCTAssertEqual(result.tokens, [])
        XCTAssertNil(result.cursorTokenIndex)
        XCTAssertEqual(result.cursorPrefix, "")
        XCTAssertFalse(result.endsWithSeparator)
    }

    func testCursorOffsetPastEndClampsToLineLength() {
        let result = tokenizeCommandLine("git", cursorOffset: 999)
        XCTAssertEqual(result.tokens, [CommandToken(text: "git", range: 0..<3)])
        XCTAssertEqual(result.cursorTokenIndex, 0)
        XCTAssertEqual(result.cursorPrefix, "git")
        XCTAssertFalse(result.endsWithSeparator)
    }

    // MARK: - Accept contract: a naive plain-candidate replacement stays well-formed

    func testCursorTokenRangeExcludesLeadingOpeningQuote() {
        let result = tokenizeCommandLine("cd \"my dir\"", cursorOffset: 10)
        let quotedToken = result.tokens[1]
        // range starts at `m` (offset 4), NOT at the opening `"` (offset 3), so the quote is
        // preserved when the token is replaced on accept.
        XCTAssertEqual(quotedToken.range, 4..<10)
        XCTAssertEqual(quotedToken.text, "my dir")
    }

    /// Simulates Task 4's accept flow: replace `line[cursorToken.range]` with a plain candidate
    /// and confirm the result is well-formed (the closing quote is not orphaned).
    private func acceptCandidate(_ candidate: String, into line: String, cursorOffset: Int) -> String {
        let result = tokenizeCommandLine(line, cursorOffset: cursorOffset)
        guard let index = result.cursorTokenIndex else {
            // No cursor token: candidate is inserted at the cursor (new token). Not exercised by
            // these tests, but keep the helper total.
            let cut = line.index(line.startIndex, offsetBy: cursorOffset)
            return String(line[..<cut]) + candidate + String(line[cut...])
        }
        let range = result.tokens[index].range
        let lower = line.index(line.startIndex, offsetBy: range.lowerBound)
        let upper = line.index(line.startIndex, offsetBy: range.upperBound)
        return line.replacingCharacters(in: lower..<upper, with: candidate)
    }

    func testAcceptingInsideDoubleQuotesKeepsQuotingWellFormed() {
        let accepted = acceptCandidate("my directory", into: "cd \"my dir\"", cursorOffset: 10)
        // Not the orphaned-quote `cd my directory"`.
        XCTAssertEqual(accepted, "cd \"my directory\"")
    }

    func testAcceptingInsideSingleQuotesKeepsQuotingWellFormed() {
        let accepted = acceptCandidate("my directory", into: "cd 'my dir'", cursorOffset: 10)
        XCTAssertEqual(accepted, "cd 'my directory'")
    }

    func testAcceptingOnEscapedTokenDropsBackslashAndStaysWellFormed() {
        // Raw text: cd my\ di  — accepting replaces the whole raw token (backslash included).
        let accepted = acceptCandidate("my dir", into: "cd my\\ di", cursorOffset: 9)
        XCTAssertEqual(accepted, "cd my dir")
    }

    func testAcceptingInsideMidTokenOpenedQuoteKeepsQuotingWellFormed() {
        // Concatenation: cd my"dir"  — the quote opens AFTER `my`, and the cursor sits before the
        // closing quote (offset 9). The replacement span is quote-relative (`dir`), so accepting
        // preserves both the `my` prefix and the quote pair.
        let accepted = acceptCandidate("directory", into: "cd my\"dir\"", cursorOffset: 9)
        XCTAssertEqual(accepted, "cd my\"directory\"")
    }

    func testMidTokenOpenedQuoteHasQuoteRelativePrefixAndRange() {
        // Raw text: cd my"dir  (quote opened mid-token, no closing quote yet, cursor at end).
        let result = tokenizeCommandLine("cd my\"dir", cursorOffset: 9)
        XCTAssertEqual(result.tokens, [
            CommandToken(text: "cd", range: 0..<2),
            CommandToken(text: "dir", range: 6..<9),
        ])
        XCTAssertEqual(result.cursorTokenIndex, 1)
        XCTAssertEqual(result.cursorPrefix, "dir")
        XCTAssertFalse(result.endsWithSeparator)
    }

    // MARK: - Lone trailing backslash is kept literal

    func testLoneTrailingBackslashIsKeptLiteral() {
        // Raw text: cd \  (a trailing backslash with nothing after it before the cursor).
        let result = tokenizeCommandLine("cd \\", cursorOffset: 4)
        XCTAssertEqual(result.tokens, [
            CommandToken(text: "cd", range: 0..<2),
            CommandToken(text: "\\", range: 3..<4),
        ])
        XCTAssertEqual(result.cursorTokenIndex, 1)
        XCTAssertEqual(result.cursorPrefix, "\\")
        XCTAssertFalse(result.endsWithSeparator)
    }

    // MARK: - Cursor right after an escaped separator is NOT a separator boundary

    func testCursorImmediatelyAfterEscapedSpaceIsNotASeparator() {
        // Raw text: cd my\ |  — the escaped space is part of the token, so the cursor is still
        // inside that token, not starting a new one.
        let result = tokenizeCommandLine("cd my\\ ", cursorOffset: 7)
        XCTAssertEqual(result.tokens, [
            CommandToken(text: "cd", range: 0..<2),
            CommandToken(text: "my ", range: 3..<7),
        ])
        XCTAssertEqual(result.cursorTokenIndex, 1)
        XCTAssertEqual(result.cursorPrefix, "my ")
        XCTAssertFalse(result.endsWithSeparator)
    }

    // MARK: - Interior runs of whitespace between tokens

    func testInteriorMultipleSpacesThenTextTokenizesCleanly() {
        let result = tokenizeCommandLine("git   ch", cursorOffset: 8)
        XCTAssertEqual(result.tokens, [
            CommandToken(text: "git", range: 0..<3),
            CommandToken(text: "ch", range: 6..<8),
        ])
        XCTAssertEqual(result.cursorTokenIndex, 1)
        XCTAssertEqual(result.cursorPrefix, "ch")
        XCTAssertFalse(result.endsWithSeparator)
    }

    // MARK: - Double-quote backslash-escaping is non-POSIX (proven by test, not just doc)

    func testBackslashInsideDoubleQuotesEscapesNextCharacter() {
        // Raw text: grep "\d  — POSIX would keep `\d` literal inside double quotes, but this
        // tokenizer treats backslash as escaping whatever follows, so the prefix is `d`.
        let result = tokenizeCommandLine("grep \"\\d", cursorOffset: 8)
        XCTAssertEqual(result.tokens, [
            CommandToken(text: "grep", range: 0..<4),
            CommandToken(text: "d", range: 6..<8),
        ])
        XCTAssertEqual(result.cursorTokenIndex, 1)
        XCTAssertEqual(result.cursorPrefix, "d")
        XCTAssertFalse(result.endsWithSeparator)
    }
}
