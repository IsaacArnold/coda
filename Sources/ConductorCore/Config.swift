import Foundation

public struct LocalState: Codable, Equatable {
    public var repositories: [Repository]
    public var sessions: [Session]
    public init(repositories: [Repository], sessions: [Session]) {
        self.repositories = repositories; self.sessions = sessions
    }
}

/// Machine-local config persisted as JSON. Holds absolute paths; this file is the
/// ONLY place absolute paths are allowed (future portable config must not have them).
public final class Config {
    private let url: URL
    public init(url: URL) { self.url = url }

    public func load() -> LocalState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(LocalState.self, from: data) else {
            return LocalState(repositories: [], sessions: [])
        }
        return state
    }

    public func save(_ state: LocalState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
