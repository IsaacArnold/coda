import XCTest
@testable import CodaCore

final class DiffBaseTests: XCTestCase {
    func testPrefersStoredBase() {
        XCTAssertEqual(diffBaseCandidate(storedBase: "feature", mainCheckoutBranch: "main"), "feature")
    }
    func testFallsBackToMainCheckout() {
        XCTAssertEqual(diffBaseCandidate(storedBase: nil, mainCheckoutBranch: "main"), "main")
        XCTAssertEqual(diffBaseCandidate(storedBase: "  ", mainCheckoutBranch: "main"), "main")
    }
    func testNoCandidateWhenBothAbsent() {
        XCTAssertNil(diffBaseCandidate(storedBase: nil, mainCheckoutBranch: nil))
        XCTAssertNil(diffBaseCandidate(storedBase: "", mainCheckoutBranch: " "))
    }
    func testResolveMapsMergeBase() {
        XCTAssertEqual(resolveDiffBase(mergeBase: "abc123"), .sinceFork(mergeBase: "abc123"))
        XCTAssertEqual(resolveDiffBase(mergeBase: nil), .workingTreeOnly)
        XCTAssertEqual(resolveDiffBase(mergeBase: "  "), .workingTreeOnly)
    }
}
