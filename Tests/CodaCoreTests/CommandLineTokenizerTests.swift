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
        // closing quote, so only `cd "my dir` (offsets 0..<10) is ever inspected.
        let result = tokenizeCommandLine("cd \"my dir\"", cursorOffset: 10)
        XCTAssertEqual(result.tokens, [
            CommandToken(text: "cd", range: 0..<2),
            CommandToken(text: "my dir", range: 3..<10),
        ])
        XCTAssertEqual(result.cursorTokenIndex, 1)
        XCTAssertEqual(result.cursorPrefix, "my dir")
        XCTAssertFalse(result.endsWithSeparator)
    }

    func testCursorInsideSingleQuotedTokenIsNotASeparator() {
        let result = tokenizeCommandLine("cd 'my dir'", cursorOffset: 10)
        XCTAssertEqual(result.tokens, [
            CommandToken(text: "cd", range: 0..<2),
            CommandToken(text: "my dir", range: 3..<10),
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

    // MARK: - Raw ranges include quote/escape characters, not just the logical text

    func testTokenRangeSpansRawCharactersIncludingOpeningQuote() {
        let result = tokenizeCommandLine("cd \"my dir\"", cursorOffset: 10)
        let quotedToken = result.tokens[1]
        // range starts at the opening `"` (offset 3), not at `m` (offset 4).
        XCTAssertEqual(quotedToken.range, 3..<10)
        XCTAssertEqual(quotedToken.text, "my dir")
    }
}
