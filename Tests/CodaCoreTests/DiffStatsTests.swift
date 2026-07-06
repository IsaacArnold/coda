import XCTest
@testable import CodaCore

final class DiffStatsTests: XCTestCase {
    func testSumsNumstat() {
        let numstat = "3\t1\tfoo.txt\n10\t0\tbar.swift\n"
        let s = diffStats(numstat: numstat, untrackedAdditions: 0)
        XCTAssertEqual(s.insertions, 13)
        XCTAssertEqual(s.deletions, 1)
        XCTAssertFalse(s.isEmpty)
    }

    func testBinaryRowsCountAsZero() {
        // git prints "-\t-\t<path>" for binary files.
        let numstat = "-\t-\timage.png\n2\t0\ttext.txt\n"
        let s = diffStats(numstat: numstat, untrackedAdditions: 0)
        XCTAssertEqual(s.insertions, 2)
        XCTAssertEqual(s.deletions, 0)
    }

    func testUntrackedCountAsAdditions() {
        let s = diffStats(numstat: "", untrackedAdditions: 5)
        XCTAssertEqual(s.insertions, 5)
        XCTAssertEqual(s.deletions, 0)
    }

    func testEmptyIsEmpty() {
        let s = diffStats(numstat: "", untrackedAdditions: 0)
        XCTAssertTrue(s.isEmpty)
    }

    func testMalformedRowsSkipped() {
        let s = diffStats(numstat: "garbage\n\n4\t2\tok.txt\n", untrackedAdditions: 0)
        XCTAssertEqual(s.insertions, 4)
        XCTAssertEqual(s.deletions, 2)
    }
}
