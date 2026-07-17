import Foundation

/// Manages `.itermcolors` files in the portable themes directory (~/.coda/themes/).
/// Import copies a file in; seed populates the dir from bundled starter themes on first run.
public final class ThemeStore {
    private let directory: URL
    private let fm = FileManager.default

    public init(directory: URL) { self.directory = directory }

    public func availableThemeURLs() -> [URL] {
        guard let urls = try? fm.contentsOfDirectory(at: directory,
                                                     includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension == "itermcolors" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func themeNames() -> [String] {
        availableThemeURLs().map { $0.deletingPathExtension().lastPathComponent }
    }

    public func loadTheme(named name: String) -> TerminalTheme? {
        let url = directory.appendingPathComponent("\(name).itermcolors")
        return try? TerminalTheme.load(from: url)
    }

    /// Copy a `.itermcolors` into the themes dir (overwriting a same-named one). Returns the destination.
    @discardableResult
    public func importTheme(from source: URL) throws -> URL {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(source.lastPathComponent)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: source, to: dest)
        return dest
    }

    /// Populate the themes dir from `sources` only if it currently has no themes.
    public func seedIfEmpty(from sources: [URL]) throws {
        guard availableThemeURLs().isEmpty else { return }
        for source in sources { try importTheme(from: source) }
    }

    /// Delete the named themes from the dir if present (no-op for absent ones).
    /// Used to retire bundled themes on upgrade — pass only names the app itself
    /// shipped, since this can't tell an app-installed theme from a user's own.
    public func removeThemes(named names: [String]) {
        for name in names {
            let url = directory.appendingPathComponent("\(name).itermcolors")
            if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
        }
    }

    /// Copy in each source whose destination doesn't already exist. Unlike
    /// `seedIfEmpty`, this runs on every launch so upgraders receive newly-bundled
    /// themes — while never overwriting a theme the user already has (or edited).
    public func installMissing(from sources: [URL]) throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for source in sources {
            let dest = directory.appendingPathComponent(source.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: source, to: dest) }
        }
    }
}
