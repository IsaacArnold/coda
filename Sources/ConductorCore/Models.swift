import Foundation

public struct Repository: Codable, Equatable, Identifiable {
    public var id: String
    public var path: String
    public var name: String
    public var setupScript: String
    public var copyAllowlist: [String]

    public init(id: String, path: String, name: String,
                setupScript: String = "", copyAllowlist: [String] = []) {
        self.id = id; self.path = path; self.name = name
        self.setupScript = setupScript; self.copyAllowlist = copyAllowlist
    }

    private enum CodingKeys: String, CodingKey { case id, path, name, setupScript, copyAllowlist }

    // Custom decode so older configs without the setup fields still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decode(String.self, forKey: .name)
        setupScript = try c.decodeIfPresent(String.self, forKey: .setupScript) ?? ""
        copyAllowlist = try c.decodeIfPresent([String].self, forKey: .copyAllowlist) ?? []
    }
}

public struct Worktree: Codable, Equatable, Identifiable {
    public var id: String
    public var repoID: String
    public var title: String
    public var branch: String
    public var worktreePath: String
    public init(id: String, repoID: String, title: String, branch: String, worktreePath: String) {
        self.id = id; self.repoID = repoID; self.title = title
        self.branch = branch; self.worktreePath = worktreePath
    }
}
