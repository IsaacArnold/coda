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
}
