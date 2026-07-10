import XCTest
@testable import CodaCore

final class AccentColorTests: XCTestCase {
    func testResolveNilGivesDefault() {
        XCTAssertEqual(AccentColor.resolve(nil), AccentColor.defaultHex)
    }

    func testResolveKeepsStoredValue() {
        XCTAssertEqual(AccentColor.resolve("#FF5555"), "#FF5555")
    }

    func testDefaultIsOneOfTheSwatches() {
        XCTAssertTrue(AccentColor.swatches.contains(AccentColor.defaultHex))
    }

    func testDefaultIsDraculaPurple() {
        XCTAssertEqual(AccentColor.defaultHex, "#BD93F9")
    }

    func testPreferencesDecodesMissingAccentToNil() throws {
        // A prefs blob written before this feature (no accentColor key) must still load.
        let json = """
        {"defaultEditor":{"name":"Visual Studio Code","bundleID":"com.microsoft.VSCode","urlScheme":"vscode"}}
        """.data(using: .utf8)!
        let prefs = try JSONDecoder().decode(Preferences.self, from: json)
        XCTAssertNil(prefs.accentColor)
    }

    func testPreferencesRoundTripsAccent() throws {
        var prefs = Preferences()
        prefs.accentColor = "#50FA7B"
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertEqual(decoded.accentColor, "#50FA7B")
    }
}
