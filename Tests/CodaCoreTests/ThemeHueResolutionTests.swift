import XCTest
@testable import CodaCore

final class ThemeHueResolutionTests: XCTestCase {
    /// A theme with 16 marker ANSI colours so fallback indices are identifiable.
    private func markerTheme(name: String) -> TerminalTheme {
        var ansi = (0..<16).map { RGB(r: Double($0) / 15.0, g: 0, b: 0) }
        ansi[9]  = RGB(hex: "#AA0000")!  // red
        ansi[10] = RGB(hex: "#00BB00")!  // green
        ansi[11] = RGB(hex: "#CCCC00")!  // yellow
        ansi[12] = RGB(hex: "#0000DD")!  // blue
        ansi[13] = RGB(hex: "#EE00EE")!  // magenta/purple
        ansi[14] = RGB(hex: "#00FFFF")!  // cyan
        return TerminalTheme(name: name, ansi: ansi,
                             foreground: RGB(hex: "#FFFFFF")!,
                             background: RGB(hex: "#000000")!,
                             cursor: .white)
    }

    // MARK: curated path

    func testCuratedThemeUsesCuratedPalette() {
        // A theme *named* Dracula resolves via the curated map, not its ANSI.
        let theme = markerTheme(name: "Dracula")
        XCTAssertEqual(theme.color(for: .purple), RGB(hex: "#BD93F9"))
        XCTAssertEqual(theme.color(for: .green), RGB(hex: "#50FA7B"))
    }

    func testDraculaPixelIdentityRegression() {
        let theme = markerTheme(name: "Dracula")
        let expected: [IdentityHue: String] = [
            .red: "#FF5555", .orange: "#FFB86C", .yellow: "#F1FA8C", .green: "#50FA7B",
            .cyan: "#8BE9FD", .blue: "#6272A4", .purple: "#BD93F9", .pink: "#FF79C6",
        ]
        for (hue, hex) in expected {
            XCTAssertEqual(theme.color(for: hue), RGB(hex: hex), "\(hue)")
        }
    }

    // MARK: ANSI fallback

    func testFallbackMapsCoreHuesToAnsiIndices() {
        let t = markerTheme(name: "Imported Theme")  // not in curated map
        XCTAssertEqual(t.color(for: .red), t.ansi[9])
        XCTAssertEqual(t.color(for: .green), t.ansi[10])
        XCTAssertEqual(t.color(for: .yellow), t.ansi[11])
        XCTAssertEqual(t.color(for: .blue), t.ansi[12])
        XCTAssertEqual(t.color(for: .purple), t.ansi[13])
        XCTAssertEqual(t.color(for: .cyan), t.ansi[14])
    }

    func testFallbackOrangeIsRedYellowBlend() {
        let t = markerTheme(name: "Imported Theme")
        XCTAssertEqual(t.color(for: .orange), t.ansi[9].blended(with: t.ansi[11], t: 0.5))
    }

    func testFallbackPinkIsLightenedMagenta() {
        let t = markerTheme(name: "Imported Theme")
        XCTAssertEqual(t.color(for: .pink), t.ansi[13].blended(with: t.foreground, t: 0.25))
    }
}
