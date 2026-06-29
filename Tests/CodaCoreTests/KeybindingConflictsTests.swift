// Tests/CodaCoreTests/KeybindingConflictsTests.swift
import XCTest
@testable import CodaCore

final class KeybindingConflictsTests: XCTestCase {
    func testDefaultsAreConflictFree() {
        XCTAssertTrue(keybindingConflicts(Keybindings()).isEmpty)
    }

    func testTwoCommandsOnSameChordConflictMutually() {
        var bindings = Keybindings()
        bindings.setChord(KeyChord("o", command: true), for: .newWorktree)  // == openInEditor default
        let conflicts = keybindingConflicts(bindings)
        XCTAssertEqual(conflicts[.newWorktree]?.reason, .command(.openInEditor))
        XCTAssertEqual(conflicts[.openInEditor]?.reason, .command(.newWorktree))
    }

    func testReservedTerminalChordIsFlagged() {
        var bindings = Keybindings()
        bindings.setChord(KeyChord("k", command: true), for: .launchClaude)
        XCTAssertEqual(keybindingConflicts(bindings)[.launchClaude]?.reason, .reserved("Clear"))
    }

    func testDisabledCommandNeverConflicts() {
        var bindings = Keybindings()
        bindings.setChord(KeyChord("o", command: true), for: .newWorktree)
        bindings.setEnabled(false, for: .newWorktree)
        let conflicts = keybindingConflicts(bindings)
        XCTAssertNil(conflicts[.newWorktree])
        XCTAssertNil(conflicts[.openInEditor])  // its only rival is now disabled
    }
}
