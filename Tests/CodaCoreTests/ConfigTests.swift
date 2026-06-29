import XCTest
import Foundation
@testable import CodaCore

final class ConfigTests: XCTestCase {
    func testLoadReturnsEmptyStateWhenFileMissing() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "cfg-" + UUID().uuidString + ".json")
        let cfg = Config(url: url)
        XCTAssertEqual(cfg.load(), LocalState(repositories: [], worktrees: []))
    }

    func testDecodesLegacyConfigWithSessionsKey() throws {
        // A config written before the Session→Worktree rename used the "sessions" key.
        // It must still load, mapping those entries into `worktrees`.
        let json = #"""
        {"repositories":[{"id":"r1","path":"/tmp/repo","name":"repo"}],
         "sessions":[{"id":"s1","repoID":"r1","title":"T","branch":"t","worktreePath":"/tmp/wt"}]}
        """#
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "legacy-" + UUID().uuidString + ".json")
        try Data(json.utf8).write(to: url)
        let state = Config(url: url).load()
        XCTAssertEqual(state.worktrees.map(\.id), ["s1"])
        XCTAssertEqual(state.repositories.map(\.id), ["r1"])
    }

    func testSaveThenLoadRoundTrips() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "cfg-" + UUID().uuidString + ".json")
        let cfg = Config(url: url)
        let state = LocalState(
            repositories: [Repository(id: "r1", path: "/tmp/repo", name: "repo")],
            worktrees: [Worktree(id: "s1", repoID: "r1", title: "T", branch: "t", worktreePath: "/tmp/wt")]
        )
        try cfg.save(state)
        XCTAssertEqual(cfg.load(), state)

        // A fresh Config on the same URL must read the persisted state from disk,
        // proving persistence rather than any in-memory retention.
        XCTAssertEqual(Config(url: url).load(), state)
    }
}
