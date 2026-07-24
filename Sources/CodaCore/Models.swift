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
    /// Display-only rename override; nil/blank → use the folder-derived `name`.
    public var displayName: String?
    /// Identity color as a hex string (e.g. "#D97757"); nil → secondary gray.
    public var color: String?
    /// Sidebar expand/collapse state; persisted so a collapsed repo stays collapsed
    /// across reloads. Default false (expanded), matching prior always-expanded behavior.
    public var isCollapsed: Bool

    public init(id: String, path: String, name: String,
                setupScript: String = "", copyAllowlist: [String] = [],
                autoLaunchClaude: Bool = false,
                displayName: String? = nil, color: String? = nil,
                isCollapsed: Bool = false) {
        self.id = id; self.path = path; self.name = name
        self.setupScript = setupScript; self.copyAllowlist = copyAllowlist
        self.autoLaunchClaude = autoLaunchClaude
        self.displayName = displayName; self.color = color
        self.isCollapsed = isCollapsed
    }

    private enum CodingKeys: String, CodingKey { case id, path, name, setupScript, copyAllowlist, autoLaunchClaude, displayName, color, isCollapsed }

    // Custom decode so older configs without the setup / auto-launch fields still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decode(String.self, forKey: .name)
        setupScript = try c.decodeIfPresent(String.self, forKey: .setupScript) ?? ""
        copyAllowlist = try c.decodeIfPresent([String].self, forKey: .copyAllowlist) ?? []
        autoLaunchClaude = try c.decodeIfPresent(Bool.self, forKey: .autoLaunchClaude) ?? false
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        isCollapsed = try c.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
    }

    /// The name to show in the sidebar: a non-blank `displayName`, else the folder `name`.
    public var sidebarDisplayName: String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { return trimmed }
        return name
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
    /// True only for the synthesized repo main-checkout worktree (working dir == repo dir).
    /// In-memory only — absent from `CodingKeys`, so it never persists and always decodes false.
    public var isMain: Bool = false
    /// The branch this worktree was forked from (the New Worktree picker's choice). Used at
    /// review time as the diff base: `git merge-base <base> HEAD`. nil → fall back to the
    /// repo's main-checkout branch. Stored as a name (not a SHA) so it self-corrects as the
    /// base advances.
    public var base: String?

    public init(id: String, repoID: String, title: String, branch: String,
                worktreePath: String, color: String? = nil, base: String? = nil) {
        self.id = id; self.repoID = repoID; self.title = title
        self.branch = branch; self.worktreePath = worktreePath; self.color = color
        self.base = base
    }

    private enum CodingKeys: String, CodingKey { case id, repoID, title, branch, worktreePath, color, base }

    // Custom decode so worktrees written before identity colors still load (color → nil).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        repoID = try c.decode(String.self, forKey: .repoID)
        title = try c.decode(String.self, forKey: .title)
        branch = try c.decode(String.self, forKey: .branch)
        worktreePath = try c.decode(String.self, forKey: .worktreePath)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        base = try c.decodeIfPresent(String.self, forKey: .base)
    }
}

extension Worktree {
    /// The synthesized "main checkout" worktree for a repo: its working dir IS the repo dir.
    /// Never persisted (identified by `isMain`); id derived from the repo so surfaces persist
    /// within a session and the derived chrome color is stable.
    public static func mainCheckout(for repo: Repository, branch: String) -> Worktree {
        var wt = Worktree(id: "\(repo.id)#main", repoID: repo.id, title: "Workspace",
                          branch: branch, worktreePath: repo.path, color: nil)
        wt.isMain = true
        return wt
    }
}

/// A user-created sidebar group holding an ordered list of repo ids. Purely
/// organizational display metadata — never affects git or on-disk state.
public struct SidebarSection: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var isCollapsed: Bool
    public var repoIDs: [String]

    public init(id: String, name: String, isCollapsed: Bool = false, repoIDs: [String] = []) {
        self.id = id; self.name = name; self.isCollapsed = isCollapsed; self.repoIDs = repoIDs
    }
}

/// One entry in the interleaved top-level sidebar order: either a section or a
/// loose (ungrouped) repo. Serialized as a tagged string ("section:<id>" /
/// "repo:<id>") so the pretty-printed local.json stays human-readable.
public enum RootRef: Codable, Equatable {
    case section(String)
    case repo(String)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let id = raw.dropPrefixIfPresent("section:") { self = .section(id) }
        else if let id = raw.dropPrefixIfPresent("repo:") { self = .repo(id) }
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Unrecognized RootRef: \(raw)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .section(let id): try c.encode("section:\(id)")
        case .repo(let id):    try c.encode("repo:\(id)")
        }
    }
}

private extension String {
    /// Returns the remainder after `prefix` if `self` starts with it, else nil.
    func dropPrefixIfPresent(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
