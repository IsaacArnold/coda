import Foundation

public enum WorktreeStoreError: Error { case repoNotFound(String); case worktreeNotFound(String) }

public final class WorktreeStore {
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

    public func updateRepository(id: String, setupScript: String, copyAllowlist: [String],
                                 autoLaunchClaude: Bool = false) throws -> Repository {
        guard let idx = state.repositories.firstIndex(where: { $0.id == id }) else {
            throw WorktreeStoreError.repoNotFound(id)
        }
        state.repositories[idx].setupScript = setupScript
        state.repositories[idx].copyAllowlist = copyAllowlist
        state.repositories[idx].autoLaunchClaude = autoLaunchClaude
        try config.save(state)
        return state.repositories[idx]
    }

    public func createWorktree(repoID: String, title: String) throws -> Worktree {
        guard let repo = state.repositories.first(where: { $0.id == repoID }) else {
            throw WorktreeStoreError.repoNotFound(repoID)
        }
        let base = try git.currentBranch(repo: repo.path)
        let branch = uniqueBranch(base: slugify(title), repo: repo)
        let worktreePath = (worktreeRoot as NSString)
            .appendingPathComponent(repo.name)
            .appending("/").appending(branch)
        try git.add(repo: repo.path, path: worktreePath, branch: branch, base: base)

        // Seed the fresh worktree with repo-configured untracked files (e.g. .env).
        // git worktree add only brings tracked files, so these would otherwise be missing.
        _ = try copyAllowlistedFiles(from: repo.path, to: worktreePath, allowlist: repo.copyAllowlist)

        let worktree = Worktree(id: UUID().uuidString, repoID: repoID,
                                title: title, branch: branch, worktreePath: worktreePath,
                                color: IdentityPalette.color(at: state.worktrees.count))
        state.worktrees.append(worktree)
        try config.save(state)
        return worktree
    }

    public func archiveWorktree(id: String, deleteBranch: Bool) throws {
        guard let worktree = state.worktrees.first(where: { $0.id == id }) else {
            throw WorktreeStoreError.worktreeNotFound(id)
        }
        guard let repo = state.repositories.first(where: { $0.id == worktree.repoID }) else {
            throw WorktreeStoreError.repoNotFound(worktree.repoID)
        }
        try git.remove(repo: repo.path, path: worktree.worktreePath)
        if deleteBranch {
            try? git.deleteBranch(repo: repo.path, branch: worktree.branch)
        }
        state.worktrees.removeAll { $0.id == id }
        try config.save(state)
    }

    /// Override a worktree's identity color (chrome only). Pass nil to clear.
    @discardableResult
    public func setWorktreeColor(id: String, color: String?) throws -> Worktree {
        guard let idx = state.worktrees.firstIndex(where: { $0.id == id }) else {
            throw WorktreeStoreError.worktreeNotFound(id)
        }
        state.worktrees[idx].color = color
        try config.save(state)
        return state.worktrees[idx]
    }

    private func uniqueBranch(base: String, repo: Repository) -> String {
        let taken = Set(state.worktrees.filter { $0.repoID == repo.id }.map { $0.branch })
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}
