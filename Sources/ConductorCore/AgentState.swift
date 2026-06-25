import Foundation

/// What a worktree's agent is doing, surfaced as a sidebar/notch badge.
/// (Maps to the DECISIONS agent-state→badge table.)
public enum AgentState: String, Equatable {
    case idle      // ⚪️ no Claude running — a plain shell
    case working   // 🟡 Claude is actively working
    case needsYou  // 🔴 Claude has stopped and it's your turn (finished/asking/permission)
    case done      // 🟢 finished cleanly — reserved for the authoritative (hook) path; the
                   //    heuristic can't distinguish it from needsYou, so it isn't emitted here
}

/// Heuristic classification of a Claude run from a snapshot of recent terminal
/// output (MVP; the authoritative HTTP-hook path is Phase 2 — same badge states).
///
/// Matching is whitespace-insensitive: the terminal snapshot collapses spaces
/// unpredictably (e.g. "← for agents" arrives as "←foragents"), so we strip all
/// whitespace and match against space-free needles drawn from real Claude output.
/// Priority: a pending prompt (needs-you) wins over a lingering spinner, then a
/// working indicator, then an idle-but-open Claude (done), else a plain shell (idle).
public func agentState(fromOutput output: String) -> AgentState {
    let lower = output.lowercased()
    let collapsed = lower.filter { !$0.isWhitespace }

    // 🟡 Working — the gerund spinner's elapsed timer, e.g. "(4s · …)" / "(12s)". Present
    // throughout active work in every Claude frame (newer versions drop "esc to interrupt").
    // Matched on the original text with a trailing word boundary so it's independent of the
    // separator glyph and rejects prose like "(2 seconds)"; the interrupt hint still counts.
    if lower.range(of: #"\(\d+s\b"#, options: .regularExpression) != nil
        || collapsed.contains("esctointerrupt") {
        return .working
    }
    // 🔴 Claude is open but not working → it's your turn (finished, asking a question, or a
    // permission prompt). Keyed off the always-present footer ("ctx:" context gauge);
    // "← for agents" alone flaps because Claude redraws it intermittently.
    if collapsed.contains("ctx:") || collapsed.contains("foragents") || collapsed.contains("forshortcuts") {
        return .needsYou
    }
    // ⚪️ No Claude markers — a plain shell.
    return .idle
}
