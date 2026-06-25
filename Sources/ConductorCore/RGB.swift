import Foundation

/// A color as sRGB components in 0...1. Pure value type — the AppKit shell
/// converts it to NSColor / SwiftTerm.Color. Core never imports AppKit.
public struct RGB: Equatable, Codable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    /// Parse `#RRGGBB` or `RRGGBB`. Returns nil for anything else.
    public init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        r = Double((v >> 16) & 0xFF) / 255.0
        g = Double((v >> 8) & 0xFF) / 255.0
        b = Double(v & 0xFF) / 255.0
    }

    /// Uppercase `#RRGGBB`.
    public var hexString: String {
        func byte(_ x: Double) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    /// Perceptual relative luminance (0 dark … 1 light).
    public var luminance: Double { 0.299 * r + 0.587 * g + 0.114 * b }

    /// Black or white, whichever reads better on top of this color.
    public var contrastingText: RGB { luminance < 0.5 ? .white : .black }

    public static let black = RGB(r: 0, g: 0, b: 0)
    public static let white = RGB(r: 1, g: 1, b: 1)
}
