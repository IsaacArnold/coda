import Foundation

/// Loads/saves user keybinding overrides at a JSON file. Mirrors PreferencesStore: a
/// missing or unreadable file yields empty overrides (everything at its default).
public final class KeybindingsStore {
    private let url: URL
    public init(url: URL) { self.url = url }

    public func load() -> Keybindings {
        guard let data = try? Data(contentsOf: url),
              let bindings = try? JSONDecoder().decode(Keybindings.self, from: data) else {
            return Keybindings()
        }
        return bindings
    }

    public func save(_ bindings: Keybindings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(bindings).write(to: url, options: .atomic)
    }
}
