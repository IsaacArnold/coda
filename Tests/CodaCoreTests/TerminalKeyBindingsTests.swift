import XCTest
@testable import CodaCore

final class TerminalKeyBindingsTests: XCTestCase {
    private func action(_ chars: String, command: Bool = true, shift: Bool = false) -> TerminalKeyAction {
        terminalKeyAction(charactersIgnoringModifiers: chars, command: command, shift: shift)
    }

    func testCommandKClears() {
        XCTAssertEqual(action("k"), .clear)
    }

    func testCommandDeleteKillsLineToStart() {
        XCTAssertEqual(action("\u{7f}"), .deleteToLineStart)   // Delete key
        XCTAssertEqual(action("\u{8}"), .deleteToLineStart)    // Backspace
    }

    func testWithoutCommandEverythingPassesThrough() {
        // A bare keystroke is normal terminal input, not a shortcut to intercept.
        XCTAssertEqual(action("k", command: false), .passThrough)
        XCTAssertEqual(action("\u{7f}", command: false), .passThrough)
    }

    func testShiftCombosPassThrough() {
        // ⌘⇧⌫ is reserved for the app (e.g. a future Delete), not line-kill.
        XCTAssertEqual(action("\u{7f}", shift: true), .passThrough)
        XCTAssertEqual(action("k", shift: true), .passThrough)
    }

    func testAppLevelCommandKeysPassThrough() {
        // Keys the menu bar owns must reach it untouched.
        for key in ["q", "n", "r", "o", "c", "v", "w", ","] {
            XCTAssertEqual(action(key), .passThrough, "⌘\(key) should pass through")
        }
    }

    func testCommandEnterInsertsNewline() {
        XCTAssertEqual(action("\r", command: true, shift: false), .insertNewline)
    }

    func testShiftEnterInsertsNewline() {
        XCTAssertEqual(terminalKeyAction(charactersIgnoringModifiers: "\r",
                                         command: false, shift: true, option: false), .insertNewline)
    }

    func testOptionEnterInsertsNewline() {
        XCTAssertEqual(terminalKeyAction(charactersIgnoringModifiers: "\r",
                                         command: false, shift: false, option: true), .insertNewline)
    }

    func testPlainEnterPassesThrough() {
        // A bare Return is normal terminal input (submit), not a soft newline.
        XCTAssertEqual(terminalKeyAction(charactersIgnoringModifiers: "\r",
                                         command: false, shift: false, option: false), .passThrough)
    }
}

/// The completion-popup navigation keymap — consulted only while the popup IS visible.
final class CompletionPopupKeyActionTests: XCTestCase {
    private func action(_ keyCode: UInt16, coc: Bool = false) -> CompletionPopupKeyAction {
        completionPopupKeyAction(keyCode: keyCode, hasCommandOptionControl: coc)
    }

    func testArrowUpMovesUp() {
        XCTAssertEqual(action(126), .moveUp)
    }

    func testArrowDownMovesDown() {
        XCTAssertEqual(action(125), .moveDown)
    }

    func testTabAccepts() {
        // Tab must be consumed on accept so it never also reaches zsh completion.
        XCTAssertEqual(action(48), .accept)
    }

    func testEscDismisses() {
        XCTAssertEqual(action(53), .dismiss)
    }

    func testReturnRunsAndCloses() {
        XCTAssertEqual(action(36), .runAndClose)   // Return
        XCTAssertEqual(action(76), .runAndClose)   // keypad Enter
    }

    func testPrintableKeyPassesThrough() {
        // 'd' (keyCode 2): a normal character re-filters the query, never navigates.
        XCTAssertEqual(action(2), .passThrough)
    }

    func testBackspacePassesThrough() {
        // Delete/Backspace (51) edits the line; the refresh re-filters, it doesn't navigate.
        XCTAssertEqual(action(51), .passThrough)
    }

    func testNavKeysWithCommandOptionControlPassThrough() {
        // ⌘/⌥/⌃ combos keep their existing meaning (⌘K, ⌘⌫, ⌘/⌥+Enter soft newline), so even
        // a nav keyCode must pass through untouched when one of those modifiers is held.
        XCTAssertEqual(action(126, coc: true), .passThrough)   // ⌘↑
        XCTAssertEqual(action(125, coc: true), .passThrough)   // ⌘↓
        XCTAssertEqual(action(48, coc: true), .passThrough)    // ⌥Tab
        XCTAssertEqual(action(53, coc: true), .passThrough)    // ⌘Esc
        XCTAssertEqual(action(36, coc: true), .passThrough)    // ⌘Return (soft newline)
    }
}
