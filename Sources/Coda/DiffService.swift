import Foundation
import CodaCore

struct DiffResult {
    let files: [DiffFile]
    let stats: DiffStats
    let base: DiffBase
}

enum DiffService {
    /// Resolve the ref to diff against for this worktree. `mainBranch` should be nil for the
    /// main-checkout worktree (no fork → working-tree-only).
    private static func resolvedRef(worktree: Worktree, mainBranch: String?,
                                    git: GitWorktree) -> (DiffBase, String) {
        let candidate = diffBaseCandidate(storedBase: worktree.base, mainCheckoutBranch: mainBranch)
        let mergeBase = candidate.flatMap { try? git.mergeBase(dir: worktree.worktreePath, $0, "HEAD") } ?? nil
        let base = resolveDiffBase(mergeBase: mergeBase)
        switch base {
        case .sinceFork(let mb): return (base, mb)
        case .workingTreeOnly:   return (base, "HEAD")
        }
    }

    /// Full model for the pane: tracked patch (parsed) + untracked files as all-add patches.
    static func compute(worktree: Worktree, mainBranch: String?, git: GitWorktree) -> DiffResult {
        let (base, ref) = resolvedRef(worktree: worktree, mainBranch: mainBranch, git: git)
        let dir = worktree.worktreePath
        var files: [DiffFile] = []
        if let patch = try? git.diffPatch(dir: dir, against: ref) {
            files += parseUnifiedDiff(patch)
        }
        for path in (try? git.untrackedFiles(dir: dir)) ?? [] {
            if let patch = try? git.untrackedPatch(dir: dir, path: path) {
                files += parseUnifiedDiff(patch)
            }
        }
        let ins = files.reduce(0) { $0 + $1.insertions }
        let del = files.reduce(0) { $0 + $1.deletions }
        return DiffResult(files: files, stats: DiffStats(insertions: ins, deletions: del), base: base)
    }

    /// Cheap stats-only path for the +/- figure: numstat (tracked) + untracked line counts.
    static func stats(worktree: Worktree, mainBranch: String?, git: GitWorktree) -> DiffStats {
        let (_, ref) = resolvedRef(worktree: worktree, mainBranch: mainBranch, git: git)
        let dir = worktree.worktreePath
        let numstat = (try? git.numstat(dir: dir, against: ref)) ?? ""
        var untrackedAdds = 0
        for path in (try? git.untrackedFiles(dir: dir)) ?? [] {
            if let contents = try? String(contentsOfFile: (dir as NSString).appendingPathComponent(path), encoding: .utf8) {
                untrackedAdds += contents.isEmpty ? 0 : contents.split(separator: "\n", omittingEmptySubsequences: false).count
            }
        }
        return CodaCore.diffStats(numstat: numstat, untrackedAdditions: untrackedAdds)
    }
}
