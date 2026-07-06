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

    // Boundary values below were verified against real `git diff --no-index /dev/null <file>`
    // output in a scratch directory (not asserted from assumption):
    //   empty file       -> no hunk at all (0 "+" lines)
    //   "\n"             -> one "+" line containing an empty string (1)
    //   "a"              -> "+a" with "\ No newline at end of file" (1)
    //   "a\n"            -> "+a" (1, NOT 2 — this was the bug)
    //   "a\nb\n"         -> "+a" "+b" (2, NOT 3 — this was the bug)
    //   "a\nb" (no trailing newline) -> "+a" "+b" (2)
    func testUntrackedAdditionLineCount() {
        XCTAssertEqual(untrackedAdditionLineCount(""), 0)
        XCTAssertEqual(untrackedAdditionLineCount("a"), 1)          // no trailing newline
        XCTAssertEqual(untrackedAdditionLineCount("a\n"), 1)        // trailing newline: NOT 2
        XCTAssertEqual(untrackedAdditionLineCount("a\nb\n"), 2)     // was the bug: NOT 3
        XCTAssertEqual(untrackedAdditionLineCount("a\nb"), 2)       // no trailing newline
        XCTAssertEqual(untrackedAdditionLineCount("\n"), 1)         // single empty line -> "+" (empty)
    }
}
