import XCTest
@testable import CodaCore

final class BranchStashTests: XCTestCase {
    func testLocalBranchProperties() {
        let b = Branch(name: "main", isRemote: false, isHead: true, remoteName: nil)
        XCTAssertEqual(b.shortName, "main")
        XCTAssertTrue(b.isHead)
        XCTAssertFalse(b.isRemote)
        XCTAssertNil(b.remoteName)
    }

    func testRemoteBranchStripsOriginPrefix() {
        let b = Branch(name: "origin/feature-x", isRemote: true, isHead: false, remoteName: "origin")
        XCTAssertEqual(b.shortName, "feature-x")
        XCTAssertTrue(b.isRemote)
    }

    func testRemoteBranchWithMultiSlashName() {
        let b = Branch(name: "origin/fix/login-bug", isRemote: true, isHead: false, remoteName: "origin")
        XCTAssertEqual(b.shortName, "fix/login-bug")
    }

    func testStashIdentifiable() {
        let s = Stash(id: 0, message: "WIP on main: abc1234 some commit", branch: "main")
        XCTAssertEqual(s.id, 0)
        XCTAssertEqual(s.branch, "main")
    }

    func testStashEquality() {
        let a = Stash(id: 0, message: "WIP", branch: "main")
        let b = Stash(id: 0, message: "WIP", branch: "main")
        XCTAssertEqual(a, b)
    }
}
