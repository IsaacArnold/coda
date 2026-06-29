import XCTest
@testable import CodaCore

final class SlugTests: XCTestCase {
    func testSlugifyLowercasesAndHyphenates() {
        XCTAssertEqual(slugify("Add Login Flow"), "add-login-flow")
    }

    func testSlugifyStripsPunctuationAndCollapsesDashes() {
        XCTAssertEqual(slugify("Fix: the @bug!! (urgent)"), "fix-the-bug-urgent")
    }

    func testSlugifyFallsBackWhenEmpty() {
        XCTAssertEqual(slugify("!!!"), "worktree")
    }
}
