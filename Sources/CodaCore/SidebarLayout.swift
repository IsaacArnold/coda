import Foundation

/// The cleaned, invariant-satisfying sidebar layout (Task 2).
public struct ReconciledLayout: Equatable {
    public var sections: [SidebarSection]
    public var rootOrder: [RootRef]
    public init(sections: [SidebarSection], rootOrder: [RootRef]) {
        self.sections = sections; self.rootOrder = rootOrder
    }
}

/// Clean a persisted (sections, rootOrder) overlay against the set of repos that
/// actually exist, enforcing: every existing repo appears exactly once (loose OR
/// in one section), every section appears exactly once at root, and no ref points
/// at a missing id. Unreferenced repos/sections are appended deterministically
/// (repos in `repositories` array order), which reproduces today's exact layout
/// for a pre-sections config (empty sections + empty rootOrder). Duplicate ids in
/// the input `sections` or `repositories` arrays are folded first-wins: the first
/// occurrence is kept and later duplicates are dropped before any claiming happens.
public func reconcileSidebarLayout(repositories: [Repository],
                                   sections: [SidebarSection],
                                   rootOrder: [RootRef]) -> ReconciledLayout {
    let existingRepoIDs = Set(repositories.map { $0.id })

    // 0. Fold sections by id, first-wins, BEFORE any claiming happens. Otherwise
    //    a duplicate section id would still claim its repos even though only one
    //    `.section(id)` root ref is ever emitted, silently losing those repos.
    var seenSectionIDsForFold = Set<String>()
    let foldedSections: [SidebarSection] = sections.filter { section in
        guard !seenSectionIDsForFold.contains(section.id) else { return false }
        seenSectionIDsForFold.insert(section.id)
        return true
    }

    // 1. Clean section membership: keep only existing, not-yet-claimed repo ids
    //    (first section listing a repo wins), preserving each section's order.
    var claimed = Set<String>()
    let cleanSections: [SidebarSection] = foldedSections.map { section in
        var kept: [String] = []
        for id in section.repoIDs where existingRepoIDs.contains(id) && !claimed.contains(id) {
            kept.append(id); claimed.insert(id)
        }
        var copy = section
        copy.repoIDs = kept
        return copy
    }
    let sectionIDs = Set(cleanSections.map { $0.id })

    // 2. Rebuild rootOrder: keep valid, first-seen refs; a repo claimed by a
    //    section can't also be loose.
    var seenSections = Set<String>()
    var seenLoose = Set<String>()
    var cleanRoot: [RootRef] = []
    for ref in rootOrder {
        switch ref {
        case .section(let id):
            if sectionIDs.contains(id), !seenSections.contains(id) {
                cleanRoot.append(ref); seenSections.insert(id)
            }
        case .repo(let id):
            if existingRepoIDs.contains(id), !claimed.contains(id), !seenLoose.contains(id) {
                cleanRoot.append(ref); seenLoose.insert(id)
            }
        }
    }

    // 3. Append any section not referenced at root (in sections array order).
    for section in cleanSections where !seenSections.contains(section.id) {
        cleanRoot.append(.section(section.id))
    }

    // 4. Append any repo neither claimed by a section nor already loose,
    //    in repositories array order (deterministic; matches pre-sections order).
    for repo in repositories where !claimed.contains(repo.id) && !seenLoose.contains(repo.id) {
        cleanRoot.append(.repo(repo.id))
        seenLoose.insert(repo.id)
    }

    return ReconciledLayout(sections: cleanSections, rootOrder: cleanRoot)
}

/// A section together with the display sections of the repos it contains.
public struct SectionDisplay: Equatable {
    public let section: SidebarSection
    public let repos: [RepositorySection]
    public init(section: SidebarSection, repos: [RepositorySection]) {
        self.section = section; self.repos = repos
    }
}

/// One top-level row group: a section (with its repos) or a loose repo.
public enum SidebarRootItem: Equatable {
    case section(SectionDisplay)
    case repo(RepositorySection)
}

/// Build the ordered three-tier sidebar tree (section → repo → worktree). Runs
/// reconciliation first so the result always satisfies the exactly-once invariant.
/// Each repo carries its synthesized main-checkout row first, then its real worktrees.
public func buildSidebarTree(repositories: [Repository],
                             worktrees: [Worktree],
                             sections: [SidebarSection],
                             rootOrder: [RootRef],
                             branchForRepo: [String: String]) -> [SidebarRootItem] {
    let layout = reconcileSidebarLayout(repositories: repositories,
                                        sections: sections, rootOrder: rootOrder)
    // First-wins: duplicate repo ids in the raw `repositories` array must not
    // trap dict construction (reconciliation dedups downstream, but this lookup
    // is built from the raw array and is consulted before that dedup helps).
    let repoByID = repositories.reduce(into: [String: Repository]()) { acc, r in
        if acc[r.id] == nil { acc[r.id] = r }
    }
    let sectionByID = Dictionary(uniqueKeysWithValues: layout.sections.map { ($0.id, $0) })

    func repoSection(_ repo: Repository) -> RepositorySection {
        let main = Worktree.mainCheckout(for: repo, branch: branchForRepo[repo.id] ?? "")
        let real = worktrees.filter { $0.repoID == repo.id }
        return RepositorySection(repository: repo, worktrees: [main] + real)
    }

    return layout.rootOrder.compactMap { ref in
        switch ref {
        case .repo(let id):
            return repoByID[id].map { .repo(repoSection($0)) }
        case .section(let id):
            guard let section = sectionByID[id] else { return nil }
            let repos = section.repoIDs.compactMap { repoByID[$0].map(repoSection) }
            return .section(SectionDisplay(section: section, repos: repos))
        }
    }
}
