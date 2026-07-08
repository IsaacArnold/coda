import Foundation

/// The pure visibility gate: decides whether a completion popup should be shown, given a snapshot
/// of the surface's state and the resolved/ranked completion result.
///
/// This is the "brain in CodaCore, tested headlessly" half of the completion controller — the
/// per-surface `CompletionController` is a thin caller that gathers these inputs (from the live
/// terminal buffer, focus state, and engine output) and does nothing more than obey the boolean
/// this returns. Keeping the policy here means every show/hide rule is covered by fast,
/// AppKit-free unit tests rather than only exercisable through the GUI.
///
/// The popup shows iff **all** of these hold:
/// - `phase == .atPrompt` — the shell is accepting input (not mid-command, not unknown).
/// - `isFocused` — this surface holds keyboard focus; a background pane never pops up.
/// - `isScrolledToBottom` — the caller's cursor/anchor buffer math only holds at the live bottom.
/// - `!isSuppressed` — the user dismissed the popup with Esc and hasn't edited since.
/// - `rankedCount > 0` — there's at least one candidate to show.
/// - a *query condition*: either the user has typed a non-empty query (`!query.isEmpty`), **or**
///   the line ends on an unquoted separator *after* at least one committed token
///   (`endsWithSeparator && hasCommandToken`). The `hasCommandToken` clause is what stops a bare
///   prompt with a lone trailing space from spuriously offering every command — `git ` offers
///   subcommands, but ` ` offers nothing.
public func shouldShowCompletions(
    phase: PromptPhase,
    isFocused: Bool,
    isScrolledToBottom: Bool,
    isSuppressed: Bool,
    query: String,
    endsWithSeparator: Bool,
    hasCommandToken: Bool,
    rankedCount: Int
) -> Bool {
    guard phase == .atPrompt else { return false }
    guard isFocused else { return false }
    guard isScrolledToBottom else { return false }
    guard !isSuppressed else { return false }
    guard rankedCount > 0 else { return false }
    return !query.isEmpty || (endsWithSeparator && hasCommandToken)
}
