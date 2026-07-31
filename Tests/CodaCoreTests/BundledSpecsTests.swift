import XCTest
@testable import CodaCore

/// Guards the specs Coda actually ships. `loadCompletionSpecs` skips any file it cannot decode,
/// so a JSON typo or an unknown generator id silently disables that whole command — exactly the
/// kind of failure no other test would catch.
final class BundledSpecsTests: XCTestCase {
    /// `Sources/Coda/Resources/completion-specs`, relative to this file in the repo. The bundled
    /// specs are a resource of the GUI target, which has no test target of its own.
    private var specsDirectory: URL {
        URL(fileURLWithPath: #filePath)      // Tests/CodaCoreTests/<this file>
            .deletingLastPathComponent()      // Tests/CodaCoreTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("Sources/Coda/Resources/completion-specs")
    }

    private func loadedSpecs() throws -> [String: CompletionSpec] {
        try loadCompletionSpecs(from: specsDirectory)
    }

    func testEveryBundledSpecFileDecodes() throws {
        let files = try FileManager.default
            .contentsOfDirectory(at: specsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let specs = try loadedSpecs()
        XCTAssertEqual(specs.count, files.count,
                       "a bundled spec failed to decode and was silently skipped; loaded "
                       + "\(specs.keys.sorted()) from \(files.map(\.lastPathComponent).sorted())")
    }

    func testNpmOffersRunPrefixedScriptsAtTopLevel() throws {
        let specs = try loadedSpecs()
        let npm = try XCTUnwrap(specs["npm"])
        XCTAssertEqual(npm.args?.first?.generator, .packageScriptsWithRun)
    }

    func testNpmRunOffersBareScripts() throws {
        let specs = try loadedSpecs()
        let npm = try XCTUnwrap(specs["npm"])
        let run = try XCTUnwrap(npm.subcommands?.first { $0.name.contains("run") })
        XCTAssertEqual(run.args?.first?.generator, .packageScripts)
    }

    func testPnpmAndBunMirrorNpmsShape() throws {
        let specs = try loadedSpecs()
        for name in ["pnpm", "bun"] {
            let spec = try XCTUnwrap(specs[name], "missing spec for \(name)")
            XCTAssertEqual(spec.args?.first?.generator, .packageScriptsWithRun, "\(name) top level")
            let run = try XCTUnwrap(spec.subcommands?.first { $0.name.contains("run") },
                                    "\(name) has no run subcommand")
            XCTAssertEqual(run.args?.first?.generator, .packageScripts, "\(name) run")
        }
    }

    /// yarn runs scripts without `run`, so its top-level shape is the bare one.
    func testYarnOffersBareScriptsAtTopLevel() throws {
        let specs = try loadedSpecs()
        let yarn = try XCTUnwrap(specs["yarn"])
        XCTAssertEqual(yarn.args?.first?.generator, .packageScripts)
    }

    /// End-to-end through the engine with the real shipped spec: subcommands and scripts coexist.
    func testEngineOffersBothSubcommandsAndScriptsAtNpmSpace() throws {
        let specs = try loadedSpecs()
        let context = resolveCompletion(line: "npm ", cursorOffset: 4, specs: specs)
        XCTAssertTrue(context.staticCandidates.contains { $0.name == "install" },
                      "expected npm's own subcommands")
        XCTAssertEqual(context.dynamicSources, [.generator(.packageScriptsWithRun)])
    }

    /// Regression guard for the spec's "overlap is intentional" rule: `npm test` is only an alias
    /// for `npm run test` when a test script exists, so both must be offered.
    func testNpmKeepsItsBuiltInTestSubcommand() throws {
        let specs = try loadedSpecs()
        let npm = try XCTUnwrap(specs["npm"])
        XCTAssertTrue(npm.subcommands?.contains { $0.name.contains("test") } == true)
    }
}
