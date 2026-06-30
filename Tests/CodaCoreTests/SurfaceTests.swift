import XCTest
@testable import CodaCore

final class SurfaceTests: XCTestCase {
    func testEffectiveColorPrefersOverride() {
        let s = Surface(id: "s1", colorOverride: RGB(r: 1, g: 0, b: 0))
        XCTAssertEqual(s.effectiveColor(worktreeColor: RGB(r: 0, g: 0, b: 1)), RGB(r: 1, g: 0, b: 0))
    }

    func testEffectiveColorFallsBackToWorktreeColor() {
        let s = Surface(id: "s1")
        XCTAssertEqual(s.effectiveColor(worktreeColor: RGB(r: 0, g: 0, b: 1)), RGB(r: 0, g: 0, b: 1))
    }

    func testEffectiveColorNilWhenNeither() {
        XCTAssertNil(Surface(id: "s1").effectiveColor(worktreeColor: nil))
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
