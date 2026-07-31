import Foundation

/// Env additions that route a Coda-spawned zsh through the bundled `ZDOTDIR` wrapper (a
/// forwarding set of `.zshenv`/`.zprofile`/`.zshrc`/`.zlogin` that chains the user's real
/// dotfiles and then installs OSC 133 prompt markers — see `Resources/shell-integration/zsh`).
///
/// Pure: no I/O, no filesystem checks. The caller resolves the real bundle directory URL (and
/// verifies it actually contains the wrapper before calling this) and the user's original
/// `ZDOTDIR` (or `$HOME` when unset).
///
/// zsh-only for v1 — any other shell yields an empty dict (silent-off), as does `enabled ==
/// false`. Never inject a partial/broken environment.
public func shellIntegrationEnv(enabled: Bool, shell: ResolvedShell,
                                bundleZdotdir: URL, userZdotdir: URL) -> [String: String] {
    guard enabled, shell.name == "zsh" else { return [:] }
    return [
        "ZDOTDIR": bundleZdotdir.path,
        "CODA_USER_ZDOTDIR": userZdotdir.path
    ]
}

/// Whether a surface's shell is actually talking to us over OSC 133.
public enum ShellIntegrationStatus: Equatable {
    /// Too early to say — still inside the grace window, or the shell hasn't printed anything yet.
    case pending
    /// At least one OSC 133 marker has arrived; the completion pipeline has what it needs.
    case active
    /// The shell has been printing for a while and has never sent a marker. Something is
    /// swallowing or bypassing the integration (see `ShellIntegrationWrapperTests`), and
    /// completions cannot work until it's resolved.
    case notDetected
}

/// The pure diagnosis behind that status.
///
/// **Why `sawAnyPromptMarker` and not the live `PromptPhase`.** A `D` (command-finished) marker
/// resets `PromptPhase` to `.unknown`, so a perfectly integrated shell sits at `.unknown` for as
/// long as a command runs. Only "has a marker *ever* arrived" distinguishes a working integration
/// from an absent one.
///
/// `sawOutput` guards the other direction: a shell that hasn't written a byte yet (slow spawn,
/// a surface whose pty hasn't started) has had no opportunity to send a marker, and must stay
/// `.pending` however long it takes — a warning there would be pure false positive.
public func shellIntegrationStatus(sawAnyPromptMarker: Bool, sawOutput: Bool,
                                   elapsed: TimeInterval,
                                   grace: TimeInterval = 5) -> ShellIntegrationStatus {
    if sawAnyPromptMarker { return .active }
    guard sawOutput, elapsed >= grace else { return .pending }
    return .notDetected
}
