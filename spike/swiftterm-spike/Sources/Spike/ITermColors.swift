import AppKit
import SwiftTerm

/// A terminal theme parsed from an iTerm2 `.itermcolors` file.
///
/// `.itermcolors` is an XML plist mapping keys like `Ansi 0 Color`,
/// `Foreground Color`, `Background Color`, `Cursor Color` to dicts of
/// `Red/Green/Blue Component` floats in 0...1.
struct ITermTheme {
    let name: String
    let ansi: [SwiftTerm.Color]      // 16 entries, indices 0...15
    let foreground: NSColor
    let background: NSColor
    let cursor: NSColor

    static func load(from url: URL) throws -> ITermTheme {
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization
            .propertyList(from: data, format: nil) as? [String: Any] else {
            throw SpikeError.message("Not a plist dictionary: \(url.lastPathComponent)")
        }

        func component(_ dict: [String: Any], _ key: String) -> Double {
            (dict[key] as? Double) ?? (dict[key] as? NSNumber)?.doubleValue ?? 0
        }

        func termColor(_ key: String) throws -> SwiftTerm.Color {
            guard let d = plist[key] as? [String: Any] else {
                throw SpikeError.message("Missing key \(key)")
            }
            let r = UInt16(min(max(component(d, "Red Component"), 0), 1) * 65535)
            let g = UInt16(min(max(component(d, "Green Component"), 0), 1) * 65535)
            let b = UInt16(min(max(component(d, "Blue Component"), 0), 1) * 65535)
            return SwiftTerm.Color(red: r, green: g, blue: b)
        }

        func nsColor(_ key: String) throws -> NSColor {
            guard let d = plist[key] as? [String: Any] else {
                throw SpikeError.message("Missing key \(key)")
            }
            return NSColor(srgbRed: CGFloat(component(d, "Red Component")),
                           green: CGFloat(component(d, "Green Component")),
                           blue: CGFloat(component(d, "Blue Component")),
                           alpha: 1)
        }

        var ansi: [SwiftTerm.Color] = []
        for i in 0..<16 {
            ansi.append(try termColor("Ansi \(i) Color"))
        }

        return ITermTheme(
            name: url.deletingPathExtension().lastPathComponent,
            ansi: ansi,
            foreground: try nsColor("Foreground Color"),
            background: try nsColor("Background Color"),
            cursor: try nsColor("Cursor Color")
        )
    }
}

enum SpikeError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let m): return m }
    }
}
