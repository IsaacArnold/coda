// Tests/CodaCoreTests/KeybindingsTests.swift
import XCTest
@testable import CodaCore

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

    func testThereAreTwentySevenBindableCommands() {
        XCTAssertEqual(ShortcutCommand.allCases.count, 27)
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

final class SurfaceShortcutTests: XCTestCase {
    func testNewSurfaceDefaultsToCommandT() {
        XCTAssertEqual(ShortcutCommand.newSurface.defaultChord, KeyChord("t", command: true))
    }
    func testCloseSurfaceDefaultsToCommandW() {
        XCTAssertEqual(ShortcutCommand.closeSurface.defaultChord, KeyChord("w", command: true))
    }
    func testNextPrevDefaults() {
        XCTAssertEqual(ShortcutCommand.nextSurface.defaultChord, KeyChord("]", command: true, shift: true))
        XCTAssertEqual(ShortcutCommand.prevSurface.defaultChord, KeyChord("[", command: true, shift: true))
    }
    func testSplitDefaultsToCommandD() {
        XCTAssertEqual(ShortcutCommand.splitSurface.defaultChord, KeyChord("d", command: true))
    }
    func testGoToSurfaceDefaultsAreCommandDigits() {
        XCTAssertEqual(ShortcutCommand.goToSurface1.defaultChord, KeyChord("1", command: true))
        XCTAssertEqual(ShortcutCommand.goToSurface9.defaultChord, KeyChord("9", command: true))
    }
    func testAllSurfaceCommandsAreInSurfaceCategory() {
        let surfaceCmds: [ShortcutCommand] = [.newSurface, .closeSurface, .nextSurface,
            .prevSurface, .splitSurface, .goToSurface1, .goToSurface5, .goToSurface9]
        for cmd in surfaceCmds { XCTAssertEqual(cmd.category, .surface) }
    }
    func testDefaultBindingsHaveNoConflicts() {
        XCTAssertTrue(keybindingConflicts(Keybindings()).isEmpty)
    }
}

final class PaneShortcutTests: XCTestCase {
    func testSplitRightKeepsCommandDAndIsRenamed() {
        XCTAssertEqual(ShortcutCommand.splitSurface.defaultChord, KeyChord("d", command: true))
        XCTAssertEqual(ShortcutCommand.splitSurface.displayName, "Split Right")
    }
    func testSplitDownIsShiftCommandD() {
        XCTAssertEqual(ShortcutCommand.splitDown.defaultChord, KeyChord("d", command: true, shift: true))
        XCTAssertEqual(ShortcutCommand.splitDown.category, .surface)
    }
    func testFocusPaneDefaultsAreCommandOptionArrows() {
        XCTAssertEqual(ShortcutCommand.focusPaneLeft.defaultChord,  KeyChord("\u{f702}", command: true, option: true))
        XCTAssertEqual(ShortcutCommand.focusPaneRight.defaultChord, KeyChord("\u{f703}", command: true, option: true))
        XCTAssertEqual(ShortcutCommand.focusPaneUp.defaultChord,    KeyChord("\u{f700}", command: true, option: true))
        XCTAssertEqual(ShortcutCommand.focusPaneDown.defaultChord,  KeyChord("\u{f701}", command: true, option: true))
    }
    func testAllPaneCommandsAreSurfaceCategory() {
        for c in [ShortcutCommand.splitDown, .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown] {
            XCTAssertEqual(c.category, .surface)
        }
    }
    func testDefaultBindingsStillHaveNoConflicts() {
        XCTAssertTrue(keybindingConflicts(Keybindings()).isEmpty)
    }
}
