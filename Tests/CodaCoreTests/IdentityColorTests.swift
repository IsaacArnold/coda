import XCTest
@testable import CodaCore

final class IdentityColorTests: XCTestCase {
    func testWorktreeColorWinsOverRepo() {
        let result = identityBaseColor(worktreeColorHex: "#112233", repoColorHex: "#445566")
        XCTAssertEqual(result, RGB(hex: "#112233"))
    }

    func testFallsBackToRepoWhenWorktreeNil() {
        let result = identityBaseColor(worktreeColorHex: nil, repoColorHex: "#445566")
        XCTAssertEqual(result, RGB(hex: "#445566"))
    }

    func testWorktreeColorWithoutRepoColor() {
        let result = identityBaseColor(worktreeColorHex: "#112233", repoColorHex: nil)
        XCTAssertEqual(result, RGB(hex: "#112233"))
    }

    func testNilWhenNeitherSet() {
        XCTAssertNil(identityBaseColor(worktreeColorHex: nil, repoColorHex: nil))
    }

    func testUnparseableWorktreeHexFallsBackToRepo() {
        // A malformed worktree hex must not swallow the repo fallback.
        let result = identityBaseColor(worktreeColorHex: "not-a-color", repoColorHex: "#445566")
        XCTAssertEqual(result, RGB(hex: "#445566"))
    }
}
