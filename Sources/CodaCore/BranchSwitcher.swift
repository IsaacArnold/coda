import Foundation

/// What happened when the branch picker switched branches.
public enum BranchSwitchOutcome: Equatable {
    case switched
    /// Uncommitted changes on `from` were stashed before switching; they come back via
    /// `BranchSwitcher.restoreAutoStash(for:in:)` when the user returns to that branch.
    case switchedAndStashed(from: String)
}

public enum BranchSwitchError: Error, Equatable, LocalizedError {
    case nothingToRestore(String)
    /// git refused to apply the stash (it would overwrite newer uncommitted edits). Nothing
    /// changed and the stash is still offered for restore.
    case restoreBlocked(String)
    /// Some of the stash came back, but `conflicted` files now hold git's conflict markers and
    /// `skipped` new files were left out because a file of that name already existed. The stash
    /// is kept as a backup but no longer offered (re-applying it would double up the changes).
    case partiallyRestored(String, conflicted: [String], skipped: [String])

    public var errorDescription: String? {
        switch self {
        case .nothingToRestore(let branch):
            return "No stashed changes for \(branch)."
        case .restoreBlocked(let branch):
            return "Your stashed changes on \(branch) would overwrite edits you've made since. "
                + "Nothing was changed. Commit or undo those edits, then restore again."
        case .partiallyRestored(let branch, let conflicted, let skipped):
            var parts = ["Restored your changes on \(branch), but not everything applied cleanly."]
            if !conflicted.isEmpty {
                parts.append(Self.count(conflicted.count, "file clashes", "files clash")
                    + " with newer work: \(conflicted.joined(separator: ", ")). "
                    + "Open \(conflicted.count == 1 ? "it" : "them") and pick which version to keep.")
            }
            if !skipped.isEmpty {
                parts.append(Self.count(skipped.count, "new file was", "new files were")
                    + " skipped because a file with the same name already exists: "
                    + "\(skipped.joined(separator: ", ")).")
            }
            parts.append("A backup of the stash has been kept.")
            return parts.joined(separator: "\n\n")
        }
    }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String {
        n == 1 ? "1 \(one)" : "\(n) \(many)"
    }
}

/// Stash-and-switch for the branch picker. Changes left on a branch are stashed under a
/// Coda marker so they can be found again *by the branch they came from* (git records that
/// as "On <branch>: …" in the stash message). Every call takes the directory of the
/// checkout to act on: a linked worktree's path, not necessarily the repo's main folder.
public struct BranchSwitcher {
    public static let marker = "coda-autostash"
    /// A partly-applied auto-stash, kept for safety but no longer offered for restore.
    public static let backupMarker = "coda-autostash-backup"

    private let git: GitWorktree
    public init(git: GitWorktree) { self.git = git }

    public func switchBranch(in dir: String, to target: String) throws -> BranchSwitchOutcome {
        guard try git.hasUncommittedChanges(repo: dir) else {
            try git.checkout(repo: dir, branch: target)
            return .switched
        }
        let from = try git.currentBranch(repo: dir)
        try git.stashSave(repo: dir, message: Self.marker)
        do {
            try git.checkout(repo: dir, branch: target)
        } catch {
            // Don't strand the changes: put them straight back on the branch we never left.
            try? git.stashPop(repo: dir, index: 0)
            throw error
        }
        return .switchedAndStashed(from: from)
    }

    /// Branches that have changes Coda stashed when switching away from them.
    public func branchesWithAutoStash(in dir: String) throws -> Set<String> {
        Set(try autoStashes(in: dir).compactMap(\.branch))
    }

    /// Bring back the newest auto-stash for `branch` and delete it.
    public func restoreAutoStash(for branch: String, in dir: String) throws {
        guard let stash = try autoStashes(in: dir).first(where: { $0.branch == branch }) else {
            throw BranchSwitchError.nothingToRestore(branch)
        }
        let before = try git.statusPorcelain(repo: dir)
        do {
            try git.stashPop(repo: dir, index: stash.id)
        } catch {
            // `git stash pop` keeps the entry whenever it can't apply cleanly. If the working
            // tree is untouched, git refused outright; otherwise part of the stash landed.
            guard try git.statusPorcelain(repo: dir) != before else {
                throw BranchSwitchError.restoreBlocked(branch)
            }
            try? git.stashRelabel(repo: dir, index: stash.id,
                                  message: "On \(branch): \(Self.backupMarker)")
            throw BranchSwitchError.partiallyRestored(
                branch,
                conflicted: (try? git.conflictedFiles(repo: dir)) ?? [],
                skipped: Self.skippedUntrackedFiles(in: error))
        }
    }

    /// git reports each untracked file it couldn't restore as "<path> already exists, no checkout".
    private static func skippedUntrackedFiles(in error: Error) -> [String] {
        guard case GitError.command(_, _, let stderr) = error else { return [] }
        let suffix = " already exists, no checkout"
        return stderr.split(separator: "\n").compactMap { line in
            line.hasSuffix(suffix) ? String(line.dropLast(suffix.count)) : nil
        }
    }

    private func autoStashes(in dir: String) throws -> [Stash] {
        try git.stashList(repo: dir).filter { $0.message.hasSuffix(": \(Self.marker)") }
    }
}
