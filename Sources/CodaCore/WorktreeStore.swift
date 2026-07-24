import Foundation

public enum WorktreeStoreError: Error, CustomStringConvertible {
    case repoNotFound(String)
    case worktreeNotFound(String)
    case sectionNotFound(String)
    public var description: String {
        switch self {
        case .repoNotFound(let id): return "Repository not found: \(id)"
        case .worktreeNotFound(let id): return "Worktree not found: \(id)"
        case .sectionNotFound(let id): return "Section not found: \(id)"
        }
    }
}

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

    /// The current branch of a repo's main checkout, for the synthesized main-checkout label.
    /// Resolved via `symbolic-ref`, which names the branch even on an *unborn* HEAD (a freshly
    /// `git init`'d repo with no commits). Falls back to the short SHA when HEAD is detached, where
    /// there is no symbolic ref to resolve.
    public func currentBranch(repoID: String) throws -> String {
        guard let repo = state.repositories.first(where: { $0.id == repoID }) else {
            throw WorktreeStoreError.repoNotFound(repoID)
        }
        if let branch = try? git.symbolicRef(repo: repo.path), !branch.isEmpty {
            return branch
        }
        // Detached HEAD: label with the short SHA (or "HEAD" if even that fails, e.g. unborn + detached).
        return (try? git.shortHead(repo: repo.path)) ?? "HEAD"
    }

    /// The repo's local branch names, for the "base branch" picker in New Worktree.
    public func localBranches(repoID: String) throws -> [String] {
        guard let repo = state.repositories.first(where: { $0.id == repoID }) else {
            throw WorktreeStoreError.repoNotFound(repoID)
        }
        return try git.localBranches(repo: repo.path)
    }

    /// Forget a repository: removes it and all its worktrees from local state and persists.
    /// Returns the removed worktrees so the shell can evict their surfaces. NEVER deletes any
    /// branch, worktree directory, or repo on disk — this is purely a Coda-side forget.
    @discardableResult
    public func removeRepository(id: String) throws -> [Worktree] {
        guard let idx = state.repositories.firstIndex(where: { $0.id == id }) else {
            throw WorktreeStoreError.repoNotFound(id)
        }
        let removed = state.worktrees.filter { $0.repoID == id }
        state.repositories.remove(at: idx)
        state.worktrees.removeAll { $0.repoID == id }
        try config.save(state)
        return removed
    }

    public func createWorktree(repoID: String, title: String, base: String? = nil) throws -> Worktree {
        guard let repo = state.repositories.first(where: { $0.id == repoID }) else {
            throw WorktreeStoreError.repoNotFound(repoID)
        }
        let resolvedBase = try base ?? git.currentBranch(repo: repo.path)
        let branch = uniqueBranch(base: slugify(title), repo: repo)
        let worktreePath = (worktreeRoot as NSString)
            .appendingPathComponent(repo.name)
            .appending("/").appending(branch)
        try git.add(repo: repo.path, path: worktreePath, branch: branch, base: resolvedBase)

        do {
            // Seed the fresh worktree with repo-configured untracked files (e.g. .env).
            // git worktree add only brings tracked files, so these would otherwise be missing.
            _ = try copyAllowlistedFiles(from: repo.path, to: worktreePath, allowlist: repo.copyAllowlist)

            let worktree = Worktree(id: UUID().uuidString, repoID: repoID,
                                    title: title, branch: branch, worktreePath: worktreePath,
                                    color: IdentityColorValue.hue(
                                        IdentityHue.autoAssigned(index: state.worktrees.count)).serialized,
                                    base: resolvedBase)
            state.worktrees.append(worktree)
            try config.save(state)
            return worktree
        } catch {
            // Atomicity: if anything after `git.add` fails (e.g. the save throws), roll the
            // on-disk worktree + branch back so a partial create can't leave an orphan.
            state.worktrees.removeAll { $0.worktreePath == worktreePath }
            try? git.remove(repo: repo.path, path: worktreePath)
            try? git.deleteBranch(repo: repo.path, branch: branch)
            throw error
        }
    }

    public func archiveWorktree(id: String, deleteBranch: Bool) throws {
        guard let worktree = state.worktrees.first(where: { $0.id == id }) else {
            throw WorktreeStoreError.worktreeNotFound(id)
        }
        guard let repo = state.repositories.first(where: { $0.id == worktree.repoID }) else {
            throw WorktreeStoreError.repoNotFound(worktree.repoID)
        }
        // Persist the removal first; if the save fails, nothing has changed on disk yet.
        state.worktrees.removeAll { $0.id == id }
        do {
            try config.save(state)
        } catch {
            state.worktrees.append(worktree)
            throw error
        }
        // Now the irreversible filesystem removal. If it fails, restore the entry so we don't
        // silently drop a worktree whose files still exist on disk.
        do {
            try git.remove(repo: repo.path, path: worktree.worktreePath)
        } catch {
            state.worktrees.append(worktree)
            try? config.save(state)
            throw error
        }
        if deleteBranch {
            try? git.deleteBranch(repo: repo.path, branch: worktree.branch)
        }
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

    public func setRepositoryColor(id: String, color: String?) throws -> Repository {
        guard let idx = state.repositories.firstIndex(where: { $0.id == id }) else {
            throw WorktreeStoreError.repoNotFound(id)
        }
        state.repositories[idx].color = color
        try config.save(state)
        return state.repositories[idx]
    }

    public func setRepositoryDisplayName(id: String, displayName: String?) throws -> Repository {
        guard let idx = state.repositories.firstIndex(where: { $0.id == id }) else {
            throw WorktreeStoreError.repoNotFound(id)
        }
        state.repositories[idx].displayName = displayName
        try config.save(state)
        return state.repositories[idx]
    }

    /// Reorder a repository within the sidebar list. `toIndex` is the `NSOutlineView`
    /// drop child index — the insertion slot computed BEFORE the dragged item is removed —
    /// so it's adjusted for the removal and clamped to valid bounds. A no-op move still saves.
    /// NEVER touches the repo on disk; this is purely the sidebar's display order.
    @discardableResult
    public func moveRepository(id: String, toIndex: Int) throws -> [Repository] {
        guard let current = state.repositories.firstIndex(where: { $0.id == id }) else {
            throw WorktreeStoreError.repoNotFound(id)
        }
        let repo = state.repositories.remove(at: current)
        // Drop index counts the pre-removal array; if the item came from before the
        // target slot, everything after it shifts down by one.
        var dest = current < toIndex ? toIndex - 1 : toIndex
        dest = max(0, min(dest, state.repositories.count))
        state.repositories.insert(repo, at: dest)
        try config.save(state)
        return state.repositories
    }

    // MARK: - Sidebar sections (display metadata only; never touches disk)

    /// Create an empty section, appended to the top-level order. Purely display metadata.
    @discardableResult
    public func createSection(name: String) throws -> SidebarSection {
        let section = SidebarSection(id: UUID().uuidString, name: name)
        state.sections.append(section)
        state.rootOrder.append(.section(section.id))
        try config.save(state)
        return section
    }

    /// Rename a section. A blank/whitespace name is ignored (keeps the previous name).
    @discardableResult
    public func renameSection(id: String, name: String) throws -> SidebarSection {
        guard let idx = state.sections.firstIndex(where: { $0.id == id }) else {
            throw WorktreeStoreError.sectionNotFound(id)
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { state.sections[idx].name = trimmed }
        try config.save(state)
        return state.sections[idx]
    }

    /// Delete a section, releasing its repos as loose repos at the section's former
    /// top-level position (preserving their order). Never removes any repo.
    public func deleteSection(id: String) throws {
        guard let sIdx = state.sections.firstIndex(where: { $0.id == id }) else {
            throw WorktreeStoreError.sectionNotFound(id)
        }
        let freed = state.sections[sIdx].repoIDs.map { RootRef.repo($0) }
        state.sections.remove(at: sIdx)
        if let rIdx = state.rootOrder.firstIndex(of: .section(id)) {
            state.rootOrder.replaceSubrange(rIdx...rIdx, with: freed)
        } else {
            state.rootOrder.append(contentsOf: freed)
        }
        try config.save(state)
    }

    public func setSectionCollapsed(id: String, collapsed: Bool) throws {
        guard let idx = state.sections.firstIndex(where: { $0.id == id }) else {
            throw WorktreeStoreError.sectionNotFound(id)
        }
        state.sections[idx].isCollapsed = collapsed
        try config.save(state)
    }

    public func setRepositoryCollapsed(id: String, collapsed: Bool) throws {
        guard let idx = state.repositories.firstIndex(where: { $0.id == id }) else {
            throw WorktreeStoreError.repoNotFound(id)
        }
        state.repositories[idx].isCollapsed = collapsed
        try config.save(state)
    }

    private func uniqueBranch(base: String, repo: Repository) -> String {
        let taken = Set(state.worktrees.filter { $0.repoID == repo.id }.map { $0.branch })
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}
