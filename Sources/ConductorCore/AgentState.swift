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
/// Priority: a pending prompt (needs-you) wins over a lingering spinner, then a
/// working indicator, then an idle-but-open Claude (done), else a plain shell (idle).
public func agentState(fromOutput output: String) -> AgentState {
    let text = output.lowercased()

    // 🔴 Permission / approval prompt — the user's turn.
    if text.contains("do you want to") || text.contains("❯ 1.") || text.contains("1. yes") {
        return .needsYou
    }
    // 🟡 Claude's "(esc to interrupt)" hint shows while it works.
    if text.contains("esc to interrupt") {
        return .working
    }
    // 🟢 Claude is open and waiting (its input box / shortcuts footer) but not working.
    if text.contains("? for shortcuts") || text.contains("│ >") {
        return .done
    }
    // ⚪️ No Claude markers — a plain shell.
    return .idle
}
