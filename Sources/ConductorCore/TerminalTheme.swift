import Foundation

public enum ThemeError: Error, CustomStringConvertible {
    case notAPlist(String)
    case missingKey(String)
    public var description: String {
        switch self {
        case .notAPlist(let f): return "Not a valid .itermcolors plist: \(f)"
        case .missingKey(let k): return "Missing color key: \(k)"
        }
    }
}

/// A terminal color scheme parsed from an iTerm2 `.itermcolors` file (an XML plist
/// mapping `Ansi 0 Color`…`Ansi 15 Color`, `Foreground/Background/Cursor Color` to
/// dicts of `Red/Green/Blue Component` floats in 0...1). Pure — no AppKit.
public struct TerminalTheme: Equatable {
    public let name: String
    public let ansi: [RGB]            // 16 entries, indices 0...15
    public let foreground: RGB
    public let background: RGB
    public let cursor: RGB

    public init(name: String, ansi: [RGB], foreground: RGB, background: RGB, cursor: RGB) {
        self.name = name; self.ansi = ansi
        self.foreground = foreground; self.background = background; self.cursor = cursor
    }

    public static func load(from url: URL) throws -> TerminalTheme {
        let data = try Data(contentsOf: url)
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw ThemeError.notAPlist(url.lastPathComponent)
        }
        guard let dict = plist as? [String: Any] else {
            throw ThemeError.notAPlist(url.lastPathComponent)
        }

        func component(_ d: [String: Any], _ key: String) -> Double {
            (d[key] as? Double) ?? (d[key] as? NSNumber)?.doubleValue ?? 0
        }
        func color(_ key: String) throws -> RGB {
            guard let d = dict[key] as? [String: Any],
                  d["Red Component"] != nil, d["Green Component"] != nil, d["Blue Component"] != nil else {
                throw ThemeError.missingKey(key)
            }
            return RGB(r: component(d, "Red Component"),
                       g: component(d, "Green Component"),
                       b: component(d, "Blue Component"))
        }

        var ansi: [RGB] = []
        for i in 0..<16 { ansi.append(try color("Ansi \(i) Color")) }
        return TerminalTheme(
            name: url.deletingPathExtension().lastPathComponent,
            ansi: ansi,
            foreground: try color("Foreground Color"),
            background: try color("Background Color"),
            cursor: try color("Cursor Color"))
    }
}
