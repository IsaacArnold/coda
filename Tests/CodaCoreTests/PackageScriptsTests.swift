import XCTest
@testable import CodaCore

final class PackageScriptsTests: XCTestCase {
    private func json(_ raw: String) -> Data { Data(raw.utf8) }

    private let sample = """
    {
      "name": "demo",
      "scripts": { "test": "vitest run", "dev": "vite --host", "build": "tsc && vite build" }
    }
    """

    // MARK: parsePackageScripts

    func testParsesScriptsSortedAlphabetically() {
        let scripts = parsePackageScripts(packageJSON: json(sample))
        XCTAssertEqual(scripts.map(\.name), ["build", "dev", "test"])
    }

    func testParsesEachScriptsCommand() {
        let scripts = parsePackageScripts(packageJSON: json(sample))
        XCTAssertEqual(scripts.first { $0.name == "dev" }?.command, "vite --host")
    }

    func testSortIsCaseInsensitive() {
        let scripts = parsePackageScripts(packageJSON: json("""
        {"scripts": {"Zip": "a", "apple": "b"}}
        """))
        XCTAssertEqual(scripts.map(\.name), ["apple", "Zip"])
    }

    func testMalformedJSONYieldsNoScripts() {
        XCTAssertTrue(parsePackageScripts(packageJSON: json("{ not json")).isEmpty)
    }

    func testMissingScriptsKeyYieldsNoScripts() {
        XCTAssertTrue(parsePackageScripts(packageJSON: json(#"{"name": "demo"}"#)).isEmpty)
    }

    func testEmptyScriptsObjectYieldsNoScripts() {
        XCTAssertTrue(parsePackageScripts(packageJSON: json(#"{"scripts": {}}"#)).isEmpty)
    }

    /// Invalid npm, but it must not crash or discard the valid siblings.
    func testNonStringScriptValueIsSkippedAndSiblingsKept() {
        let scripts = parsePackageScripts(packageJSON: json("""
        {"scripts": {"dev": "vite", "weird": {"nested": true}, "test": "vitest"}}
        """))
        XCTAssertEqual(scripts.map(\.name), ["dev", "test"])
    }

    func testScriptsAsAnArrayInsteadOfObjectYieldsNoScripts() {
        XCTAssertTrue(parsePackageScripts(packageJSON: json(#"{"scripts": ["dev"]}"#)).isEmpty)
    }

    /// Security regression: a script *name* containing a control character (e.g. `\n`) would be
    /// sent verbatim to the PTY as `insertion`, where a newline acts as Enter — one Tab would
    /// submit a second, attacker-chosen command. Such names must be dropped, while valid siblings
    /// survive.
    func testScriptNameContainingNewlineIsDroppedButSiblingsSurvive() {
        let scripts = parsePackageScripts(packageJSON: json("""
        {"scripts": {"  aaa\\nrm -rf ~/Documents\\n": "build", "dev": "vite"}}
        """))
        XCTAssertFalse(scripts.contains { $0.name.contains("\n") })
        XCTAssertEqual(scripts.map(\.name), ["dev"])
    }

    // MARK: scriptCandidates

    func testBareShapingUsesTheScriptNameAndTrailingSpace() {
        let candidates = scriptCandidates([PackageScript(name: "dev", command: "vite")],
                                          runPrefixed: false)
        XCTAssertEqual(candidates.map(\.name), ["dev"])
        XCTAssertEqual(candidates.map(\.insertion), ["dev "])
    }

    func testRunPrefixedShapingPrependsRunToNameAndInsertion() {
        let candidates = scriptCandidates([PackageScript(name: "dev", command: "vite")],
                                          runPrefixed: true)
        XCTAssertEqual(candidates.map(\.name), ["run dev"])
        XCTAssertEqual(candidates.map(\.insertion), ["run dev "])
    }

    func testCandidatesUseTheScriptKind() {
        let candidates = scriptCandidates([PackageScript(name: "dev", command: "vite")],
                                          runPrefixed: false)
        XCTAssertEqual(candidates.first?.kind, .script)
    }

    func testDescriptionIsTheScriptCommand() {
        let candidates = scriptCandidates([PackageScript(name: "dev", command: "vite --host")],
                                          runPrefixed: false)
        XCTAssertEqual(candidates.first?.description, "vite --host")
    }

    func testLongCommandIsTruncatedWithEllipsis() throws {
        let long = String(repeating: "x", count: 200)
        let candidates = scriptCandidates([PackageScript(name: "dev", command: long)],
                                          runPrefixed: false)
        let description = try XCTUnwrap(candidates.first?.description)
        XCTAssertEqual(description.count, packageScriptDescriptionLimit)
        XCTAssertTrue(description.hasSuffix("…"))
    }

    /// Scripts are frequently written across lines in package.json; the popup is one line per row.
    func testWhitespaceInCommandIsCollapsedToSingleSpaces() {
        let candidates = scriptCandidates(
            [PackageScript(name: "ci", command: "eslint .\n  &&   vitest run")],
            runPrefixed: false
        )
        XCTAssertEqual(candidates.first?.description, "eslint . && vitest run")
    }

    /// The insertion is sent to the PTY, so it must be escaped; the name stays raw for matching.
    func testScriptNameNeedingEscapingIsEscapedInInsertionOnly() {
        let candidates = scriptCandidates([PackageScript(name: "test:e2e(ci)", command: "x")],
                                          runPrefixed: false)
        XCTAssertEqual(candidates.first?.name, "test:e2e(ci)")
        XCTAssertEqual(candidates.first?.insertion, #"test:e2e\(ci\) "#)
    }

    func testCapLimitsTheNumberOfCandidates() {
        let many = (1...150).map { PackageScript(name: "s\($0)", command: "x") }
        XCTAssertEqual(scriptCandidates(many, runPrefixed: false, cap: 100).count, 100)
    }

    func testNoScriptsYieldsNoCandidates() {
        XCTAssertTrue(scriptCandidates([], runPrefixed: true).isEmpty)
    }
}
