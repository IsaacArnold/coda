import XCTest
@testable import CodaCore

final class TerminalDropTests: XCTestCase {
    func testShellEscapeLeavesSafePathUnchanged() {
        XCTAssertEqual(TerminalDrop.shellEscape("/Users/isaac/file_1.txt"), "/Users/isaac/file_1.txt")
    }

    func testShellEscapeEscapesSpacesAndSpecials() {
        XCTAssertEqual(TerminalDrop.shellEscape("/a b/c(d).txt"), "/a\\ b/c\\(d\\).txt")
        XCTAssertEqual(TerminalDrop.shellEscape("/x&y$z;q*.log"), "/x\\&y\\$z\\;q\\*.log")
        XCTAssertEqual(TerminalDrop.shellEscape("/it's \"here\""), "/it\\'s\\ \\\"here\\\"")
    }

    func testShellEscapeLeavesNonASCIIUnescaped() {
        XCTAssertEqual(TerminalDrop.shellEscape("/tmp/café/x.txt"), "/tmp/café/x.txt")
    }
}
