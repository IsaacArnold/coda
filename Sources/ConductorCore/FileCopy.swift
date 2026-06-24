import Foundation

/// Copy each allowlisted relative path from `repoRoot` into `worktree`, preserving
/// the relative path and creating parent directories. Missing sources are skipped.
/// Returns the relative paths that were actually copied. Files and directories
/// (recursively) are both supported.
public func copyAllowlistedFiles(from repoRoot: String, to worktree: String, allowlist: [String]) throws -> [String] {
    let fm = FileManager.default
    var copied: [String] = []
    for rel in allowlist {
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
