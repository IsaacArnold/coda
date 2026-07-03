import Foundation

/// The user's shell preference. Portable (no absolute path) so it can live in `Preferences`.
/// `.automatic` means "use my login shell"; `.zsh`/`.bash` force a specific well-known shell.
public enum ShellChoice: String, Codable, CaseIterable {
    case automatic, zsh, bash

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic (login shell)"
        case .zsh:       return "zsh"
        case .bash:      return "bash"
        }
    }
}

/// A concrete shell to spawn: its executable path plus the derived login argv0 (a leading
/// dash tells the shell to behave as a login shell, matching Terminal.app) and basename.
public struct ResolvedShell: Equatable {
    public let executablePath: String
    public init(executablePath: String) { self.executablePath = executablePath }

    /// The shell's basename, e.g. "zsh", "bash", "fish".
    public var name: String { (executablePath as NSString).lastPathComponent }

    /// argv0 for a login shell: the basename prefixed with "-" (e.g. "-zsh"), which is the
    /// convention login shells use to decide to source login-profile files.
    public var loginArgv0: String { "-" + name }
}

/// Resolve a `ShellChoice` (plus the detected login shell) to a concrete `ResolvedShell`.
/// `.automatic` uses `loginShell` when it's an absolute path, else falls back to `/bin/zsh`.
/// Pure and FS-free for testability — the caller supplies `loginShell` (from `$SHELL` /
/// the password DB).
public func resolveShell(choice: ShellChoice, loginShell: String?) -> ResolvedShell {
    switch choice {
    case .zsh:  return ResolvedShell(executablePath: "/bin/zsh")
    case .bash: return ResolvedShell(executablePath: "/bin/bash")
    case .automatic:
        if let s = loginShell, s.hasPrefix("/") {
            return ResolvedShell(executablePath: s)
        }
        return ResolvedShell(executablePath: "/bin/zsh")
    }
}
