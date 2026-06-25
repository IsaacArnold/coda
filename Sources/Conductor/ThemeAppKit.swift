// Sources/Conductor/ThemeAppKit.swift
import AppKit
import SwiftTerm
import ConductorCore

extension RGB {
    /// sRGB NSColor for chrome.
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
    }

    /// SwiftTerm color (UInt16 0...65535 channels), matching the spike's conversion.
    var swiftTermColor: SwiftTerm.Color {
        func chan(_ x: Double) -> UInt16 { UInt16(min(max(x, 0), 1) * 65535) }
        return SwiftTerm.Color(red: chan(r), green: chan(g), blue: chan(b))
    }
}

extension NSColor {
    /// Convenience for hex strings stored on a worktree's identity color.
    convenience init?(hex: String) {
        guard let rgb = RGB(hex: hex) else { return nil }
        self.init(srgbRed: CGFloat(rgb.r), green: CGFloat(rgb.g), blue: CGFloat(rgb.b), alpha: 1)
    }
}

extension ThemeAppearance {
    var nsAppearance: NSAppearance? {
        switch self {
        case .dark:  return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        }
    }
}
