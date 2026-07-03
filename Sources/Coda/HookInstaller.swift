import Foundation
import CodaCore

/// Installs/removes the Coda agent-status hook in `~/.claude/settings.json`, gated by
/// explicit user consent (Security §6). Reads/writes JSON generically (not through
/// `Preferences`/`Config`) because this file is owned by Claude Code itself and may
/// contain arbitrary user/foreign-tool keys we must round-trip untouched.
enum HookInstaller {
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// The forwarder shipped inside the app bundle (Contents/MacOS/coda-hook).
    static var forwarderPath: String {
        (Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("coda-hook").path) ?? "coda-hook"
    }

    static func isInstalled() -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return containsCodaHook(obj)
    }

    static func install() throws {
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { obj = existing }
        let updated = addCodaHook(to: obj, forwarderPath: forwarderPath)
        try write(updated)
    }

    static func uninstall() throws {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        try write(removeCodaHook(from: obj))
    }

    private static func write(_ obj: [String: Any]) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)
    }
}
