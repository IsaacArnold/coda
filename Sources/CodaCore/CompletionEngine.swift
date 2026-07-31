import Foundation

/// What a completion candidate *is*, so the GUI can pick an icon/style and callers can reason
/// about it. `.file`/`.directory` are produced later (by the GUI, from a resolved `DynamicSource`);
/// `resolveCompletion` itself only emits `.command`, `.subcommand`, and `.option`.
public enum CandidateKind: Equatable {
    case subcommand
    case option
    case argument
    case file
    case directory
    case command
    /// A script defined by the project (e.g. a `package.json` `scripts` entry). Ranked ahead of
    /// other kinds by `rankCandidates` — in a project directory the project's own scripts are
    /// what you're reaching for, not the package manager's built-in subcommands.
    case script
}

/// A single thing the user can accept. `name` is what the query matches against and what's shown;
/// `insertion` is the exact text sent on accept (see `resolveCompletion` for the trailing-space
/// convention on static candidates).
public struct Candidate: Equatable {
    public let name: String
    public let description: String?
    public let kind: CandidateKind
    public let insertion: String

    public init(name: String, description: String?, kind: CandidateKind, insertion: String) {
        self.name = name
        self.description = description
        self.kind = kind
        self.insertion = insertion
    }
}

/// A source of candidates that can't be known statically and must be resolved with I/O
/// (filesystem or git) between the two pure engine steps. `resolveCompletion` only *declares*
/// which sources apply; it performs no I/O.
public enum DynamicSource: Equatable {
    case filepaths
    case folders
    case generator(GeneratorID)
}

/// The pure result of classifying a cursor position: the static candidates already known from the
/// spec, the dynamic sources the GUI must resolve and merge in, the query to rank everything
/// against, and the line span to replace when a candidate is accepted.
public struct CompletionContext: Equatable {
    public let staticCandidates: [Candidate]
    public let dynamicSources: [DynamicSource]
    public let query: String
    public let replacementRange: Range<Int>

    public init(
        staticCandidates: [Candidate],
        dynamicSources: [DynamicSource],
        query: String,
        replacementRange: Range<Int>
    ) {
        self.staticCandidates = staticCandidates
        self.dynamicSources = dynamicSources
        self.query = query
        self.replacementRange = replacementRange
    }
}

/// Step 1 (pure): tokenize `line` up to `cursorOffset`, resolve the first token to a command spec,
/// walk its subcommand/option/argument tree to the cursor, and classify the cursor token into the
/// static candidates + dynamic sources + query + replacement range needed to complete it.
///
/// The GUI resolves `dynamicSources` (filesystem / git) between this call and `rankCandidates`,
/// merging their results into the candidate list — so this function performs no I/O.
///
/// ### Classification
/// - **Command position** (typing the first token): offer every spec's primary name as a
///   `.command` candidate. An empty command query (empty line, or only whitespace) yields an
///   empty context.
/// - **Unknown command** (first token resolves to no spec): its arguments get filesystem path
///   completion — `dynamicSources` is `[.filepaths]`.
/// - **Option token** (the cursor token starts with `-`): offer the current spec's options as
///   `.option` candidates.
/// - **Option argument** (the previous token was an option that takes an argument): emit that
///   argument's dynamic source.
/// - **Subcommand / positional** (a fresh or partial non-option token): offer the current spec's
///   subcommands (`.subcommand`) and options (`.option`) as static candidates, plus the dynamic
///   source of the positional argument at this position, if any.
///
/// ### `replacementRange`
/// When the cursor sits inside a token, the replacement is that token's `range` (already
/// quote-aware — see `tokenizeCommandLine`'s accept contract). When the cursor starts a fresh
/// token (after a separator, or on an empty line), the replacement is the empty range at the
/// cursor.
///
/// ### `insertion`
/// Static candidates (`.command`, `.subcommand`, `.option`) insert their primary name followed by
/// a single trailing space, since in every static case the user goes on to type another token
/// (a subcommand, an argument, or another option). File/directory insertions are decided later by
/// the GUI when it resolves the dynamic sources.
public func resolveCompletion(
    line: String,
    cursorOffset: Int,
    specs: [String: CompletionSpec]
) -> CompletionContext {
    let tokenized = tokenizeCommandLine(line, cursorOffset: cursorOffset)
    let cursor = max(0, min(cursorOffset, line.count))
    let query = tokenized.cursorPrefix

    let replacementRange: Range<Int>
    if let index = tokenized.cursorTokenIndex {
        replacementRange = tokenized.tokens[index].range
    } else {
        replacementRange = cursor..<cursor
    }

    // Tokens committed before the cursor token. When the cursor is inside a token (always the last
    // one the tokenizer appends), it's still being typed and isn't part of the resolved chain.
    let committed: [CommandToken] =
        tokenized.cursorTokenIndex == nil ? tokenized.tokens : Array(tokenized.tokens.dropLast())

    // --- Command position: the cursor token IS the first token ---
    if committed.isEmpty {
        guard !query.isEmpty else {
            return CompletionContext(
                staticCandidates: [],
                dynamicSources: [],
                query: query,
                replacementRange: replacementRange
            )
        }
        let commands = specs.values
            .compactMap { spec -> Candidate? in
                guard let name = spec.name.first else { return nil }
                return Candidate(
                    name: name,
                    description: spec.description,
                    kind: .command,
                    insertion: name + " "
                )
            }
            .sorted { $0.name < $1.name }
        return CompletionContext(
            staticCandidates: commands,
            dynamicSources: [],
            query: query,
            replacementRange: replacementRange
        )
    }

    // --- Resolve the command; unknown commands get filesystem path completion ---
    guard let commandSpec = resolveSpec(named: committed[0].text, in: Array(specs.values)) else {
        return CompletionContext(
            staticCandidates: [],
            dynamicSources: [.filepaths],
            query: query,
            replacementRange: replacementRange
        )
    }

    // --- Walk the committed tokens after the command, descending into subcommands and tracking
    //     how many positional args have been consumed at the current level and whether the last
    //     token was an option still awaiting its argument. ---
    var spec = commandSpec
    var positionalsConsumed = 0
    var pendingOptionArg: SpecArg?

    var index = 1
    while index < committed.count {
        let text = committed[index].text
        index += 1

        if pendingOptionArg != nil {
            // This token fills the previous option's argument slot.
            pendingOptionArg = nil
            continue
        }
        if text.hasPrefix("-") {
            if let option = findOption(named: text, in: spec), option.args?.first != nil {
                pendingOptionArg = option.args?.first
            }
            continue
        }
        if let sub = findSubcommand(named: text, in: spec) {
            spec = sub
            positionalsConsumed = 0
            continue
        }
        positionalsConsumed += 1
    }

    // --- Classify the cursor token against the resolved `spec`. ---

    // The cursor fills an option's argument.
    if let arg = pendingOptionArg {
        return CompletionContext(
            staticCandidates: [],
            dynamicSources: dynamicSources(for: arg),
            query: query,
            replacementRange: replacementRange
        )
    }

    // The cursor token is an option.
    if query.hasPrefix("-") {
        return CompletionContext(
            staticCandidates: optionCandidates(of: spec),
            dynamicSources: [],
            query: query,
            replacementRange: replacementRange
        )
    }

    // A fresh or partial positional: subcommands + options (static) plus the dynamic source of the
    // positional argument at this position.
    var staticCandidates = subcommandCandidates(of: spec)
    staticCandidates += optionCandidates(of: spec)

    let sources: [DynamicSource] = positionalArg(at: positionalsConsumed, in: spec)
        .map { dynamicSources(for: $0) } ?? []

    return CompletionContext(
        staticCandidates: staticCandidates,
        dynamicSources: sources,
        query: query,
        replacementRange: replacementRange
    )
}

