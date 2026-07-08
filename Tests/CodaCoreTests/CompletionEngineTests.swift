import XCTest
@testable import CodaCore

final class CompletionEngineTests: XCTestCase {
    // MARK: - Fixtures

    /// A small in-code spec set: `git` (subcommands + options, one subcommand takes a
    /// git-branches generator arg) and `cd` (a single folders arg, no subcommands).
    private func makeSpecs() -> [String: CompletionSpec] {
        let checkout = CompletionSpec(
            name: ["checkout", "co"],
            description: "Switch branches",
            args: [SpecArg(name: "branch", generator: .gitBranches)]
        )
        let clone = CompletionSpec(name: ["clone"], description: "Clone a repository")
        let git = CompletionSpec(
            name: ["git"],
            description: "Distributed version control",
            subcommands: [checkout, clone],
            options: [
                SpecOption(name: ["--version"], description: "Print the version"),
                SpecOption(name: ["--help", "-h"], description: "Show help"),
            ]
        )
        let cd = CompletionSpec(
            name: ["cd"],
            description: "Change directory",
            args: [SpecArg(name: "directory", template: .folders)]
        )
        return ["git": git, "cd": cd]
    }

    private func candidate(_ name: String, kind: CandidateKind = .subcommand) -> Candidate {
        Candidate(name: name, description: nil, kind: kind, insertion: name)
    }

    // MARK: - resolveCompletion: command position

    func testCommandPositionOffersCommandNames() {
        let context = resolveCompletion(line: "gi", cursorOffset: 2, specs: makeSpecs())
        XCTAssertEqual(context.query, "gi")
        XCTAssertEqual(context.replacementRange, 0..<2)
        XCTAssertTrue(context.dynamicSources.isEmpty)
        XCTAssertTrue(context.staticCandidates.allSatisfy { $0.kind == .command })
        XCTAssertTrue(context.staticCandidates.contains { $0.name == "git" })
        XCTAssertTrue(context.staticCandidates.contains { $0.name == "cd" })
    }

    func testEmptyLineProducesEmptyContext() {
        let context = resolveCompletion(line: "", cursorOffset: 0, specs: makeSpecs())
        XCTAssertTrue(context.staticCandidates.isEmpty)
        XCTAssertTrue(context.dynamicSources.isEmpty)
        XCTAssertEqual(context.query, "")
        XCTAssertEqual(context.replacementRange, 0..<0)
    }

    // MARK: - resolveCompletion: subcommands

    func testGitSpaceOffersSubcommandsFreshToken() {
        let context = resolveCompletion(line: "git ", cursorOffset: 4, specs: makeSpecs())
        XCTAssertEqual(context.query, "")
        // Fresh token after a separator: replacement is the empty range at the cursor.
        XCTAssertEqual(context.replacementRange, 4..<4)
        XCTAssertTrue(context.dynamicSources.isEmpty)
        let subcommands = context.staticCandidates.filter { $0.kind == .subcommand }.map(\.name)
        XCTAssertTrue(subcommands.contains("checkout"))
        XCTAssertTrue(subcommands.contains("clone"))
        // Options are offered alongside subcommands.
        XCTAssertTrue(context.staticCandidates.contains { $0.kind == .option && $0.name == "--version" })
    }

    func testGitPartialSubcommandOffersQueryAndSubcommands() {
        let context = resolveCompletion(line: "git ch", cursorOffset: 6, specs: makeSpecs())
        XCTAssertEqual(context.query, "ch")
        // Mid-token completion: replacement is the cursor token's full span.
        XCTAssertEqual(context.replacementRange, 4..<6)
        XCTAssertTrue(context.staticCandidates.contains { $0.kind == .subcommand && $0.name == "checkout" })
    }

    // MARK: - resolveCompletion: options

    func testGitDashDashOffersOptions() {
        let context = resolveCompletion(line: "git --", cursorOffset: 6, specs: makeSpecs())
        XCTAssertEqual(context.query, "--")
        XCTAssertEqual(context.replacementRange, 4..<6)
        XCTAssertTrue(context.dynamicSources.isEmpty)
        XCTAssertFalse(context.staticCandidates.isEmpty)
        XCTAssertTrue(context.staticCandidates.allSatisfy { $0.kind == .option })
        XCTAssertTrue(context.staticCandidates.contains { $0.name == "--version" })
    }

    // MARK: - resolveCompletion: dynamic sources (generator + templates)

    func testGitCheckoutOffersGitBranchesGenerator() {
        let context = resolveCompletion(line: "git checkout ", cursorOffset: 13, specs: makeSpecs())
        XCTAssertEqual(context.query, "")
        XCTAssertEqual(context.replacementRange, 13..<13)
        XCTAssertTrue(context.dynamicSources.contains(.generator(.gitBranches)))
    }

    func testCdOffersFolders() {
        let context = resolveCompletion(line: "cd ", cursorOffset: 3, specs: makeSpecs())
        XCTAssertEqual(context.query, "")
        XCTAssertEqual(context.replacementRange, 3..<3)
        XCTAssertEqual(context.dynamicSources, [.folders])
    }

    func testCdPartialPathOffersFoldersWithQuery() {
        let context = resolveCompletion(line: "cd ./s", cursorOffset: 6, specs: makeSpecs())
        XCTAssertEqual(context.query, "./s")
        XCTAssertEqual(context.replacementRange, 3..<6)
        XCTAssertTrue(context.dynamicSources.contains(.folders))
    }

    func testUnknownCommandOffersFilepaths() {
        let context = resolveCompletion(line: "frobnicate ./s", cursorOffset: 14, specs: makeSpecs())
        XCTAssertEqual(context.query, "./s")
        XCTAssertEqual(context.replacementRange, 11..<14)
        XCTAssertTrue(context.staticCandidates.isEmpty)
        XCTAssertTrue(context.dynamicSources.contains(.filepaths))
    }

    // MARK: - rankCandidates

    func testPrefixBeatsSubstringAndStableWithinTier() {
        // "branch" is a substring match for "ch" (…branch); "checkout"/"chore" are prefix matches.
        let all = [candidate("branch"), candidate("checkout"), candidate("chore")]
        let ranked = rankCandidates(all, query: "ch")
        XCTAssertEqual(ranked.map(\.name), ["checkout", "chore", "branch"])
    }

    func testRankingIsCaseInsensitive() {
        let all = [candidate("Checkout"), candidate("Clone")]
        let ranked = rankCandidates(all, query: "che")
        XCTAssertEqual(ranked.map(\.name), ["Checkout"])
    }

    func testNonMatchesAreDropped() {
        let all = [candidate("checkout"), candidate("clone")]
        let ranked = rankCandidates(all, query: "zz")
        XCTAssertTrue(ranked.isEmpty)
    }

    func testStabilityWithinPrefixTier() {
        let all = [candidate("clone"), candidate("checkout"), candidate("cherry")]
        let ranked = rankCandidates(all, query: "c")
        XCTAssertEqual(ranked.map(\.name), ["clone", "checkout", "cherry"])
    }

    func testEmptyQueryReturnsAllInOrder() {
        let all = [candidate("clone"), candidate("checkout")]
        let ranked = rankCandidates(all, query: "")
        XCTAssertEqual(ranked.map(\.name), ["clone", "checkout"])
    }
}
