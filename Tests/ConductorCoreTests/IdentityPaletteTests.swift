import XCTest
@testable import ConductorCore

final class IdentityPaletteTests: XCTestCase {
    func testPaletteIsNonEmptyValidHex() {
        XCTAssertFalse(IdentityPalette.colors.isEmpty)
        for hex in IdentityPalette.colors {
            XCTAssertNotNil(RGB(hex: hex), "\(hex) is not valid hex")
        }
    }

    func testColorAtCyclesByIndex() {
        XCTAssertEqual(IdentityPalette.color(at: 0), IdentityPalette.colors[0])
        let n = IdentityPalette.colors.count
        XCTAssertEqual(IdentityPalette.color(at: n), IdentityPalette.colors[0], "wraps around")
        XCTAssertEqual(IdentityPalette.color(at: n + 1), IdentityPalette.colors[1])
    }

    func testConsecutiveColorsDiffer() {
        XCTAssertNotEqual(IdentityPalette.color(at: 0), IdentityPalette.color(at: 1))
    }
}
