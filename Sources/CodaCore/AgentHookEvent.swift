import Foundation

/// Claude Code lifecycle hook events Coda cares about. Closed enum: an unrecognised
/// hook_event_name is dropped (Security §4).
public enum HookEventName: String {
    case sessionStart     = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse       = "PreToolUse"
    case postToolUse      = "PostToolUse"
    case notification     = "Notification"
    case stop             = "Stop"
    case sessionEnd       = "SessionEnd"
}

/// `message` is present on Notification events (the needs-you body). `transcriptPath` is
/// forwarded so Coda can read the last assistant turn for the done body. There is no
/// assistant-message field on the wire — the payload doesn't have one (verified).
public struct AgentHookEvent: Equatable {
    public let worktreeID: String
    public let surfaceID: String
    public let event: HookEventName
    public let message: String?
    public let transcriptPath: String?
    public init(worktreeID: String, surfaceID: String, event: HookEventName,
                message: String?, transcriptPath: String?) {
        self.worktreeID = worktreeID; self.surfaceID = surfaceID; self.event = event
        self.message = message; self.transcriptPath = transcriptPath
    }
}

/// One physical line: "<worktreeID> <surfaceID> <json>". JSON escapes any spaces/newlines,
/// so the line is always single-physical-line and space-splittable into 3.
public func encodeHookMessage(worktreeID: String, surfaceID: String, event: HookEventName,
                              message: String?, transcriptPath: String?) -> String {
    var obj: [String: String] = ["hook_event_name": event.rawValue]
    if let message { obj["message"] = message }
    if let transcriptPath { obj["transcript_path"] = transcriptPath }
    let json = (try? JSONSerialization.data(withJSONObject: obj))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    return "\(worktreeID) \(surfaceID) \(json)"
}

public func decodeHookMessage(_ line: String, maxLength: Int = 64_000) -> AgentHookEvent? {
    guard line.utf8.count <= maxLength else { return nil }
    let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    let worktreeID = String(parts[0]), surfaceID = String(parts[1])
    guard !worktreeID.isEmpty, !surfaceID.isEmpty else { return nil }
    guard let data = String(parts[2]).data(using: .utf8),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let name = obj["hook_event_name"] as? String,
          let event = HookEventName(rawValue: name) else { return nil }
    return AgentHookEvent(worktreeID: worktreeID, surfaceID: surfaceID, event: event,
                          message: obj["message"] as? String,
                          transcriptPath: obj["transcript_path"] as? String)
}

/// Event → state. nil means "no state change from this event alone" (SessionStart just
/// marks a Claude run present; the socket server handles presence).
public func agentState(for event: HookEventName) -> AgentState? {
    switch event {
    case .userPromptSubmit, .preToolUse, .postToolUse: return .working
    case .notification: return .needsYou
    case .stop:         return .done
    case .sessionEnd:   return .idle
    case .sessionStart: return nil
    }
}

/// Last assistant record's text from transcript JSONL (its `content[]` `text` blocks
/// joined). Pure; Coda does the bounded file read and passes the tail here (Security §4).
public func lastAssistantText(fromTranscript jsonl: String) -> String? {
    // Scans backward and returns the most-recent assistant record that HAS text, so a
    // trailing text-less/tool-only turn (e.g. a bare tool_use) falls back to the prior
    // turn's text — intended as the body for the "done" notification.
    for raw in jsonl.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
        guard let data = raw.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              let msg = obj["message"] as? [String: Any],
              let content = msg["content"] as? [[String: Any]] else { continue }
        let text = content.compactMap { block -> String? in
            (block["type"] as? String) == "text" ? block["text"] as? String : nil
        }.joined(separator: "\n")
        if !text.isEmpty { return text }
    }
    return nil
}
