import XCTest
@testable import CodaCore

final class AllowlistTextTests: XCTestCase {
    func testParsesLinesTrimmingAndDroppingBlanks() {
        let text = ".env\n  apps/web/.env.local  \n\n\tconfig\n"
        XCTAssertEqual(parseAllowlist(text), [".env", "apps/web/.env.local", "config"])
    }

    func testHandlesCRLFAndEmptyInput() {
        XCTAssertEqual(parseAllowlist(".env\r\n.env.local\r\n"), [".env", ".env.local"])
        XCTAssertEqual(parseAllowlist(""), [])
        XCTAssertEqual(parseAllowlist("   \n\t\n"), [])
    }
}
