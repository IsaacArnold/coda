import Foundation

/// What a worktree's agent is doing, surfaced as a sidebar/notch badge.
/// (Maps to the DECISIONS agent-state→badge table.)
public enum AgentState: String, Equatable {
    case idle      // ⚪️ no Claude running — a plain shell
    case working   // 🟡 Claude is actively working
    case needsYou  // 🔴 Claude is waiting on the user (permission/idle prompt)
    case done      // 🟢 Claude finished and is waiting for the next prompt
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
    let collapsed = output.lowercased().filter { !$0.isWhitespace }

    // 🔴 Permission/approval prompt — the user's turn. Keyed off the numbered approve
    // option ("1. Yes") that only the selection UI prints, NOT prose like "do you want…".
    if collapsed.contains("1.yes") {
        return .needsYou
    }
    // 🟡 Working — Claude's "(esc to interrupt)" hint (match "interrupt"; spacing varies).
    if collapsed.contains("interrupt") {
        return .working
    }
    // 🟢 Claude is open and waiting. Keyed off the always-present footer ("ctx:" context
    // gauge); "← for agents" alone flaps because Claude redraws it intermittently.
    if collapsed.contains("ctx:") || collapsed.contains("foragents") || collapsed.contains("forshortcuts") {
        return .done
    }
    // ⚪️ No Claude markers — a plain shell.
    return .idle
}
