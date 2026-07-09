import Foundation

/// The minimal directory-entry shape the pure filesystem-candidate builder needs: a name and
/// whether it is a directory. The GUI produces these from `FileManager` (which is the only impure
/// step), then hands them here so the *filtering and shaping* rules — hidden-file handling, prefix
/// match, folders-only, the `name`/`insertion` convention, the cap and pre-rank sort — are pure and
/// unit-testable without touching the filesystem.
public struct DirectoryEntry: Equatable {
    public let name: String
    public let isDirectory: Bool
    public init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
    }
}

/// Split a path-fragment completion `prefix` into the directory portion — everything up to and
/// including the last `/`, or `""` if there is no `/` — and the name prefix being matched
/// (everything after the last `/`).
///
/// Examples: `"./s"` → `("./", "s")`; `"src/ma"` → `("src/", "ma")`; `"foo"` → `("", "foo")`;
/// `"/usr/lo"` → `("/usr/", "lo")`; `"~/Doc"` → `("~/", "Doc")`.
public func splitPathPrefix(_ prefix: String) -> (dirPart: String, namePrefix: String) {
    guard let slash = prefix.lastIndex(of: "/") else { return ("", prefix) }
    let after = prefix.index(after: slash)
    return (String(prefix[..<after]), String(prefix[after...]))
}

/// Build file/directory candidates from already-enumerated directory `entries`, applying standard
/// shell path-completion rules. Pure: the caller (`CompletionGenerators` in the GUI) does the I/O
/// and passes the results here.
///
/// - **Prefix match:** keep entries whose name has `namePrefix` as a case-insensitive prefix.
/// - **Hidden-file rule:** dotfiles are included only when `namePrefix` itself starts with `.`
///   (standard shell behavior — you must type the leading dot to see hidden entries).
/// - **Folders only:** when `foldersOnly`, drop non-directories.
/// - **Candidate shape (load-bearing for ranking):** `name = dirPart + entryName` — i.e. the token
///   exactly as it reads once typed — because the controller merges these into one list and calls
///   `rankCandidates(all, query: ctx.query)` a single time, where `ctx.query` is the FULL path
///   fragment (e.g. `"./s"`). A bare basename (`"src"`) would fail to prefix-match `"./s"` and be
///   dropped. `insertion = dirPart + entryName (+ "/" for directories)`: directories get a trailing
///   slash so accepting one descends into it (and the next refresh re-completes its contents);
///   files get no trailing space in v1. `kind` is `.directory`/`.file`; `description` is `nil`.
/// - **Cap + stable pre-rank sort:** at most `cap` entries, sorted directories-first then
///   case-insensitive name. `rankCandidates` re-orders by match tier afterward, so this sort only
///   provides a sane, deterministic order before ranking (and bounds the merged list).
public func filesystemCandidates(
    from entries: [DirectoryEntry],
    dirPart: String,
    namePrefix: String,
    foldersOnly: Bool,
    cap: Int = 200
) -> [Candidate] {
    let includeHidden = namePrefix.hasPrefix(".")
    let needle = namePrefix.lowercased()

    let filtered = entries.filter { entry in
        if foldersOnly && !entry.isDirectory { return false }
        if !includeHidden && entry.name.hasPrefix(".") { return false }
        return entry.name.lowercased().hasPrefix(needle)
    }
    // Swift's `sorted` is guaranteed stable, so equal keys keep enumeration order.
    let sorted = filtered.sorted { a, b in
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.lowercased() < b.name.lowercased()
    }
    return sorted.prefix(cap).map { entry in
        Candidate(
            name: dirPart + entry.name,
            description: nil,
            kind: entry.isDirectory ? .directory : .file,
            insertion: dirPart + entry.name + (entry.isDirectory ? "/" : "")
        )
    }
}

/// Parse the stdout of a git command that prints one name per line (`git branch
/// --format=%(refname:short)` or `git remote`) into `.argument` candidates. Each non-empty,
/// whitespace-trimmed line becomes a candidate whose `insertion` is the name plus a single trailing
/// space (the user goes on to type or run). Mirrors `GitWorktree.localBranches`' parsing.
public func gitNameCandidates(from stdout: String) -> [Candidate] {
    stdout
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .map { Candidate(name: $0, description: nil, kind: .argument, insertion: $0 + " ") }
}
