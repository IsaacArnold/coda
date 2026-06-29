import XCTest
@testable import CodaCore

final class RGBTests: XCTestCase {
    func testParsesSixDigitHexWithHash() {
        let c = RGB(hex: "#282A36")
        XCTAssertNotNil(c)
        XCTAssertEqual(c!.r, 40.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(c!.g, 42.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(c!.b, 54.0 / 255.0, accuracy: 0.0001)
    }

    func testParsesHexWithoutHash() {
        XCTAssertEqual(RGB(hex: "ffffff"), RGB(r: 1, g: 1, b: 1))
    }

    func testRejectsBadHex() {
        XCTAssertNil(RGB(hex: "xyz"))
        XCTAssertNil(RGB(hex: "#12"))
    }

    func testHexStringRoundTrips() {
        XCTAssertEqual(RGB(hex: "#1E90FF")!.hexString, "#1E90FF")
    }

    func testLuminanceDarkIsLowLightIsHigh() {
        XCTAssertLessThan(RGB(r: 0, g: 0, b: 0).luminance, 0.1)
        XCTAssertGreaterThan(RGB(r: 1, g: 1, b: 1).luminance, 0.9)
    }

    func testContrastingTextIsWhiteOnDarkBlackOnLight() {
        XCTAssertEqual(RGB(hex: "#222222")!.contrastingText, .white)
        XCTAssertEqual(RGB(hex: "#EEEEEE")!.contrastingText, .black)
    }
}
