// Tests/CodaCoreTests/TerminalThemeTests.swift
import XCTest
@testable import CodaCore

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
        func comp(_ v: Double) -> [String: Any] { ["Red Component": v, "Green Component": v, "Blue Component": v] }
        var dict: [String: Any] = [
            "Foreground Color": comp(1), "Background Color": comp(0), "Cursor Color": comp(0.5),
        ]
        for i in 0..<16 { dict["Ansi \(i) Color"] = comp(0) }
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Dracula.itermcolors")
        try data.write(to: url)
        let theme = try TerminalTheme.load(from: url)
        XCTAssertEqual(theme.name, "Dracula")
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

    func testThrowsWhenTopLevelKeyIsAbsent() throws {
        // A plist missing "Background Color" entirely (not just its components).
        func comp(_ v: Double) -> [String: Any] { ["Red Component": v, "Green Component": v, "Blue Component": v] }
        var dict: [String: Any] = ["Foreground Color": comp(1), "Cursor Color": comp(0.5)]
        for i in 0..<16 { dict["Ansi \(i) Color"] = comp(0) }
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "nobg-" + UUID().uuidString + ".itermcolors")
        try data.write(to: url)
        XCTAssertThrowsError(try TerminalTheme.load(from: url))
    }
}
