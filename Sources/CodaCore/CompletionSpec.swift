import Foundation

/// A Fig-subset terminal completion spec for one command (or nested subcommand).
///
/// Field names deliberately mirror Fig's own spec format (see ADR 0002:
/// `docs/adr/0002-native-completion-engine.md`), so the static parts of the community
/// `withfig/autocomplete` spec repo can later be vendored in as data rather than rewritten. This
/// is a *subset*: Fig's format also carries JS `generators`, `postProcess` hooks, and other
/// script-driven fields that a native Swift engine can't execute; those are intentionally
/// omitted here. Dynamic values are instead produced by `GeneratorID`, a closed set of
/// Coda-native generators implemented in Swift (Task 4).
///
/// `name` is an array, not a single string, because a command (and, on `SpecOption`, a flag)
/// can have aliases — e.g. git's `checkout`/`co`, or `--help`/`-h`. Wherever a spec is indexed
/// by name (see `loadCompletionSpecs`), the **primary name** is `name[0]`; the remaining
/// elements are alternate spellings that resolve to the same spec but are not, themselves,
/// index keys.
public struct CompletionSpec: Codable, Equatable {
    /// This command's name and aliases, primary first (e.g. `["checkout", "co"]`).
    public let name: [String]
    public let description: String?
    /// Nested subcommands (e.g. git's `checkout`, `clone`, ...). `nil`/empty when this command
    /// takes no subcommands.
    public let subcommands: [CompletionSpec]?
    /// Flags this command accepts (e.g. `--force`/`-f`).
    public let options: [SpecOption]?
    /// Positional arguments this command accepts.
    public let args: [SpecArg]?

    public init(
        name: [String],
        description: String? = nil,
        subcommands: [CompletionSpec]? = nil,
        options: [SpecOption]? = nil,
        args: [SpecArg]? = nil
    ) {
        self.name = name
        self.description = description
        self.subcommands = subcommands
        self.options = options
        self.args = args
    }
}

/// A single flag/option a `CompletionSpec` (or nested subcommand) accepts, e.g. `--force`/`-f`.
public struct SpecOption: Codable, Equatable {
    /// This option's name and aliases, primary first (e.g. `["--force", "-f"]`).
    public let name: [String]
    public let description: String?
    /// Arguments this option itself takes (e.g. `--branch <name>`). `nil` for a bare flag.
    public let args: [SpecArg]?

    public init(name: [String], description: String? = nil, args: [SpecArg]? = nil) {
        self.name = name
        self.description = description
        self.args = args
    }
}

/// A positional argument to a command or option.
public struct SpecArg: Codable, Equatable {
    /// Human-readable placeholder (e.g. `"branch"`, `"directory"`); purely cosmetic.
    public let name: String?
    /// A built-in filesystem-shaped completion source, when this arg takes a path.
    public let template: ArgTemplate?
    /// A Coda-native dynamic value producer, when this arg's candidates can't be known
    /// statically (e.g. the repo's current branches).
    public let generator: GeneratorID?
    /// Whether the argument may be omitted. `nil` is treated as `false` (required) by convention
    /// — Fig specs generally omit this key rather than writing `false` explicitly.
    public let isOptional: Bool?
    /// Whether the argument may be repeated (e.g. `ls <path>...`). `nil` is treated as `false`.
    public let isVariadic: Bool?

    public init(
        name: String? = nil,
        template: ArgTemplate? = nil,
        generator: GeneratorID? = nil,
        isOptional: Bool? = nil,
        isVariadic: Bool? = nil
    ) {
        self.name = name
        self.template = template
        self.generator = generator
        self.isOptional = isOptional
        self.isVariadic = isVariadic
    }
}

/// A built-in, filesystem-shaped completion source for a `SpecArg`. Raw values match Fig's own
/// spec vocabulary (`"filepaths"`, `"folders"`) so vendored Fig specs decode unchanged.
public enum ArgTemplate: String, Codable, Equatable {
    case filepaths
    case folders
}

/// A Coda-native dynamic value producer for a `SpecArg`, implemented in Swift (Task 4) rather
/// than in Fig's JS `generators` (which this native engine can't execute — see ADR 0002).
/// Extend this set as new dynamic sources are added; unknown generator ids fail to decode the
/// containing file (see `loadCompletionSpecs`'s malformed-file handling).
public enum GeneratorID: String, Codable, Equatable {
    case gitBranches
    case gitRemotes
}

/// Loads every `*.json` completion spec in `directory`, indexing each by its **primary** name
/// (`spec.name[0]`).
///
/// This function is declared `throws` to match the task interface and leave room for a future
/// hard failure (e.g. permission to enumerate the directory denied for reasons other than
/// "doesn't exist"), but today it never actually throws: both a missing directory and an
/// individual malformed/undecodable/unreadable JSON file are handled gracefully rather than
/// aborting the whole load, since a single bad or absent spec file should never take down
/// completions for every other command:
///
/// - **Missing directory**: returns `[:]`. There's nothing "wrong" about a Coda install with no
///   bundled specs directory yet (or a directory that hasn't been created); completions should
///   just degrade to none, not crash the app.
/// - **Malformed/unreadable file**: that one file is skipped — its spec is absent from the
///   result — and every other file in the directory still loads normally. This includes: a file
///   that isn't valid JSON, JSON that doesn't match `CompletionSpec`'s shape (e.g. an unknown
///   `generator` id, a missing required `name`), and a file that can't be read at all.
/// - **A spec with an empty `name` array**: has no primary name to index by, so — like a
///   malformed file — it's skipped rather than crashing or silently overwriting an unrelated
///   entry.
///
/// Non-`.json` files in `directory` are ignored. If two files resolve to the same primary name,
/// the later one (in `FileManager`'s enumeration order, which is not guaranteed) wins; specs are
/// expected to be named after their primary command (e.g. `git.json`), making collisions rare in
/// practice.
public func loadCompletionSpecs(from directory: URL) throws -> [String: CompletionSpec] {
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ) else {
        return [:]
    }

    let decoder = JSONDecoder()
    var specs: [String: CompletionSpec] = [:]

    for url in entries where url.pathExtension.lowercased() == "json" {
        guard let data = try? Data(contentsOf: url) else { continue }
        guard let spec = try? decoder.decode(CompletionSpec.self, from: data) else { continue }
        guard let primaryName = spec.name.first else { continue }
        specs[primaryName] = spec
    }

    return specs
}
