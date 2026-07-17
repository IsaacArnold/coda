import XCTest
@testable import CodaCore

final class CuratedIdentityPalettesTests: XCTestCase {
    func testDraculaReproducesRetiredHexesExactly() {
        // HARD REQUIREMENT: a current daily Dracula user sees zero change. These
        // are the exact retired IdentityPalette hexes.
        let expected: [IdentityHue: String] = [
            .red: "#FF5555", .orange: "#FFB86C", .yellow: "#F1FA8C", .green: "#50FA7B",
            .cyan: "#8BE9FD", .blue: "#6272A4", .purple: "#BD93F9", .pink: "#FF79C6",
        ]
        let dracula = CuratedIdentityPalettes.map["Dracula"]
        XCTAssertNotNil(dracula)
        for (hue, hex) in expected {
            XCTAssertEqual(dracula?[hue], RGB(hex: hex), "\(hue)")
        }
    }

    func testEveryBundledThemeIsFullyCurated() {
        for name in CuratedIdentityPalettes.bundledThemeNames {
            guard let palette = CuratedIdentityPalettes.map[name] else {
                XCTFail("bundled theme '\(name)' has no curated palette"); continue
            }
            for hue in IdentityHue.allCases {
                XCTAssertNotNil(palette[hue], "'\(name)' missing hue \(hue)")
            }
        }
    }

    func testDraculaCuratedHexesRoundTripThroughMigration() {
        // Closes the loop: a legacy Dracula hex migrates to a hue, and that hue's
        // curated colour is the same hex. So migrated colours are pixel-identical.
        let dracula = CuratedIdentityPalettes.map["Dracula"]!
        for (hex, hue) in IdentityColorValue.legacyHexToHue {
            XCTAssertEqual(dracula[hue], RGB(hex: hex), "\(hue)")
        }
    }

    func testSevenBundledThemes() {
        XCTAssertEqual(Set(CuratedIdentityPalettes.bundledThemeNames),
                       ["Dracula", "Nord", "Solarized Light", "IsaacTheme",
                        "JetBrains Islands Dark", "Atom One Dark", "Brogrammer"])
    }
}
