// Tests/CodaCoreTests/ThemeStoreTests.swift
import XCTest
@testable import CodaCore

final class ThemeStoreTests: XCTestCase {
    /// Write a minimal `.itermcolors` to `dir` and return its URL.
    private func writeTheme(_ name: String, in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func comp(_ v: Double) -> [String: Any] { ["Red Component": v, "Green Component": v, "Blue Component": v] }
        var dict: [String: Any] = ["Foreground Color": comp(1), "Background Color": comp(0), "Cursor Color": comp(0.5)]
        for i in 0..<16 { dict["Ansi \(i) Color"] = comp(0) }
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        let url = dir.appendingPathComponent("\(name).itermcolors")
        try data.write(to: url)
        return url
    }

    private func tmpDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory() + "themes-" + UUID().uuidString, isDirectory: true)
    }

    func testListsOnlyItermcolorsFiles() throws {
        let dir = tmpDir()
        _ = try writeTheme("Dracula", in: dir)
        try "noise".write(to: dir.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        let store = ThemeStore(directory: dir)
        XCTAssertEqual(store.themeNames(), ["Dracula"])
    }

    func testImportCopiesFileIn() throws {
        let dir = tmpDir()
        let source = try writeTheme("Nord", in: tmpDir())
        let store = ThemeStore(directory: dir)
        try store.importTheme(from: source)
        XCTAssertEqual(store.themeNames(), ["Nord"])
        XCTAssertNotNil(store.loadTheme(named: "Nord"))
    }

    func testSeedIfEmptyCopiesSourcesWhenDirEmpty() throws {
        let dir = tmpDir()
        let a = try writeTheme("A", in: tmpDir())
        let b = try writeTheme("B", in: tmpDir())
        let store = ThemeStore(directory: dir)
        try store.seedIfEmpty(from: [a, b])
        XCTAssertEqual(store.themeNames(), ["A", "B"])
    }

    func testImportOverwritesSameNamedTheme() throws {
        let dir = tmpDir()
        let first = try writeTheme("Nord", in: tmpDir())
        let second = try writeTheme("Nord", in: tmpDir())  // same name, different source dir
        let store = ThemeStore(directory: dir)
        try store.importTheme(from: first)
        try store.importTheme(from: second)   // must not throw
        XCTAssertEqual(store.themeNames(), ["Nord"], "re-import overwrites, no duplicate")
    }

    func testSeedIfEmptyDoesNothingWhenNotEmpty() throws {
        let dir = tmpDir()
        _ = try writeTheme("Existing", in: dir)
        let extra = try writeTheme("Extra", in: tmpDir())
        let store = ThemeStore(directory: dir)
        try store.seedIfEmpty(from: [extra])
        XCTAssertEqual(store.themeNames(), ["Existing"], "must not seed over a populated dir")
    }
}
