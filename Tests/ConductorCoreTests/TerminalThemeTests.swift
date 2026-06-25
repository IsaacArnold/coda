// Tests/ConductorCoreTests/TerminalThemeTests.swift
import XCTest
@testable import ConductorCore

final class TerminalThemeTests: XCTestCase {
    /// Write a minimal valid `.itermcolors` plist to a temp file and return its URL.
    private func writeITermColors(name: String) throws -> URL {
        func comp(_ r: Double, _ g: Double, _ b: Double) -> [String: Any] {
            ["Red Component": r, "Green Component": g, "Blue Component": b]
        }
        var dict: [String: Any] = [
            "Foreground Color": comp(1, 1, 1),
            "Background Color": comp(0, 0, 0),
            "Cursor Color": comp(0.5, 0.5, 0.5),
        ]
        for i in 0..<16 { dict["Ansi \(i) Color"] = comp(Double(i) / 15.0, 0, 0) }
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + name + "-" + UUID().uuidString + ".itermcolors")
        try data.write(to: url)
        return url
    }

    func testParsesSixteenAnsiPlusFgBgCursor() throws {
        let url = try writeITermColors(name: "Test")
        let theme = try TerminalTheme.load(from: url)
        XCTAssertEqual(theme.ansi.count, 16)
        XCTAssertEqual(theme.foreground, RGB(r: 1, g: 1, b: 1))
        XCTAssertEqual(theme.background, RGB(r: 0, g: 0, b: 0))
        XCTAssertEqual(theme.cursor, RGB(r: 0.5, g: 0.5, b: 0.5))
        XCTAssertEqual(theme.ansi[15].r, 1, accuracy: 0.0001)
    }

    func testNameComesFromFilename() throws {
        let url = try writeITermColors(name: "Dracula")
        let theme = try TerminalTheme.load(from: url)
        XCTAssertTrue(theme.name.hasPrefix("Dracula"))
    }

    func testThrowsOnNonPlist() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "junk-" + UUID().uuidString + ".itermcolors")
        try "not a plist".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try TerminalTheme.load(from: url))
    }

    func testThrowsOnMissingKey() throws {
        let dict: [String: Any] = ["Foreground Color": ["Red Component": 1.0]]  // missing the rest
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "partial-" + UUID().uuidString + ".itermcolors")
        try data.write(to: url)
        XCTAssertThrowsError(try TerminalTheme.load(from: url))
    }
}
