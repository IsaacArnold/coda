import Foundation

public let codaHookMarker = "coda-agent-hook"

private let codaHookEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse",
                              "PostToolUse", "Notification", "Stop", "SessionEnd"]

/// The hook command string. Just the signed forwarder's absolute path plus an identifying
/// comment — no arguments, no interpolation of any payload (Security §1, §5).
public func codaHookCommand(forwarderPath: String) -> String {
    "\(forwarderPath) # \(codaHookMarker)"
}

private func isCodaBlock(_ block: [String: Any]) -> Bool {
    guard let hooks = block["hooks"] as? [[String: Any]] else { return false }
    return hooks.contains { ($0["command"] as? String)?.contains(codaHookMarker) == true }
}

public func containsCodaHook(_ settings: [String: Any]) -> Bool {
    guard let hooks = settings["hooks"] as? [String: Any] else { return false }
    return hooks.values.contains { ($0 as? [[String: Any]])?.contains(where: isCodaBlock) == true }
}

public func addCodaHook(to settings: [String: Any], forwarderPath: String) -> [String: Any] {
    var out = removeCodaHook(from: settings)   // idempotent: strip any prior coda block first
    var hooks = (out["hooks"] as? [String: Any]) ?? [:]
    let codaBlock: [String: Any] = ["matcher": "",
        "hooks": [["type": "command", "command": codaHookCommand(forwarderPath: forwarderPath)]]]
    for event in codaHookEvents {
        var blocks = (hooks[event] as? [[String: Any]]) ?? []
        blocks.append(codaBlock)
        hooks[event] = blocks
    }
    out["hooks"] = hooks
    return out
}

public func removeCodaHook(from settings: [String: Any]) -> [String: Any] {
    var out = settings
    guard var hooks = out["hooks"] as? [String: Any] else { return out }
    for (event, value) in hooks {
        guard let blocks = value as? [[String: Any]] else { continue }
        let kept = blocks.filter { !isCodaBlock($0) }
        if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
    }
    if hooks.isEmpty { out.removeValue(forKey: "hooks") } else { out["hooks"] = hooks }
    return out
}
