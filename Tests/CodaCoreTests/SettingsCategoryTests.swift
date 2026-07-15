import XCTest
@testable import CodaCore

final class SettingsCategoryTests: XCTestCase {
    func testOrderMatchesSidebarLayout() {
        XCTAssertEqual(SettingsCategory.allCases,
                       [.general, .appearance, .terminal, .notifications, .shortcuts])
    }

    func testCountIsFive() {
        XCTAssertEqual(SettingsCategory.allCases.count, 5)
    }

    func testTitles() {
        XCTAssertEqual(SettingsCategory.general.title, "General")
        XCTAssertEqual(SettingsCategory.appearance.title, "Appearance")
        XCTAssertEqual(SettingsCategory.terminal.title, "Terminal")
        XCTAssertEqual(SettingsCategory.notifications.title, "Notifications")
        XCTAssertEqual(SettingsCategory.shortcuts.title, "Shortcuts")
    }

    func testEverySymbolIsNonEmpty() {
        for category in SettingsCategory.allCases {
            XCTAssertFalse(category.symbolName.isEmpty, "\(category) has no SF Symbol")
        }
    }

    func testSpecificSymbols() {
        XCTAssertEqual(SettingsCategory.general.symbolName, "gearshape")
        XCTAssertEqual(SettingsCategory.appearance.symbolName, "paintpalette")
        XCTAssertEqual(SettingsCategory.terminal.symbolName, "terminal")
        XCTAssertEqual(SettingsCategory.notifications.symbolName, "bell")
        XCTAssertEqual(SettingsCategory.shortcuts.symbolName, "keyboard")
    }
}
