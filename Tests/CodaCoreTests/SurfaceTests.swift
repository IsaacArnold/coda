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
        XCTAssertEqual(surfaceLabel(nameOverride: "logs", terminalTitle: "zsh", index: 2), "logs")
    }

    func testLabelUsesTerminalTitleWhenNoRename() {
        XCTAssertEqual(surfaceLabel(nameOverride: nil, terminalTitle: "claude", index: 0), "claude")
    }

    func testLabelFallsBackToTerminalN() {
        XCTAssertEqual(surfaceLabel(nameOverride: nil, terminalTitle: "", index: 0), "Terminal 1")
        XCTAssertEqual(surfaceLabel(nameOverride: "   ", terminalTitle: nil, index: 4), "Terminal 5")
    }
}
