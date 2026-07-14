import XCTest
@testable import CodaCore

final class IdentityColorResolutionTests: XCTestCase {
    private let dracula = TerminalTheme(
        name: "Dracula",
        ansi: (0..<16).map { _ in RGB(hex: "#010101")! },
        foreground: .white, background: .black, cursor: .white)

    // MARK: IdentityColorValue.resolved(theme:)

    func testHueResolvesThroughTheme() {
        XCTAssertEqual(IdentityColorValue.hue(.purple).resolved(dracula), RGB(hex: "#BD93F9"))
    }

    func testPinnedIgnoresTheme() {
        let pin = RGB(hex: "#123456")!
        XCTAssertEqual(IdentityColorValue.pinned(pin).resolved(dracula), pin)
    }

    // MARK: chain precedence

    func testSurfaceWinsOverWorktreeAndRepo() {
        let c = resolvedIdentityColor(surface: .hue(.red), worktree: .hue(.green),
                                      repo: .hue(.blue), theme: dracula)
        XCTAssertEqual(c, RGB(hex: "#FF5555"))
    }

    func testWorktreeWinsWhenNoSurface() {
        let c = resolvedIdentityColor(surface: nil, worktree: .hue(.green),
                                      repo: .hue(.blue), theme: dracula)
        XCTAssertEqual(c, RGB(hex: "#50FA7B"))
    }

    func testRepoUsedWhenNoSurfaceOrWorktree() {
        let c = resolvedIdentityColor(surface: nil, worktree: nil,
                                      repo: .hue(.cyan), theme: dracula)
        XCTAssertEqual(c, RGB(hex: "#8BE9FD"))
    }

    func testNilWhenNothingSet() {
        XCTAssertNil(resolvedIdentityColor(surface: nil, worktree: nil, repo: nil, theme: dracula))
    }

    // MARK: AccentColor

    func testAccentDefaultIsPurpleHue() {
        XCTAssertEqual(AccentColor.defaultValue, .hue(.purple))
    }

    func testAccentResolvesNilToDraculaPurple() {
        XCTAssertEqual(AccentColor.resolve(nil, theme: dracula), RGB(hex: "#BD93F9"))
    }

    func testAccentResolvesLegacyStoredHex() {
        // An upgrading user's stored accent hex migrates to a hue and follows the theme.
        XCTAssertEqual(AccentColor.resolve("#FF5555", theme: dracula), RGB(hex: "#FF5555"))
    }
}
