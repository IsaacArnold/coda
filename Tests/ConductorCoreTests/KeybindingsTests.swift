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

final class KeybindingsResolutionTests: XCTestCase {
    func testEffectiveChordFallsBackToDefault() {
        let bindings = Keybindings()
        XCTAssertEqual(bindings.effectiveChord(for: .newWorktree), KeyChord("n", command: true))
        XCTAssertTrue(bindings.isEnabled(.newWorktree))
    }

    func testOverrideReplacesChord() {
        var bindings = Keybindings()
        bindings.setChord(KeyChord("j", command: true), for: .newWorktree)
        XCTAssertEqual(bindings.effectiveChord(for: .newWorktree), KeyChord("j", command: true))
    }

    func testDisabledCommandHasNoEffectiveChordButKeepsItsChord() {
        var bindings = Keybindings()
        bindings.setEnabled(false, for: .archiveWorktree)
        XCTAssertNil(bindings.effectiveChord(for: .archiveWorktree))
        XCTAssertFalse(bindings.isEnabled(.archiveWorktree))
        XCTAssertEqual(bindings.chord(for: .archiveWorktree), KeyChord("\u{8}", command: true))
    }

    func testResetRemovesOverride() {
        var bindings = Keybindings()
        bindings.setChord(KeyChord("j", command: true), for: .newWorktree)
        bindings.reset(.newWorktree)
        XCTAssertEqual(bindings.effectiveChord(for: .newWorktree), KeyChord("n", command: true))
    }
}

final class NormalizedKeyEquivalentTests: XCTestCase {
    func testMapsDeleteToBackspaceEquivalent() {
        XCTAssertEqual(normalizedKeyEquivalent(charactersIgnoringModifiers: "\u{7f}"), "\u{8}")
    }
    func testLowercasesOrdinaryKeys() {
        XCTAssertEqual(normalizedKeyEquivalent(charactersIgnoringModifiers: "A"), "a")
        XCTAssertEqual(normalizedKeyEquivalent(charactersIgnoringModifiers: ","), ",")
    }
    func testPassesThroughArrowsAndSpace() {
        XCTAssertEqual(normalizedKeyEquivalent(charactersIgnoringModifiers: " "), " ")
        XCTAssertEqual(normalizedKeyEquivalent(charactersIgnoringModifiers: "\u{f702}"), "\u{f702}")
    }
    func testRejectsEmptyAndControlChars() {
        XCTAssertNil(normalizedKeyEquivalent(charactersIgnoringModifiers: ""))
        XCTAssertNil(normalizedKeyEquivalent(charactersIgnoringModifiers: "\u{1}"))
    }
}