/// Step 2 (pure): keep only candidates whose `name` contains `query` (case-insensitive), with
/// prefix matches ranked above substring matches. Within each tier the original order is
/// preserved among candidates of the same kind, except that `.script` candidates are partitioned
/// ahead of every other kind. An empty query keeps every candidate, with that same script-first
/// partition applied.
public func rankCandidates(_ all: [Candidate], query: String) -> [Candidate] {
    guard !query.isEmpty else { return scriptsFirst(all) }
    let needle = query.lowercased()

    var prefixMatches: [Candidate] = []
    var substringMatches: [Candidate] = []
    for candidate in all {
        let name = candidate.name.lowercased()
        if name.hasPrefix(needle) {
            prefixMatches.append(candidate)
        } else if name.contains(needle) {
            substringMatches.append(candidate)
        }
    }
    return scriptsFirst(prefixMatches) + scriptsFirst(substringMatches)
}

/// Stable partition putting `.script` candidates ahead of every other kind.
///
/// Applied *within* a match tier, never across one, so a script that merely contains the query
/// can't jump a prefix match of another kind. Because `.script` is produced only by the
/// package-script generators, this leaves every pre-existing ordering untouched.
private func scriptsFirst(_ candidates: [Candidate]) -> [Candidate] {
    candidates.filter { $0.kind == .script } + candidates.filter { $0.kind != .script }
}

// MARK: - Spec lookup helpers

/// Resolves a command name to a spec, honoring aliases (`spec.name` carries primary + aliases).
private func resolveSpec(named name: String, in specs: [CompletionSpec]) -> CompletionSpec? {
    specs.first { $0.name.contains(name) }
}

private func findSubcommand(named name: String, in spec: CompletionSpec) -> CompletionSpec? {
    spec.subcommands?.first { $0.name.contains(name) }
}

private func findOption(named name: String, in spec: CompletionSpec) -> SpecOption? {
    spec.options?.first { $0.name.contains(name) }
}

/// The positional argument at `index`, treating a trailing variadic arg as absorbing every
/// position beyond the declared list.
private func positionalArg(at index: Int, in spec: CompletionSpec) -> SpecArg? {
    guard let args = spec.args, !args.isEmpty else { return nil }
    if index < args.count { return args[index] }
    if let last = args.last, last.isVariadic == true { return last }
    return nil
}

/// The dynamic sources an arg contributes. An arg may carry BOTH a generator and a filesystem
/// template (e.g. `bun run <script-or-file>`), in which case both are offered — generator first,
/// so its candidates rank above the directory listing.
private func dynamicSources(for arg: SpecArg) -> [DynamicSource] {
    var out: [DynamicSource] = []
    if let generator = arg.generator { out.append(.generator(generator)) }
    switch arg.template {
    case .filepaths: out.append(.filepaths)
    case .folders: out.append(.folders)
    case nil: break
    }
    return out
}

private func subcommandCandidates(of spec: CompletionSpec) -> [Candidate] {
    (spec.subcommands ?? []).compactMap { sub in
        guard let name = sub.name.first else { return nil }
        return Candidate(
            name: name,
            description: sub.description,
            kind: .subcommand,
            insertion: name + " "
        )
    }
}

private func optionCandidates(of spec: CompletionSpec) -> [Candidate] {
    (spec.options ?? []).compactMap { option in
        guard let name = option.name.first else { return nil }
        return Candidate(
            name: name,
            description: option.description,
            kind: .option,
            insertion: name + " "
        )
    }
}
