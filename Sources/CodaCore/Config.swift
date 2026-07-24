import Foundation

public struct LocalState: Codable, Equatable {
    public var repositories: [Repository]
    public var worktrees: [Worktree]
    /// User-created sidebar groups (Task 1). Empty for pre-sections configs.
    public var sections: [SidebarSection]
    /// Interleaved top-level order of sections and loose repos (Task 1). Empty
    /// for pre-sections configs — reconciliation then appends every repo as loose.
    public var rootOrder: [RootRef]

    public init(repositories: [Repository], worktrees: [Worktree],
                sections: [SidebarSection] = [], rootOrder: [RootRef] = []) {
        self.repositories = repositories; self.worktrees = worktrees
        self.sections = sections; self.rootOrder = rootOrder
    }

    private enum CodingKeys: String, CodingKey { case repositories, worktrees, sessions, sections, rootOrder }

    // Custom decode so configs written before the Session→Worktree rename
    // (which used the "sessions" key) — and before sidebar sections — still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repositories = try c.decodeIfPresent([Repository].self, forKey: .repositories) ?? []
        if let wt = try c.decodeIfPresent([Worktree].self, forKey: .worktrees) {
            worktrees = wt
        } else {
            worktrees = try c.decodeIfPresent([Worktree].self, forKey: .sessions) ?? []
        }
        sections = try c.decodeIfPresent([SidebarSection].self, forKey: .sections) ?? []
        rootOrder = try c.decodeIfPresent([RootRef].self, forKey: .rootOrder) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(repositories, forKey: .repositories)
        try c.encode(worktrees, forKey: .worktrees)
        try c.encode(sections, forKey: .sections)
        try c.encode(rootOrder, forKey: .rootOrder)
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
