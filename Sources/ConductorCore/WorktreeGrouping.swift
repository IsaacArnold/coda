import Foundation

/// A repository together with its worktrees, for display as a sidebar source-list section.
public struct RepositorySection: Equatable {
    public let repository: Repository
    public let worktrees: [Worktree]
    public init(repository: Repository, worktrees: [Worktree]) {
        self.repository = repository
        self.worktrees = worktrees
    }
}

/// Group worktrees under their repositories for the source-list sidebar.
/// Repositories keep their given order; within each, worktrees keep their given
/// order. Empty repositories are still emitted (so a worktree can be added to
/// them). Worktrees whose `repoID` matches no repository are omitted.
public func groupWorktreesByRepository(repositories: [Repository], worktrees: [Worktree]) -> [RepositorySection] {
    repositories.map { repo in
        RepositorySection(repository: repo,
                          worktrees: worktrees.filter { $0.repoID == repo.id })
    }
}
