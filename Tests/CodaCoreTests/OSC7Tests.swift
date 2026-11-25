import XCTest
@testable import CodaCore

/// Parsing the cwd a shell reports via OSC 7 (#84). The payload is normally
/// `file://<host><percent-encoded path>`; some shells/tools send a bare path instead.
final class OSC7Tests: XCTestCase {
    func testFileURLWithHost() {
        XCTAssertEqual(directoryPath(fromOSC7: "file://my-mac.local/Users/me/repo"), "/Users/me/repo")
    }

    func testFileURLWithoutHost() {
        XCTAssertEqual(directoryPath(fromOSC7: "file:///Users/me/repo"), "/Users/me/repo")
    }

    func testPercentEncodedSpaceAndNonASCII() {
        XCTAssertEqual(directoryPath(fromOSC7: "file://host/Users/me/My%20Notes/caf%C3%A9"),
                       "/Users/me/My Notes/café")
    }

    func testUnencodedSpaceIsStillAccepted() {
        // A sloppy emitter shouldn't lose the cwd entirely.
        XCTAssertEqual(directoryPath(fromOSC7: "file://host/Users/me/My Notes"), "/Users/me/My Notes")
    }

    func testBarePath() {
        XCTAssertEqual(directoryPath(fromOSC7: "/Users/me/My%20Notes"), "/Users/me/My Notes")
        XCTAssertEqual(directoryPath(fromOSC7: "/Users/me/plain"), "/Users/me/plain")
    }

    func testRejectsGarbage() {
        XCTAssertNil(directoryPath(fromOSC7: ""))
        XCTAssertNil(directoryPath(fromOSC7: "https://example.com/x"))
        XCTAssertNil(directoryPath(fromOSC7: "relative/dir"))
    }
}
