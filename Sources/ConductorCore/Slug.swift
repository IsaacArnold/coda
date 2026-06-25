import Foundation

/// Turn a human title into a git-branch-safe slug: lowercase, words joined by
/// single hyphens, only [a-z0-9-]. Falls back to "worktree" if nothing survives.
public func slugify(_ s: String) -> String {
    let lowered = s.lowercased()
    var out = ""
    var lastWasDash = false
    for ch in lowered {
        if ch.isLetter || ch.isNumber {
            out.append(ch)
            lastWasDash = false
        } else if !lastWasDash {
            out.append("-")
            lastWasDash = true
        }
    }
    let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.isEmpty ? "worktree" : trimmed
}
