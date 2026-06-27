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

/// Like `groupWorktreesByRepository`, but prepends each repo's synthesized "main checkout"
/// worktree (the repo's own working dir, current branch) above its real worktrees. This is
/// what the sidebar consumes: every repo always has at least the main-checkout row.
public func sectionsWithMainCheckouts(repositories: [Repository],
                                      worktrees: [Worktree],
                                      branchForRepo: [String: String]) -> [RepositorySection] {
    repositories.map { repo in
        let main = Worktree.mainCheckout(for: repo, branch: branchForRepo[repo.id] ?? "")
        let real = worktrees.filter { $0.repoID == repo.id }
        return RepositorySection(repository: repo, worktrees: [main] + real)
    }
}
