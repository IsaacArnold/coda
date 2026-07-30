import Foundation

/// One entry from a `package.json` `scripts` object.
public struct PackageScript: Equatable {
    /// The script's key, e.g. `dev`.
    public let name: String
    /// The command it runs, e.g. `vite --host`. Shown as the candidate's description.
    public let command: String

    public init(name: String, command: String) {
        self.name = name
        self.command = command
    }
}

/// How many characters of a script's command are shown as the candidate description. The popup
/// tail-ellipsises anything past its 480pt `maxWidth` anyway; truncating here stops one
/// pathological script from dominating the popup's width calculation.
public let packageScriptDescriptionLimit = 60

/// Parses the `scripts` object out of `package.json`, sorted case-insensitively by name.
///
/// Every malformed shape degrades to `[]` rather than throwing: a project with an unparseable
/// `package.json` should simply get no script completions, never an error in the user's face.
/// Individual non-string values (invalid npm, but possible) are skipped while their valid
/// siblings are kept.
///
/// **Sorted, not in declaration order.** A JSON object has no order once decoded, and recovering
/// it would need a raw-byte rescan. Alphabetical is deterministic, which matters more here:
/// `rankCandidates` re-orders by match tier immediately afterward, so this sort exists only to
/// give a stable, predictable pre-rank order (same contract as `filesystemCandidates`).
public func parsePackageScripts(packageJSON: Data) -> [PackageScript] {
    guard
        let root = try? JSONSerialization.jsonObject(with: packageJSON),
        let object = root as? [String: Any],
        let scripts = object["scripts"] as? [String: Any]
    else { return [] }

    return scripts
        .compactMap { key, value -> PackageScript? in
            guard let command = value as? String else { return nil }
            return PackageScript(name: key, command: command)
        }
        .sorted { $0.name.lowercased() < $1.name.lowercased() }
}

/// Shapes parsed scripts into completion candidates.
///
/// `runPrefixed` renders `run dev` instead of `dev`, for the position *before* the `run`
/// subcommand has been typed (npm/pnpm/bun). yarn needs no `run`, so it uses the bare shape at
/// both positions.
///
/// `name` stays raw — it's what the query matches against and what's displayed. `insertion` is
/// sent to the PTY, so the script name is escaped; the literal `run ` prefix and the trailing
/// token separator must NOT be escaped (same convention as `gitNameCandidates`).
public func scriptCandidates(
    _ scripts: [PackageScript],
    runPrefixed: Bool,
    cap: Int = 100
) -> [Candidate] {
    scripts.prefix(cap).map { script in
        let prefix = runPrefixed ? "run " : ""
        return Candidate(
            name: prefix + script.name,
            description: truncatedScriptCommand(script.command),
            kind: .script,
            insertion: prefix + shellEscapeForInsertion(script.name) + " "
        )
    }
}

/// Collapses whitespace (scripts are often written across several lines) and truncates to
/// `packageScriptDescriptionLimit`, ellipsis included in that budget.
private func truncatedScriptCommand(_ command: String) -> String {
    let collapsed = command.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard collapsed.count > packageScriptDescriptionLimit else { return collapsed }
    return String(collapsed.prefix(packageScriptDescriptionLimit - 1)) + "…"
}

/// Walks up from `directory` looking for a readable `package.json`, returning the first one found.
///
/// Matches npm's own resolution, so completions work from a subdirectory of the project — the
/// common case, since you're usually somewhere inside `src/`. An existing-but-unreadable file is
/// skipped and the walk continues upward. Terminates at the filesystem root (where
/// `deletingLastPathComponent()` stops changing the path).
public func findNearestPackageJSON(startingAt directory: URL) -> URL? {
    var current = directory.standardizedFileURL
    while true {
        let candidate = current.appendingPathComponent("package.json")
        if FileManager.default.isReadableFile(atPath: candidate.path) { return candidate }
        let parent = current.deletingLastPathComponent().standardizedFileURL
        if parent == current { return nil }
        current = parent
    }
}

/// Resolves and caches a directory's nearest `package.json` scripts.
///
/// **Synchronous, unlike the git generators.** Those spawn a subprocess, so they need the whole
/// in-flight/TTL/async-refresh dance. This is one small file read, comfortably inside a
/// 40ms-debounced refresh — which also means candidates appear on the *first* keystroke instead
/// of after a second refresh.
///
/// **Threading:** not synchronised. Like `CompletionGenerators`, which owns the only instance,
/// this is main-thread-confined.
///
/// The cache is keyed by resolved file path and invalidated whenever the file's modification date
/// or size changes, so editing `package.json` is picked up on the next keystroke.
public final class PackageScriptStore {
    private struct Stamp: Equatable {
        let modified: Date?
        let size: Int?
    }
    private struct Entry {
        let scripts: [PackageScript]
        let stamp: Stamp
    }

    private var cache: [String: Entry] = [:]

    public init() {}

    /// The nearest `package.json`'s scripts, or `[]` when there is none (or it's unparseable).
    public func scripts(cwd: URL) -> [PackageScript] {
        guard let file = findNearestPackageJSON(startingAt: cwd) else { return [] }
        let key = file.path
        let stamp = currentStamp(of: file)

        if let cached = cache[key], cached.stamp == stamp { return cached.scripts }

        guard let data = try? Data(contentsOf: file) else { return [] }
        let scripts = parsePackageScripts(packageJSON: data)
        cache[key] = Entry(scripts: scripts, stamp: stamp)
        return scripts
    }

    /// The nearest `package.json`'s scripts as completion candidates.
    public func candidates(cwd: URL, runPrefixed: Bool) -> [Candidate] {
        scriptCandidates(scripts(cwd: cwd), runPrefixed: runPrefixed)
    }

    private func currentStamp(of file: URL) -> Stamp {
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return Stamp(modified: values?.contentModificationDate, size: values?.fileSize)
    }
}
