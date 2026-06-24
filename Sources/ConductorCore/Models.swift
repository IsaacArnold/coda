import Foundation

public struct Repository: Codable, Equatable, Identifiable {
    public var id: String
    public var path: String
    public var name: String
    public init(id: String, path: String, name: String) {
        self.id = id; self.path = path; self.name = name
    }
}

public struct Session: Codable, Equatable, Identifiable {
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
