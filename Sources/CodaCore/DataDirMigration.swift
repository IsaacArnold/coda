import Foundation

/// One-time migration of app settings from the legacy `~/.conductor` data directory
/// to `~/.coda` (the app was renamed from Conductor → Coda).
///
/// Settings-only by design. We copy the files that carry **no internal path
/// dependencies** — `preferences.json`, `keybindings.json`, and the `themes/`
/// directory. We deliberately do NOT touch `local.json` (registered repos +
/// worktrees) or `worktrees/`: those store absolute paths and are git-linked by
/// absolute path, so they can't survive a directory move without rewriting both
/// sides. Repos are simply re-registered in Coda.
///
/// Copy (not move) so the legacy directory remains intact as a backup until the
/// user removes it themselves.
public enum DataDirMigration {
    /// Items safe to migrate — no absolute-path dependencies inside them.
    static let migratableItems = ["preferences.json", "keybindings.json", "themes"]

    /// Copies migratable settings from `oldDir` to `newDir`, skipping any item that
    /// already exists at the destination (a real `~/.coda` always wins). No-op if
    /// `oldDir` doesn't exist. Returns the names of the items actually copied.
    @discardableResult
    public static func migrateSettings(from oldDir: URL,
                                       to newDir: URL,
                                       fileManager fm: FileManager = .default) -> [String] {
        guard fm.fileExists(atPath: oldDir.path) else { return [] }

        var copied: [String] = []
        for item in migratableItems {
            let src = oldDir.appendingPathComponent(item)
            let dst = newDir.appendingPathComponent(item)
            guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
            do {
                try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
                try fm.copyItem(at: src, to: dst)
                copied.append(item)
            } catch {
                // Best-effort: a failed item shouldn't block the rest or app launch.
            }
        }
        return copied
    }
}
