import XCTest
@testable import CodaCore

final class PackageScriptStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("coda-pkg-scripts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeDirectory(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: findNearestPackageJSON

    func testFindsPackageJSONInTheStartingDirectory() throws {
        try write(#"{"scripts":{"dev":"vite"}}"#, to: root.appendingPathComponent("package.json"))
        XCTAssertEqual(findNearestPackageJSON(startingAt: root)?.lastPathComponent, "package.json")
    }

    /// The common case: you're deep inside the project, not at its root.
    func testWalksUpFromANestedSubdirectory() throws {
        try write(#"{"scripts":{"dev":"vite"}}"#, to: root.appendingPathComponent("package.json"))
        let nested = try makeDirectory("src/components/deep")
        let found = try XCTUnwrap(findNearestPackageJSON(startingAt: nested))
        XCTAssertEqual(found.deletingLastPathComponent().standardizedFileURL,
                       root.standardizedFileURL)
    }

    func testPrefersTheNearestPackageJSONNotTheHighest() throws {
        try write(#"{"scripts":{"outer":"x"}}"#, to: root.appendingPathComponent("package.json"))
        let inner = try makeDirectory("packages/app")
        try write(#"{"scripts":{"inner":"x"}}"#, to: inner.appendingPathComponent("package.json"))
        let found = try XCTUnwrap(findNearestPackageJSON(startingAt: inner))
        XCTAssertEqual(found.deletingLastPathComponent().standardizedFileURL,
                       inner.standardizedFileURL)
    }

    func testReturnsNilWhenNoPackageJSONExistsAnywhereAbove() throws {
        let nested = try makeDirectory("a/b")
        // The temp dir has no package.json above it, so the walk reaches / and gives up.
        XCTAssertNil(findNearestPackageJSON(startingAt: nested))
    }

    // MARK: PackageScriptStore

    func testStoreReturnsScriptsFromTheNearestPackageJSON() throws {
        try write(#"{"scripts":{"dev":"vite","build":"tsc"}}"#,
                  to: root.appendingPathComponent("package.json"))
        let store = PackageScriptStore()
        XCTAssertEqual(store.scripts(cwd: root).map(\.name), ["build", "dev"])
    }

    func testStoreReturnsNothingWithoutAPackageJSON() throws {
        let store = PackageScriptStore()
        XCTAssertTrue(store.scripts(cwd: try makeDirectory("empty")).isEmpty)
    }

    func testStoreShapesCandidatesRunPrefixed() throws {
        try write(#"{"scripts":{"dev":"vite"}}"#, to: root.appendingPathComponent("package.json"))
        let store = PackageScriptStore()
        let candidates = store.candidates(cwd: root, runPrefixed: true)
        XCTAssertEqual(candidates.map(\.name), ["run dev"])
    }

    /// Editing package.json must be reflected on the next keystroke — a stale cache here would be
    /// worse than no cache, since the popup would offer scripts that no longer exist.
    func testCacheIsInvalidatedWhenPackageJSONChangesSize() throws {
        let file = root.appendingPathComponent("package.json")
        try write(#"{"scripts":{"dev":"vite"}}"#, to: file)
        let store = PackageScriptStore()
        XCTAssertEqual(store.scripts(cwd: root).map(\.name), ["dev"])

        try write(#"{"scripts":{"dev":"vite","test":"vitest"}}"#, to: file)
        XCTAssertEqual(store.scripts(cwd: root).map(\.name), ["dev", "test"])
    }

    /// Same byte count, newer mtime — proves invalidation isn't relying on size alone.
    func testCacheIsInvalidatedWhenOnlyTheModificationDateChanges() throws {
        let file = root.appendingPathComponent("package.json")
        try write(#"{"scripts":{"aaa":"vite"}}"#, to: file)
        let store = PackageScriptStore()
        XCTAssertEqual(store.scripts(cwd: root).map(\.name), ["aaa"])

        try write(#"{"scripts":{"bbb":"vite"}}"#, to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path
        )
        XCTAssertEqual(store.scripts(cwd: root).map(\.name), ["bbb"])
    }

    func testRepeatedReadsOfAnUnchangedFileStayCorrect() throws {
        try write(#"{"scripts":{"dev":"vite"}}"#, to: root.appendingPathComponent("package.json"))
        let store = PackageScriptStore()
        XCTAssertEqual(store.scripts(cwd: root).map(\.name), ["dev"])
        XCTAssertEqual(store.scripts(cwd: root).map(\.name), ["dev"])
    }
}
