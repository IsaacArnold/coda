import XCTest
@testable import CodaCore

final class IdentityColorValueTests: XCTestCase {
    // MARK: serialization

    func testHueSerializesToBareName() {
        XCTAssertEqual(IdentityColorValue.hue(.red).serialized, "red")
        XCTAssertEqual(IdentityColorValue.hue(.purple).serialized, "purple")
    }

    func testPinnedSerializesWithPinTag() {
        // Tagged so a pinned hex is never confused with a legacy bare #hex.
        XCTAssertEqual(IdentityColorValue.pinned(RGB(hex: "#FF5555")!).serialized, "pin:#FF5555")
    }

    func testHueRoundTrips() {
        for hue in IdentityHue.allCases {
            let v = IdentityColorValue.hue(hue)
            XCTAssertEqual(IdentityColorValue(serialized: v.serialized), v)
        }
    }

    func testPinnedRoundTrips() {
        let v = IdentityColorValue.pinned(RGB(hex: "#123456")!)
        XCTAssertEqual(IdentityColorValue(serialized: v.serialized), v)
    }

    func testInitRejectsUnknownName() {
        XCTAssertNil(IdentityColorValue(serialized: "chartreuse"))
    }

    func testInitRejectsBareLegacyHex() {
        // A bare #hex is NOT valid new-format input — it's legacy, handled by migrating(from:).
        XCTAssertNil(IdentityColorValue(serialized: "#FF5555"))
    }

    func testInitRejectsMalformedPin() {
        XCTAssertNil(IdentityColorValue(serialized: "pin:not-a-color"))
    }

    // MARK: migration

    func testMigratingNilIsNil() {
        XCTAssertNil(IdentityColorValue.migrating(from: nil))
    }

    func testMigratingLegacyDraculaHexesMapToHues() {
        // The retired IdentityPalette, mapped 1:1 to hues.
        let table: [String: IdentityHue] = [
            "#BD93F9": .purple, "#50FA7B": .green, "#FF79C6": .pink, "#8BE9FD": .cyan,
            "#FFB86C": .orange, "#6272A4": .blue, "#F1FA8C": .yellow, "#FF5555": .red,
        ]
        for (hex, hue) in table {
            XCTAssertEqual(IdentityColorValue.migrating(from: hex), .hue(hue), "\(hex)")
        }
    }

    func testMigratingLegacyHexIsCaseInsensitive() {
        XCTAssertEqual(IdentityColorValue.migrating(from: "#bd93f9"), .hue(.purple))
    }

    func testMigratingUnknownLegacyHexBecomesPinned() {
        XCTAssertEqual(IdentityColorValue.migrating(from: "#123456"),
                       .pinned(RGB(hex: "#123456")!))
    }

    func testMigratingNewFormatPassesThrough() {
        XCTAssertEqual(IdentityColorValue.migrating(from: "green"), .hue(.green))
        XCTAssertEqual(IdentityColorValue.migrating(from: "pin:#FF5555"),
                       .pinned(RGB(hex: "#FF5555")!))
    }

    func testMigratingGarbageIsNil() {
        XCTAssertNil(IdentityColorValue.migrating(from: "not-a-color"))
    }
}
