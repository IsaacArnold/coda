import Foundation

public struct Repository: Codable, Equatable, Identifiable {
    public var id: String
    public var path: String
    public var name: String
    public var setupScript: String
    public var copyAllowlist: [String]
    /// When true, a newly created worktree in this repo auto-runs Claude (after the
    /// setup script, if any). Off by default: worktrees are shell-first.
    public var autoLaunchClaude: Bool

    public init(id: String, path: String, name: String,
                setupScript: String = "", copyAllowlist: [String] = [],
                autoLaunchClaude: Bool = false) {
        self.id = id; self.path = path; self.name = name
        self.setupScript = setupScript; self.copyAllowlist = copyAllowlist
        self.autoLaunchClaude = autoLaunchClaude
    }

    private enum CodingKeys: String, CodingKey { case id, path, name, setupScript, copyAllowlist, autoLaunchClaude }

    // Custom decode so older configs without the setup / auto-launch fields still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decode(String.self, forKey: .name)
        setupScript = try c.decodeIfPresent(String.self, forKey: .setupScript) ?? ""
        copyAllowlist = try c.decodeIfPresent([String].self, forKey: .copyAllowlist) ?? []
        autoLaunchClaude = try c.decodeIfPresent(Bool.self, forKey: .autoLaunchClaude) ?? false
    }
}

public struct Worktree: Codable, Equatable, Identifiable {
    public var id: String
    public var repoID: String
    public var title: String
    public var branch: String
    public var worktreePath: String
    /// Identity color (hex, e.g. "#4CAF50") driving the full-width bar + sidebar accent.
    /// Chrome only — never the terminal grid. Auto-assigned at creation, manually overridable.
    public var color: String?

    public init(id: String, repoID: String, title: String, branch: String,
                worktreePath: String, color: String? = nil) {
        self.id = id; self.repoID = repoID; self.title = title
        self.branch = branch; self.worktreePath = worktreePath; self.color = color
    }

    private enum CodingKeys: String, CodingKey { case id, repoID, title, branch, worktreePath, color }

    // Custom decode so worktrees written before identity colors still load (color → nil).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        repoID = try c.decode(String.self, forKey: .repoID)
        title = try c.decode(String.self, forKey: .title)
        branch = try c.decode(String.self, forKey: .branch)
        worktreePath = try c.decode(String.self, forKey: .worktreePath)
        color = try c.decodeIfPresent(String.self, forKey: .color)
    }
}
