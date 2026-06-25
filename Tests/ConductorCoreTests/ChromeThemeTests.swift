import XCTest
@testable import ConductorCore

final class ChromeThemeTests: XCTestCase {
    private func theme(bg: RGB, fg: RGB = .white, accent: RGB = RGB(hex: "#5599FF")!) -> TerminalTheme {
        var ansi = Array(repeating: RGB.black, count: 16)
        ansi[4] = accent   // ANSI 4 = blue, used as the derived accent
        return TerminalTheme(name: "t", ansi: ansi, foreground: fg, background: bg, cursor: fg)
    }

    func testDarkBackgroundYieldsDarkAppearance() {
        let chrome = ChromeTheme(terminal: theme(bg: RGB(hex: "#282A36")!))
        XCTAssertEqual(chrome.appearance, .dark)
    }

    func testLightBackgroundYieldsLightAppearance() {
        let chrome = ChromeTheme(terminal: theme(bg: RGB(hex: "#FDF6E3")!))
        XCTAssertEqual(chrome.appearance, .light)
    }

    func testWindowBackgroundIsTerminalBackground() {
        let bg = RGB(hex: "#1E1E2E")!
        XCTAssertEqual(ChromeTheme(terminal: theme(bg: bg)).color(.windowBackground), bg)
    }

    func testAccentIsAnsiFour() {
        let accent = RGB(hex: "#89B4FA")!
        XCTAssertEqual(ChromeTheme(terminal: theme(bg: .black, accent: accent)).color(.accent), accent)
    }

    func testPrimaryTextIsForeground() {
        let fg = RGB(hex: "#CDD6F4")!
        XCTAssertEqual(ChromeTheme(terminal: theme(bg: .black, fg: fg)).color(.primaryText), fg)
    }

    func testOverrideTakesPrecedenceOverDerived() {
        let override = RGB(hex: "#FF0000")!
        let chrome = ChromeTheme(terminal: theme(bg: .black), overrides: [.accent: override])
        XCTAssertEqual(chrome.color(.accent), override, "override must win over the derived value")
        // Non-overridden roles still derive.
        XCTAssertEqual(chrome.color(.windowBackground), RGB.black)
    }
}
