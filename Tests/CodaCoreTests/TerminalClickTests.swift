import XCTest
@testable import CodaCore

final class TerminalClickTests: XCTestCase {
    func testFindsHTTPSURL() {
        XCTAssertEqual(firstWebURL(in: "see https://example.com now")?.absoluteString,
                       "https://example.com")
    }

    func testFindsHTTPURL() {
        XCTAssertEqual(firstWebURL(in: "http://example.com/a/b")?.absoluteString,
                       "http://example.com/a/b")
    }

    func testTrimsSurroundingPunctuation() {
        XCTAssertEqual(firstWebURL(in: "(https://example.com)")?.absoluteString,
                       "https://example.com")
    }

    func testSchemelessLocalhostGetsHTTP() {
        XCTAssertEqual(firstWebURL(in: "open localhost:3000")?.absoluteString,
                       "http://localhost:3000")
    }

    func testSchemelessLoopbackIPGetsHTTP() {
        XCTAssertEqual(firstWebURL(in: "127.0.0.1:8080/path")?.absoluteString,
                       "http://127.0.0.1:8080/path")
    }

    func testBareLocalhostGetsHTTP() {
        XCTAssertEqual(firstWebURL(in: "curl localhost")?.absoluteString,
                       "http://localhost")
    }

    func testDoesNotMatchLocalhostSubstring() {
        // "localhostfoo" is not the localhost authority — must not be treated as a URL.
        XCTAssertNil(firstWebURL(in: "localhostfoo bar"))
    }

    func testReturnsNilForPlainText() {
        XCTAssertNil(firstWebURL(in: "just some words and a path Sources/main.swift"))
    }

    func testReturnsFirstURLWhenMultiple() {
        XCTAssertEqual(firstWebURL(in: "https://a.com https://b.com")?.absoluteString,
                       "https://a.com")
    }
}
