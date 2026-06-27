import XCTest
import Foundation
@testable import ConductorCore

final class ModelsCodableTests: XCTestCase {
    func testRepositoryDecodesOldJSONWithoutNewFields() throws {
        // Mirrors an existing ~/.conductor/local.json repo entry with no setup fields.
        let json = #"{"id":"r1","path":"/tmp/repo","name":"repo"}"#
        let repo = try JSONDecoder().decode(Repository.self, from: Data(json.utf8))
        XCTAssertEqual(repo.setupScript, "")
        XCTAssertEqual(repo.copyAllowlist, [])
    }

    func testRepositoryRoundTripsNewFields() throws {
        let repo = Repository(id: "r1", path: "/tmp/repo", name: "repo",
                              setupScript: "npm install", copyAllowlist: [".env"])
        let data = try JSONEncoder().encode(repo)
        let back = try JSONDecoder().decode(Repository.self, from: data)
        XCTAssertEqual(back, repo)
    }

    func testRepositoryAutoLaunchClaudeDefaultsFalseForOldJSON() throws {
        // Configs written before the auto-launch flag existed must still decode,
        // defaulting the flag off (shell-first).
        let json = #"{"id":"r1","path":"/tmp/repo","name":"repo"}"#
        let repo = try JSONDecoder().decode(Repository.self, from: Data(json.utf8))
        XCTAssertFalse(repo.autoLaunchClaude)
    }

    func testRepositoryRoundTripsAutoLaunchClaude() throws {
        let repo = Repository(id: "r1", path: "/tmp/repo", name: "repo", autoLaunchClaude: true)
        let data = try JSONEncoder().encode(repo)
        let back = try JSONDecoder().decode(Repository.self, from: data)
        XCTAssertTrue(back.autoLaunchClaude)
        XCTAssertEqual(back, repo)
    }

    func testWorktreeDecodesOldJSONWithoutColor() throws {
        let json = #"{"id":"w1","repoID":"r1","title":"T","branch":"t","worktreePath":"/tmp/wt"}"#
        let wt = try JSONDecoder().decode(Worktree.self, from: Data(json.utf8))
        XCTAssertNil(wt.color)
    }

    func testWorktreeRoundTripsColor() throws {
        var wt = Worktree(id: "w1", repoID: "r1", title: "T", branch: "t", worktreePath: "/tmp/wt")
        wt.color = "#4CAF50"
        let back = try JSONDecoder().decode(Worktree.self, from: JSONEncoder().encode(wt))
        XCTAssertEqual(back.color, "#4CAF50")
        XCTAssertEqual(back, wt)
    }

    func testRepositoryDecodesOldJSONWithoutColorOrDisplayName() throws {
        let json = #"{"id":"r1","path":"/tmp/repo","name":"repo"}"#
        let repo = try JSONDecoder().decode(Repository.self, from: Data(json.utf8))
        XCTAssertNil(repo.displayName)
        XCTAssertNil(repo.color)
    }

    func testRepositoryRoundTripsDisplayNameAndColor() throws {
        let repo = Repository(id: "r1", path: "/tmp/repo", name: "repo",
                              displayName: "My Repo", color: "#D97757")
        let back = try JSONDecoder().decode(Repository.self,
                                            from: JSONEncoder().encode(repo))
        XCTAssertEqual(back, repo)
    }

    func testSidebarDisplayNameFallsBackAndOverrides() {
        let base = Repository(id: "r1", path: "/tmp/repo", name: "folder-name")
        XCTAssertEqual(base.sidebarDisplayName, "folder-name")                 // nil → folder name

        var blank = base; blank.displayName = "   "
        XCTAssertEqual(blank.sidebarDisplayName, "folder-name")                // whitespace → folder name

        var named = base; named.displayName = "  Pretty Name  "
        XCTAssertEqual(named.sidebarDisplayName, "Pretty Name")                // trimmed override
    }

    func testWorktreeIsMainDefaultsFalseAndIsNotPersisted() throws {
        // A synthesized main worktree carries isMain == true in memory…
        let repo = Repository(id: "R1", path: "/tmp/acme", name: "acme")
        let main = Worktree.mainCheckout(for: repo, branch: "main")
        XCTAssertTrue(main.isMain)
        XCTAssertEqual(main.id, "R1#main")
        XCTAssertEqual(main.repoID, "R1")
        XCTAssertEqual(main.title, "Default")
        XCTAssertEqual(main.worktreePath, "/tmp/acme")
        XCTAssertEqual(main.branch, "main")

        // …but isMain is in-memory only: it must not survive a JSON round-trip, and the
        // encoded JSON must not even contain the key.
        let data = try JSONEncoder().encode(main)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("isMain"), "isMain leaked into persisted JSON")
        let decoded = try JSONDecoder().decode(Worktree.self, from: data)
        XCTAssertFalse(decoded.isMain, "isMain should decode to false (not persisted)")
    }

    func testNormalWorktreeIsNotMain() {
        let wt = Worktree(id: "W1", repoID: "R1", title: "Feature", branch: "feat",
                          worktreePath: "/tmp/wt/feat")
        XCTAssertFalse(wt.isMain)
    }
}
