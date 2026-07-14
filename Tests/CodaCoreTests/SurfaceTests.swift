import XCTest
@testable import CodaCore

final class SurfaceTests: XCTestCase {
    func testEffectiveValuePrefersOverride() {
        let s = Surface(id: "s1", colorOverride: .pinned(RGB(r: 1, g: 0, b: 0)))
        XCTAssertEqual(s.effectiveValue(worktreeValue: .hue(.blue)), .pinned(RGB(r: 1, g: 0, b: 0)))
    }

    func testEffectiveValueFallsBackToWorktreeValue() {
        let s = Surface(id: "s1")
        XCTAssertEqual(s.effectiveValue(worktreeValue: .hue(.blue)), .hue(.blue))
    }

    func testEffectiveValueNilWhenNeither() {
        XCTAssertNil(Surface(id: "s1").effectiveValue(worktreeValue: nil))
    }

    func testDefaultKindIsWorktree() {
        XCTAssertEqual(Surface(id: "s1").kind, .worktree)
    }

    func testLabelPrefersRename() {
        XCTAssertEqual(surfaceLabel(nameOverride: "logs", repoName: "celestial-crater", index: 2), "logs")
    }

    func testLabelUsesRepoNameWhenNoRename() {
        // The first tab is just the repo name; the live shell title is ignored.
        XCTAssertEqual(surfaceLabel(nameOverride: nil, repoName: "celestial-crater", index: 0), "celestial-crater")
    }

    func testLabelDisambiguatesAdditionalTabsByNumber() {
        XCTAssertEqual(surfaceLabel(nameOverride: nil, repoName: "celestial-crater", index: 1), "celestial-crater 2")
        XCTAssertEqual(surfaceLabel(nameOverride: "  ", repoName: "celestial-crater", index: 3), "celestial-crater 4")
    }

    func testLabelFallsBackToTerminalNWithoutRepoName() {
        XCTAssertEqual(surfaceLabel(nameOverride: nil, repoName: nil, index: 0), "Terminal 1")
        XCTAssertEqual(surfaceLabel(nameOverride: "   ", repoName: "  ", index: 4), "Terminal 5")
    }
}
