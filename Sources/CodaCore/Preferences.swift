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

/// A terminal font choice, stored portably by PostScript name + point size (never a path).
public struct TerminalFontPref: Codable, Equatable {
    public var name: String
    public var size: Double
    public init(name: String, size: Double) {
        self.name = name; self.size = size
    }
}

/// App-wide interface (chrome) size, as four presets. The multiplier scales chrome
/// fonts and geometry; `.medium` (1.0) is the app's default look. Pure/UI-free so the
/// scale math is testable in CodaCore — the AppKit `UIMetrics` type consumes it.
public enum UIScale: String, Codable, CaseIterable {
    case small, medium, large, xlarge

    public var multiplier: Double {
        switch self {
        case .small:  return 0.9
        case .medium: return 1.0
        case .large:  return 1.15
        case .xlarge: return 1.3
        }
    }

    public var displayName: String {
        switch self {
        case .small:  return "Small"
        case .medium: return "Medium"
        case .large:  return "Large"
        case .xlarge: return "Extra Large"
        }
    }

    /// Scale a base point/length to the nearest whole point.
    public func scaled(_ base: Double) -> Double { (base * multiplier).rounded() }
}

/// App-wide, portable preferences (no machine-local absolute paths). Separate from
/// `Config`, which is the only place absolute paths are allowed.
public struct Preferences: Codable, Equatable {
    public var defaultEditor: Editor
    /// Name of the active terminal theme (a file in ~/.coda/themes/). nil → the
    /// app falls back to its default bundled theme. The custom decoder below decodes
    /// a missing key to nil, so older prefs files still load.
    public var activeTheme: String?
    /// The terminal font. nil → the app's default monospaced font. The custom decoder
    /// below decodes a missing key to nil, so older prefs files still load.
    public var terminalFont: TerminalFontPref?
    /// The interface (chrome) size. Defaults to `.medium`; older prefs files without
    /// the key decode to `.medium` via the custom decoder below.
    public var uiScale: UIScale
    /// Whether the user declined the "Enable live agent status" hook-install consent
    /// prompt. Defaults to `false`; older prefs files without the key decode to `false`
    /// via the custom decoder below, so they still see the prompt once.
    public var declinedHookInstall: Bool
    /// Whether to post a macOS notification when an agent transitions to "needs you".
    /// Defaults to `true`; older prefs files without the key decode to `true` via the
    /// custom decoder below, so existing users get notifications on by default.
    public var notifyOnNeedsYou: Bool
    /// Whether to post a macOS notification when an agent transitions to "done".
    /// Defaults to `true`; older prefs files without the key decode to `true` via the
    /// custom decoder below, so existing users get notifications on by default.
    public var notifyOnDone: Bool
    /// The shell to spawn in new terminals. Defaults to `.automatic` (the login shell);
    /// older prefs files without the key decode to `.automatic` via the custom decoder below.
    /// Changing this affects new terminals only. Portable (an enum, never a path).
    public var shell: ShellChoice
    /// Whether the terminal-completions shell integration (the bundled `ZDOTDIR` wrapper that
    /// emits OSC 133 prompt markers) is injected into newly-spawned terminals. Defaults to
    /// `false` — pre-consent it is off; the first-run consent prompt flips it on if the user
    /// accepts. Older prefs files without the key decode to `false` via the custom decoder
    /// below. Changing this affects newly-opened terminals only.
    public var completionsEnabled: Bool
    /// Whether the first-run terminal-completions consent prompt has already been shown.
    /// Defaults to `false`; older prefs files without the key decode to `false` via the custom
    /// decoder below, so existing users see the prompt exactly once.
    public var askedCompletionsConsent: Bool
    public init(defaultEditor: Editor = .vsCode, activeTheme: String? = nil,
                terminalFont: TerminalFontPref? = nil, uiScale: UIScale = .medium,
                declinedHookInstall: Bool = false, notifyOnNeedsYou: Bool = true,
                notifyOnDone: Bool = true, shell: ShellChoice = .automatic,
                completionsEnabled: Bool = false, askedCompletionsConsent: Bool = false) {
        self.defaultEditor = defaultEditor
        self.activeTheme = activeTheme
        self.terminalFont = terminalFont
        self.uiScale = uiScale
        self.declinedHookInstall = declinedHookInstall
        self.notifyOnNeedsYou = notifyOnNeedsYou
        self.notifyOnDone = notifyOnDone
        self.shell = shell
        self.completionsEnabled = completionsEnabled
        self.askedCompletionsConsent = askedCompletionsConsent
    }

    // Synthesized Codable would make `uiScale`/`declinedHookInstall`/`notifyOnNeedsYou`/
    // `notifyOnDone`/`completionsEnabled`/`askedCompletionsConsent` required keys and fail to
    // decode older prefs files. A custom decoder defaults each missing key (and keeps the other
    // keys' existing optional/required behavior).
    private enum CodingKeys: String, CodingKey {
        case defaultEditor, activeTheme, terminalFont, uiScale, declinedHookInstall
        case notifyOnNeedsYou, notifyOnDone, shell, completionsEnabled, askedCompletionsConsent
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.defaultEditor = try c.decode(Editor.self, forKey: .defaultEditor)
        self.activeTheme = try c.decodeIfPresent(String.self, forKey: .activeTheme)
        self.terminalFont = try c.decodeIfPresent(TerminalFontPref.self, forKey: .terminalFont)
        self.uiScale = try c.decodeIfPresent(UIScale.self, forKey: .uiScale) ?? .medium
        self.declinedHookInstall = try c.decodeIfPresent(Bool.self, forKey: .declinedHookInstall) ?? false
        self.notifyOnNeedsYou = try c.decodeIfPresent(Bool.self, forKey: .notifyOnNeedsYou) ?? true
        self.notifyOnDone = try c.decodeIfPresent(Bool.self, forKey: .notifyOnDone) ?? true
        self.shell = try c.decodeIfPresent(ShellChoice.self, forKey: .shell) ?? .automatic
        self.completionsEnabled = try c.decodeIfPresent(Bool.self, forKey: .completionsEnabled) ?? false
        self.askedCompletionsConsent = try c.decodeIfPresent(Bool.self, forKey: .askedCompletionsConsent) ?? false
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
