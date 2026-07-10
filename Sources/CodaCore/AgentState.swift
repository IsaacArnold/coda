import Foundation

/// What a worktree's agent is doing, surfaced as a sidebar/notch badge.
/// (Maps to the DECISIONS agent-state→badge table.)
public enum AgentState: String, Equatable {
    case idle      // ⚪️ no Claude running — a plain shell
    case working   // 🟡 Claude is actively working
    case needsYou  // 🔴 Claude stopped and is awaiting your decision (a question / prompt)
    case done      // 🟢 Claude stopped after finishing cleanly — nothing pending
}

/// Heuristic classification of a Claude run from a snapshot of recent terminal output
/// (MVP; the authoritative HTTP-hook path is Phase 2 — same badge states).
///
/// - working: the gerund spinner's elapsed timer ("(4s · …)") or the interrupt hint.
/// - needsYou / done: when Claude has stopped, we look at its last on-screen message —
///   a question or a numbered/selection prompt means it's awaiting you (needsYou); a plain
///   finish is done. (Distinguishing these from scraped text is best-effort.)
/// - idle: no Claude footer at all — a plain shell.
public func agentState(fromOutput output: String) -> AgentState {
    let lower = output.lowercased()
    let collapsed = lower.filter { !$0.isWhitespace }

    // 🟡 Working — spinner elapsed timer (separator-independent; rejects prose "(2 seconds)").
    if lower.range(of: #"\(\d+s\b"#, options: .regularExpression) != nil
        || collapsed.contains("esctointerrupt") {
        return .working
    }

    // No Claude footer → a plain shell.
    let claudeOpen = collapsed.contains("ctx:")
        || collapsed.contains("foragents") || collapsed.contains("forshortcuts")
    guard claudeOpen else { return .idle }

    // 🔴 vs 🟢 — Claude stopped: is it awaiting your input?
    return awaitingUser(output) ? .needsYou : .done
}

/// True when Claude appears to be waiting on the user: a numbered/selection prompt, or its
/// last on-screen message line ends with a question mark.
private func awaitingUser(_ output: String) -> Bool {
    let collapsed = output.lowercased().filter { !$0.isWhitespace }
    if collapsed.contains("❯1.") || collapsed.contains("1.yes") {   // selection / permission prompt
        return true
    }
    return lastMessageLine(output)?.hasSuffix("?") ?? false
}

/// The last "real" message line on screen — skipping the input box, separators, the status
/// footer, and the spinner/completion line — so we can tell a closing question from a sign-off.
private func lastMessageLine(_ output: String) -> String? {
    let spinnerGlyphs: Set<Character> = ["✻", "✽", "✢", "✶", "✳", "·", "✺", "◐", "◓", "◑", "◒", "∗"]
    let boxScalars = CharacterSet(charactersIn: "─│╯╰╭╮┌┐└┘├┤┬┴┼━┃┏┓┗┛ ")

    for raw in output.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        let low = line.lowercased()

        // Status footer / chrome.
        if low.contains("ctx:") || low.contains("for agents") || low.contains("foragents")
            || low.contains("(1m context)") || low.contains("/effort") { continue }
        // A line of only box-drawing characters.
        if line.unicodeScalars.allSatisfy({ boxScalars.contains($0) }) { continue }
        // The (empty) input box: just the prompt arrow.
        if line.allSatisfy({ $0 == "❯" || $0 == " " }) { continue }
        // The spinner / completion status line ("✻ Cooked for 15s", "· Blanching… (3s …)").
        if let first = line.first, spinnerGlyphs.contains(first) { continue }
        if low.range(of: #"\(\d+s\b"#, options: .regularExpression) != nil { continue }
        if low.contains("tokens") || low.contains("esc to interrupt") { continue }

        return line
    }
    return nil
}

/// The worktree-level badge across its surfaces: the highest-priority state present.
/// Priority: needsYou > working > done > idle. An empty list rolls up to idle.
public func rollup(_ states: [AgentState]) -> AgentState {
    if states.contains(.needsYou) { return .needsYou }
    if states.contains(.working) { return .working }
    if states.contains(.done) { return .done }
    return .idle
}

/// How many worktrees are awaiting the user (rolled-up state `.needsYou`).
/// Drives the Dock badge count. Pure so it is unit-testable without AppKit.
public func needsYouCount(_ rollups: [String: AgentState]) -> Int {
    rollups.values.filter { $0 == .needsYou }.count
}
