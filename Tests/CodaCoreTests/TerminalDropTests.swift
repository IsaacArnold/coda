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

extension TerminalDropTests {
    func testDropTextSingleFile() {
        let u = URL(fileURLWithPath: "/a b/c.txt")
        XCTAssertEqual(TerminalDrop.dropText(fileURLs: [u], text: nil, url: nil), "/a\\ b/c.txt")
    }

    func testDropTextMultipleFilesSpaceJoinedNoTrailingSpace() {
        let a = URL(fileURLWithPath: "/x/one.txt")
        let b = URL(fileURLWithPath: "/y/t wo.txt")
        XCTAssertEqual(TerminalDrop.dropText(fileURLs: [a, b], text: nil, url: nil),
                       "/x/one.txt /y/t\\ wo.txt")
    }

    func testDropTextFilesBeatUrlAndString() {
        let f = URL(fileURLWithPath: "/f.txt")
        let web = URL(string: "https://example.com")!
        XCTAssertEqual(TerminalDrop.dropText(fileURLs: [f], text: "ignored", url: web), "/f.txt")
    }

    func testDropTextUrlWhenNoFiles() {
        let web = URL(string: "https://example.com/path?q=1")!
        XCTAssertEqual(TerminalDrop.dropText(fileURLs: [], text: "ignored", url: web),
                       "https://example.com/path?q=1")
    }

    func testDropTextStringWhenNoFilesOrUrl() {
        XCTAssertEqual(TerminalDrop.dropText(fileURLs: [], text: "hello world", url: nil), "hello world")
    }

    func testDropTextNilWhenEmpty() {
        XCTAssertNil(TerminalDrop.dropText(fileURLs: [], text: nil, url: nil))
        XCTAssertNil(TerminalDrop.dropText(fileURLs: [], text: "", url: nil))
    }
}
