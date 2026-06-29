import Foundation

/// True if `rel` is a safe relative path to copy into a worktree: not absolute,
/// no `..` components, not empty. Prevents allowlist entries from reading or
/// writing outside the repo/worktree.
public func isSafeRelativePath(_ rel: String) -> Bool {
    if rel.hasPrefix("/") { return false }
    let comps = rel.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    if comps.isEmpty { return false }
    return !comps.contains("..")
}

/// Copy each allowlisted relative path from `repoRoot` into `worktree`, preserving
/// the relative path and creating parent directories. Missing sources are skipped.
/// Returns the relative paths that were actually copied. Files and directories
/// (recursively) are both supported.
public func copyAllowlistedFiles(from repoRoot: String, to worktree: String, allowlist: [String]) throws -> [String] {
    let fm = FileManager.default
    var copied: [String] = []
    for rel in allowlist {
        guard isSafeRelativePath(rel) else { continue }
        let source = (repoRoot as NSString).appendingPathComponent(rel)
        guard fm.fileExists(atPath: source) else { continue }
        let dest = (worktree as NSString).appendingPathComponent(rel)
        let destParent = (dest as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: destParent, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
        try fm.copyItem(atPath: source, toPath: dest)
        copied.append(rel)
    }
    return copied
}
