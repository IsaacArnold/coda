import Foundation

/// An editor app, identified portably (bundle id + URL scheme — never an absolute path).
public struct Editor: Codable, Equatable {
    public var name: String
    public var bundleID: String
    public var urlScheme: String
    public init(name: String, bundleID: String, urlScheme: String) {
        self.name = name; self.bundleID = bundleID; self.urlScheme = urlScheme
    }

    public static let vsCode = Editor(name: "Visual Studio Code",
                                      bundleID: "com.microsoft.VSCode",
                                      urlScheme: "vscode")

    /// Curated editors offered by the Settings picker, each with a known URL scheme so
    /// cmd+click line-jump works out of the box. Users can still pick any other app via
    /// the "Other…" path (bundle id only — no line-jump scheme).
    public static let knownEditors: [Editor] = [
        .vsCode,
        Editor(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", urlScheme: "cursor"),
        Editor(name: "VSCodium", bundleID: "com.vscodium", urlScheme: "vscodium"),
        Editor(name: "Zed", bundleID: "dev.zed.Zed", urlScheme: "zed"),
        Editor(name: "Sublime Text", bundleID: "com.sublimetext.4", urlScheme: "subl"),
    ]
}

/// App-wide, portable preferences (no machine-local absolute paths). Separate from
/// `Config`, which is the only place absolute paths are allowed.
public struct Preferences: Codable, Equatable {
    public var defaultEditor: Editor
    public init(defaultEditor: Editor = .vsCode) {
        self.defaultEditor = defaultEditor
    }
}

public final class PreferencesStore {
    private let url: URL
    public init(url: URL) { self.url = url }

    public func load() -> Preferences {
        guard let data = try? Data(contentsOf: url),
              let preferences = try? JSONDecoder().decode(Preferences.self, from: data) else {
            return Preferences()
        }
        return preferences
    }

    public func save(_ preferences: Preferences) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preferences).write(to: url, options: .atomic)
    }
}

/// Build an editor deep-link that opens a path (a worktree dir or a file), jumping
/// to `line` when given. Mirrors VS Code's `<scheme>://file/<path>:<line>` form;
/// line-jump is best-effort per editor.
public func editorOpenURL(scheme: String = "vscode", path: String, line: Int?) -> URL? {
    let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    var string = "\(scheme)://file\(encoded)"
    if let line { string += ":\(line)" }
    return URL(string: string)
}
