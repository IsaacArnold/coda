import Foundation

public enum SessionStoreError: Error { case repoNotFound(String); case sessionNotFound(String) }

public final class SessionStore {
    private let config: Config
    private let git: GitWorktree
    private let worktreeRoot: String
    public private(set) var state: LocalState

    public init(config: Config, git: GitWorktree, worktreeRoot: String) {
        self.config = config
        self.git = git
        self.worktreeRoot = worktreeRoot
        self.state = config.load()
    }

    public func addRepository(path: String) throws -> Repository {
        if let existing = state.repositories.first(where: { $0.path == path }) { return existing }
        let name = URL(fileURLWithPath: path).lastPathComponent
        let repo = Repository(id: UUID().uuidString, path: path, name: name)
        state.repositories.append(repo)
        try config.save(state)
        return repo
    }

    public func createSession(repoID: String, title: String) throws -> Session {
        guard let repo = state.repositories.first(where: { $0.id == repoID }) else {
            throw SessionStoreError.repoNotFound(repoID)
        }
        let base = try git.currentBranch(repo: repo.path)
        let branch = uniqueBranch(base: slugify(title), repo: repo)
        let worktreePath = (worktreeRoot as NSString)
            .appendingPathComponent(repo.name)
            .appending("/").appending(branch)
        try git.add(repo: repo.path, path: worktreePath, branch: branch, base: base)

        let session = Session(id: UUID().uuidString, repoID: repoID,
                              title: title, branch: branch, worktreePath: worktreePath)
        state.sessions.append(session)
        try config.save(state)
        return session
    }

    public func archiveSession(id: String, deleteBranch: Bool) throws {
        guard let session = state.sessions.first(where: { $0.id == id }) else {
            throw SessionStoreError.sessionNotFound(id)
        }
        guard let repo = state.repositories.first(where: { $0.id == session.repoID }) else {
            throw SessionStoreError.repoNotFound(session.repoID)
        }
        try git.remove(repo: repo.path, path: session.worktreePath)
        if deleteBranch {
            try? git.deleteBranch(repo: repo.path, branch: session.branch)
        }
        state.sessions.removeAll { $0.id == id }
        try config.save(state)
    }

    private func uniqueBranch(base: String, repo: Repository) -> String {
        let taken = Set(state.sessions.filter { $0.repoID == repo.id }.map { $0.branch })
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}
