import Foundation

public struct DiffStats: Equatable {
    public let insertions: Int
    public let deletions: Int
    public init(insertions: Int, deletions: Int) {
        self.insertions = insertions; self.deletions = deletions
    }
    public var isEmpty: Bool { insertions == 0 && deletions == 0 }
}

/// Sum `git diff --numstat` output (rows of "<ins>\t<del>\t<path>"; binary rows are
/// "-\t-\t<path>" → 0) and add untracked additions (each untracked file's lines count as +).
public func diffStats(numstat: String, untrackedAdditions: Int) -> DiffStats {
    var ins = untrackedAdditions
    var del = 0
    for row in numstat.split(separator: "\n", omittingEmptySubsequences: true) {
        let cols = row.split(separator: "\t", omittingEmptySubsequences: false)
        guard cols.count >= 2 else { continue }
        ins += Int(cols[0]) ?? 0     // "-" (binary) → 0
        del += Int(cols[1]) ?? 0
    }
    return DiffStats(insertions: ins, deletions: del)
}
