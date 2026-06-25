import Foundation

public struct LocalState: Codable, Equatable {
    public var repositories: [Repository]
    public var worktrees: [Worktree]
    public init(repositories: [Repository], worktrees: [Worktree]) {
        self.repositories = repositories; self.worktrees = worktrees
    }

    private enum CodingKeys: String, CodingKey { case repositories, worktrees, sessions }

    // Custom decode so configs written before the Session→Worktree rename
    // (which used the "sessions" key) still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repositories = try c.decodeIfPresent([Repository].self, forKey: .repositories) ?? []
        if let wt = try c.decodeIfPresent([Worktree].self, forKey: .worktrees) {
            worktrees = wt
        } else {
            worktrees = try c.decodeIfPresent([Worktree].self, forKey: .sessions) ?? []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(repositories, forKey: .repositories)
        try c.encode(worktrees, forKey: .worktrees)
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
            return LocalState(repositories: [], worktrees: [])
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
