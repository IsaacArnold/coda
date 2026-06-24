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
}
