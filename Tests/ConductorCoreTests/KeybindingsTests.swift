// Tests/ConductorCoreTests/KeybindingsTests.swift
import XCTest
@testable import ConductorCore

final class KeyChordTests: XCTestCase {
    func testDisplayUsesCanonicalModifierOrderAndUppercaseKey() {
        XCTAssertEqual(KeyChord("n", command: true).display, "⌘N")
        XCTAssertEqual(KeyChord("r", command: true, option: true).display, "⌥⌘R")
        XCTAssertEqual(KeyChord("s", command: true, control: true).display, "⌃⌘S")
    }

    func testDisplayMapsSpecialKeys() {
        XCTAssertEqual(KeyChord("\u{8}", command: true).display, "⌘⌫")
        XCTAssertEqual(KeyChord(",", command: true).display, "⌘,")
    }

    func testCodableRoundTripWithCompactModifiers() throws {
        let chord = KeyChord("r", command: true, option: true)
        let data = try JSONEncoder().encode(chord)
        XCTAssertEqual(try JSONDecoder().decode(KeyChord.self, from: data), chord)
        // modifiers encode as a bare int, not a {rawValue:…} object
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("rawValue"))
    }
}

final class ShortcutCommandTests: XCTestCase {
    func testEveryCommandHasDisplayNameAndCategory() {
        for command in ShortcutCommand.allCases {
            XCTAssertFalse(command.displayName.isEmpty)
            XCTAssertFalse(command.category.displayName.isEmpty)
        }
    }

    func testDefaultChordsMatchTheMenu() {
        XCTAssertEqual(ShortcutCommand.newWorktree.defaultChord, KeyChord("n", command: true))
        XCTAssertEqual(ShortcutCommand.revealInFinder.defaultChord, KeyChord("r", command: true, option: true))
        XCTAssertEqual(ShortcutCommand.archiveWorktree.defaultChord, KeyChord("\u{8}", command: true))
        XCTAssertEqual(ShortcutCommand.toggleSidebar.defaultChord, KeyChord("s", command: true, control: true))
    }

    func testThereAreEightBindableCommands() {
        XCTAssertEqual(ShortcutCommand.allCases.count, 8)
    }
}
