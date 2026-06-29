// Tests/CodaCoreTests/KeybindingsStoreTests.swift
import XCTest
import Foundation
@testable import CodaCore

final class KeybindingsStoreTests: XCTestCase {
    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory() + "kb-" + UUID().uuidString + ".json")
    }

    func testMissingFileLoadsEmptyOverrides() {
        XCTAssertEqual(KeybindingsStore(url: tempURL()).load(), Keybindings())
    }

    func testSaveThenLoadRoundTrips() throws {
        let url = tempURL()
        var bindings = Keybindings()
        bindings.setChord(KeyChord("j", command: true), for: .newWorktree)
        bindings.setEnabled(false, for: .archiveWorktree)
        try KeybindingsStore(url: url).save(bindings)
        // A fresh store on the same URL must read it from disk.
        XCTAssertEqual(KeybindingsStore(url: url).load(), bindings)
    }

    func testJSONIsKeyedByCommandRawValue() throws {
        let url = tempURL()
        var bindings = Keybindings()
        bindings.setChord(KeyChord("j", command: true), for: .toggleSidebar)
        try KeybindingsStore(url: url).save(bindings)
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(json.contains("\"toggleSidebar\""), "overrides must be a keyed object: \(json)")
    }
}
