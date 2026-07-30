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
