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
