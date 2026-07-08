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
