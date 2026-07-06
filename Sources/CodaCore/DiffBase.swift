import Foundation

/// The resolved comparison for a worktree's diff. `sinceFork` diffs `mergeBase` against the
/// working tree (committed + uncommitted since the fork). `workingTreeOnly` diffs HEAD.
public enum DiffBase: Equatable {
    case sinceFork(mergeBase: String)
    case workingTreeOnly
}

private func trimmedNonEmpty(_ s: String?) -> String? {
    guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
    return t
}

/// The branch to attempt `merge-base` against: stored base first, else the repo's main-checkout
/// branch, else nil (→ working-tree-only). Pass nil for both on the main-checkout worktree.
public func diffBaseCandidate(storedBase: String?, mainCheckoutBranch: String?) -> String? {
    trimmedNonEmpty(storedBase) ?? trimmedNonEmpty(mainCheckoutBranch)
}

/// Map a computed merge-base (nil/blank = none found) to a diff mode.
public func resolveDiffBase(mergeBase: String?) -> DiffBase {
    if let mb = trimmedNonEmpty(mergeBase) { return .sinceFork(mergeBase: mb) }
    return .workingTreeOnly
}
