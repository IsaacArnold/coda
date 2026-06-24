import XCTest
import Foundation
@testable import ConductorCore

final class ConfigTests: XCTestCase {
    func testLoadReturnsEmptyStateWhenFileMissing() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "cfg-" + UUID().uuidString + ".json")
        let cfg = Config(url: url)
        XCTAssertEqual(cfg.load(), LocalState(repositories: [], sessions: []))
    }

    func testSaveThenLoadRoundTrips() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "cfg-" + UUID().uuidString + ".json")
        let cfg = Config(url: url)
        let state = LocalState(
            repositories: [Repository(id: "r1", path: "/tmp/repo", name: "repo")],
            sessions: [Session(id: "s1", repoID: "r1", title: "T", branch: "t", worktreePath: "/tmp/wt")]
        )
        try cfg.save(state)
        XCTAssertEqual(cfg.load(), state)
    }
}
