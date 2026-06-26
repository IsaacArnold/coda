import XCTest
import Foundation
@testable import ConductorCore

final class PreferencesTests: XCTestCase {
    func testLoadReturnsSaneDefaultWhenFileMissing() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "prefs-" + UUID().uuidString + ".json")
        let store = PreferencesStore(url: url)
        // Missing file → defaults, and the default editor is VS Code.
        XCTAssertEqual(store.load(), Preferences())
        XCTAssertEqual(store.load().defaultEditor, .vsCode)
    }

    func testSaveThenLoadRoundTripsDefaultEditor() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "prefs-" + UUID().uuidString + ".json")
        let store = PreferencesStore(url: url)
        let cursor = Editor(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", urlScheme: "cursor")
        try store.save(Preferences(defaultEditor: cursor))
        XCTAssertEqual(store.load().defaultEditor, cursor)
        // A fresh store on the same URL must read it from disk.
        XCTAssertEqual(PreferencesStore(url: url).load().defaultEditor, cursor)
    }

    func testPreferencesHoldsNoAbsolutePaths() throws {
        // Portable config: the editor is identified by bundle id + scheme, never a path.
        let data = try JSONEncoder().encode(Preferences(defaultEditor: .vsCode))
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("/"), "Preferences must not persist absolute paths: \(json)")
    }

    func testActiveThemeDefaultsNilForOldPrefs() throws {
        // Prefs written before theming carried only defaultEditor.
        let json = #"{"defaultEditor":{"name":"Visual Studio Code","bundleID":"com.microsoft.VSCode","urlScheme":"vscode"}}"#
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        XCTAssertNil(prefs.activeTheme)
    }

    func testActiveThemeRoundTrips() throws {
        var prefs = Preferences()
        prefs.activeTheme = "Dracula"
        let back = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(back.activeTheme, "Dracula")
    }

    func testTerminalFontDefaultsNilForOldPrefs() throws {
        // Prefs written before the font picker carried no terminalFont key.
        let json = #"{"defaultEditor":{"name":"Visual Studio Code","bundleID":"com.microsoft.VSCode","urlScheme":"vscode"}}"#
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        XCTAssertNil(prefs.terminalFont)
    }

    func testTerminalFontRoundTrips() throws {
        var prefs = Preferences()
        prefs.terminalFont = TerminalFontPref(name: "DankMono-Regular", size: 15)
        let back = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(back.terminalFont, TerminalFontPref(name: "DankMono-Regular", size: 15))
    }
}

final class KnownEditorsTests: XCTestCase {
    func testIncludesVSCodeTheDefault() {
        // The picker shows a curated list; the default editor must be selectable in it.
        XCTAssertTrue(Editor.knownEditors.contains(.vsCode))
    }

    func testEveryKnownEditorHasASchemeForLineJump() {
        // Curated entries carry a real URL scheme so cmd+click line-jump works for each.
        for editor in Editor.knownEditors {
            XCTAssertFalse(editor.name.isEmpty)
            XCTAssertFalse(editor.bundleID.isEmpty)
            XCTAssertFalse(editor.urlScheme.isEmpty, "\(editor.name) needs a scheme")
        }
    }

    func testBundleIDsAreUnique() {
        let ids = Editor.knownEditors.map(\.bundleID)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate editor in the curated list")
    }
}

final class EditorURLTests: XCTestCase {
    func testBuildsLineJumpURLWhenGivenALine() {
        let url = editorOpenURL(path: "/Users/me/Project/main.swift", line: 42)
        XCTAssertEqual(url?.absoluteString, "vscode://file/Users/me/Project/main.swift:42")
    }

    func testBuildsBareFolderURLWhenNoLine() {
        let url = editorOpenURL(path: "/Users/me/Project", line: nil)
        XCTAssertEqual(url?.absoluteString, "vscode://file/Users/me/Project")
    }

    func testUsesTheGivenEditorScheme() {
        let url = editorOpenURL(scheme: "cursor", path: "/a/b.swift", line: 3)
        XCTAssertEqual(url?.absoluteString, "cursor://file/a/b.swift:3")
    }

    func testPercentEncodesSpacesInPath() {
        let url = editorOpenURL(path: "/Users/me/My Project/main.swift", line: 7)
        XCTAssertEqual(url?.absoluteString, "vscode://file/Users/me/My%20Project/main.swift:7")
    }
}
