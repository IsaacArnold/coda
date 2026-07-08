import XCTest
@testable import CodaCore

final class CompletionSpecTests: XCTestCase {
    // MARK: - Fixture locations

    /// `Tests/CodaCoreTests/Fixtures/<subdirectory>`, resolved inside the test bundle.
    private func fixturesURL(_ subdirectory: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: subdirectory, withExtension: nil, subdirectory: "Fixtures") else {
            XCTFail("missing fixture directory Fixtures/\(subdirectory) in test bundle")
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    private func decodeSpec(named name: String, in subdirectory: String) throws -> CompletionSpec {
        let url = try fixturesURL(subdirectory).appendingPathComponent("\(name).json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CompletionSpec.self, from: data)
    }

    // MARK: - Decoding git.json (subcommands, option aliases, template, generator)

    func testGitSpecDecodesTopLevelNameAndDescription() throws {
        let spec = try decodeSpec(named: "git", in: "specs")
        XCTAssertEqual(spec.name, ["git"])
        XCTAssertEqual(spec.description, "the stupid content tracker")
    }

    func testGitSpecDecodesTopLevelOptionWithAlias() throws {
        let spec = try decodeSpec(named: "git", in: "specs")
        let help = try XCTUnwrap(spec.options?.first)
        XCTAssertEqual(help.name, ["--help", "-h"])
        XCTAssertEqual(help.description, "display help for git")
    }

    func testGitSpecDecodesSubcommandsWithAliases() throws {
        let spec = try decodeSpec(named: "git", in: "specs")
        let subcommands = try XCTUnwrap(spec.subcommands)
        XCTAssertEqual(subcommands.count, 2)

        let checkout = try XCTUnwrap(subcommands.first { $0.name.first == "checkout" })
        XCTAssertEqual(checkout.name, ["checkout", "co"])
    }

    func testGitSpecDecodesSubcommandOptionAlias() throws {
        let spec = try decodeSpec(named: "git", in: "specs")
        let checkout = try XCTUnwrap(spec.subcommands?.first { $0.name.first == "checkout" })
        let force = try XCTUnwrap(checkout.options?.first)
        XCTAssertEqual(force.name, ["--force", "-f"])
    }

    func testGitSpecDecodesArgWithGitBranchesGenerator() throws {
        let spec = try decodeSpec(named: "git", in: "specs")
        let checkout = try XCTUnwrap(spec.subcommands?.first { $0.name.first == "checkout" })
        let branchArg = try XCTUnwrap(checkout.args?.first)
        XCTAssertEqual(branchArg.name, "branch")
        XCTAssertEqual(branchArg.generator, .gitBranches)
        XCTAssertNil(branchArg.template)
    }

    func testGitSpecDecodesArgWithFoldersTemplate() throws {
        let spec = try decodeSpec(named: "git", in: "specs")
        let clone = try XCTUnwrap(spec.subcommands?.first { $0.name.first == "clone" })
        let dirArg = try XCTUnwrap(clone.args?.first)
        XCTAssertEqual(dirArg.template, .folders)
        XCTAssertEqual(dirArg.isOptional, true)
        XCTAssertNil(dirArg.generator)
    }

    // MARK: - Decoding cd.json (single arg, folders template)

    func testCdSpecDecodes() throws {
        let spec = try decodeSpec(named: "cd", in: "specs")
        XCTAssertEqual(spec.name, ["cd"])
        let dirArg = try XCTUnwrap(spec.args?.first)
        XCTAssertEqual(dirArg.template, .folders)
        XCTAssertEqual(dirArg.isVariadic, false)
    }

    // MARK: - Loader: indexes by primary name

    func testLoaderIndexesSpecsByPrimaryName() throws {
        let directory = try fixturesURL("specs")
        let specs = try loadCompletionSpecs(from: directory)

        XCTAssertEqual(specs.count, 2)
        XCTAssertEqual(specs["git"]?.name, ["git"])
        XCTAssertEqual(specs["cd"]?.name, ["cd"])
    }

    func testLoaderDoesNotIndexBySecondaryName() throws {
        // "checkout"/"co" are subcommand aliases, not top-level specs — only "git" and "cd"
        // exist as top-level files, so neither alias should appear as a loader key.
        let directory = try fixturesURL("specs")
        let specs = try loadCompletionSpecs(from: directory)

        XCTAssertNil(specs["checkout"])
        XCTAssertNil(specs["co"])
    }

    // MARK: - Decoding a minimal spec (only `name`; all optionals absent)

    func testMinimalSpecDecodesWithAllOptionalsNil() throws {
        // The real-world Fig shape: most specs omit most fields. Absent keys must decode to nil,
        // not fail — Task 4 walks these and relies on that.
        let spec = try decodeSpec(named: "minimal", in: "specs-minimal")
        XCTAssertEqual(spec.name, ["minimal"])
        XCTAssertNil(spec.description)
        XCTAssertNil(spec.subcommands)
        XCTAssertNil(spec.options)
        XCTAssertNil(spec.args)
    }

    // MARK: - Loader: a spec with an empty `name` array has no primary key and is skipped

    func testLoaderSkipsSpecWithEmptyName() throws {
        let directory = try fixturesURL("specs-with-empty-name")
        let specs = try loadCompletionSpecs(from: directory)

        // The empty-name spec has no primary name to index by, so it must not appear at all;
        // its valid sibling must still load unaffected.
        XCTAssertEqual(specs.count, 1)
        XCTAssertEqual(specs["valid"]?.name, ["valid"])
        XCTAssertNil(specs[""])
    }

    // MARK: - Loader: missing directory is handled gracefully (no throw, empty result)

    func testLoaderReturnsEmptyForMissingDirectory() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/path/\(UUID().uuidString)")
        let specs = try loadCompletionSpecs(from: missing)
        XCTAssertTrue(specs.isEmpty)
    }

    // MARK: - Loader: a malformed JSON file is skipped, valid siblings still load

    func testLoaderSkipsMalformedFileButLoadsValidSiblings() throws {
        let directory = try fixturesURL("specs-with-malformed")
        let specs = try loadCompletionSpecs(from: directory)

        // "ls" is valid and must load despite "broken.json" being unparsable.
        XCTAssertEqual(specs["ls"]?.name, ["ls"])
        // The malformed file must not produce any entry, and must not abort the whole load.
        XCTAssertEqual(specs.count, 1)
    }
}
