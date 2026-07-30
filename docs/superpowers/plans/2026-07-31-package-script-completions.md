# Package Script Completions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Offer a project's `package.json` scripts in the terminal completion popup — as `run dev` at `npm `, and as bare `dev` at `npm run ` — for npm, yarn, pnpm and bun.

**Architecture:** Two new `GeneratorID` cases (`packageScripts`, `packageScriptsWithRun`) let spec JSON choose the rendered shape, so the pure engine needs no change — `resolveCompletion` already emits a resolved spec's subcommands plus its positional arg's generator. Parsing, shaping, the walk-up to the nearest `package.json` and an mtime-invalidated cache all live in `CodaCore` (where they are unit-testable); the GUI's `CompletionGenerators` only owns an instance and delegates.

**Tech Stack:** Swift 5 language mode, SwiftPM, XCTest, Foundation `JSONSerialization`. No new dependencies.

## Global Constraints

- Platform floor is **macOS 13** (`Package.swift`: `platforms: [.macOS(.v13)]`). No API newer than macOS 13.
- `swiftLanguageModes: [.v5]`.
- **`CodaCore` must not import AppKit or SwiftTerm.** It is the headless, testable half; only `Foundation`.
- **No new package dependencies.**
- The only test target is **`CodaCoreTests`** — there is no test target for the GUI `Coda` target. Anything that needs a test must live in `CodaCore`.
- Build: `swift build` (uses the default CommandLineTools toolchain).
- Test: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest` — the full Xcode toolchain is **required** (CommandLineTools has no XCTest module) and the **separate `--build-path` is required** (mixing toolchains in one build dir causes "module compiled with Swift 6.3.2 cannot be imported by the Swift 6.2.3 compiler").
- SourceKit reports phantom "cannot find type / no member" errors for `Coda`↔`CodaCore` edits. **Trust `swift build`, not the editor diagnostics.**
- Every commit message ends with:
  `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`
- Baseline before starting: **558 tests passing** on branch `feat/package-script-completions`.

**Deviation from the spec (intentional):** the spec sketched a single `packageScriptCandidates(packageJSON:runPrefixed:cap:)`. This plan splits it into `parsePackageScripts(packageJSON:) -> [PackageScript]` and `scriptCandidates(_:runPrefixed:cap:) -> [Candidate]`, because the cache stores parsed scripts once and both shapes (`dev` and `run dev`) are rendered from the same cached parse. Same behaviour, no double parsing.

---

### Task 1: `.script` candidate kind, ranked ahead of other kinds

**Files:**
- Modify: `Sources/CodaCore/CompletionEngine.swift:6-13` (the `CandidateKind` enum)
- Modify: `Sources/CodaCore/CompletionEngine.swift:230-245` (`rankCandidates`)
- Test: `Tests/CodaCoreTests/CompletionEngineTests.swift` (append to the `// MARK: - rankCandidates` section, which starts at line 173)

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `CandidateKind.script`, and the guarantee that `rankCandidates` places `.script` candidates ahead of other kinds *within each match tier*.

Why this is needed: with an empty query `rankCandidates` returns its input unchanged, and `CompletionController` assembles `staticCandidates + dynamic`. Without this change, scripts would appear *below* npm's own subcommands at `npm `.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/CodaCoreTests/CompletionEngineTests.swift` inside the `rankCandidates` section. The existing helper at line 38 is `private func candidate(_ name: String, kind: CandidateKind = .subcommand) -> Candidate`, so pass `kind:` explicitly:

```swift
    func testScriptsRankAheadOfOtherKindsWithEmptyQuery() {
        let all = [candidate("install"), candidate("run dev", kind: .script)]
        let ranked = rankCandidates(all, query: "")
        XCTAssertEqual(ranked.map(\.name), ["run dev", "install"])
    }

    func testScriptsRankAheadWithinTheSameMatchTier() {
        // Both prefix-match "r"; the script must come first.
        let all = [candidate("remove"), candidate("run dev", kind: .script)]
        let ranked = rankCandidates(all, query: "r")
        XCTAssertEqual(ranked.map(\.name), ["run dev", "remove"])
    }

    func testPrefixTierStillBeatsAScriptSubstringMatch() {
        // "dev-server" prefix-matches "dev"; "run dev" only contains it. Scripts are promoted
        // WITHIN a tier, never across tiers — a substring script must not jump a prefix match.
        let all = [candidate("dev-server"), candidate("run dev", kind: .script)]
        let ranked = rankCandidates(all, query: "dev")
        XCTAssertEqual(ranked.map(\.name), ["dev-server", "run dev"])
    }

    func testScriptOrderAmongScriptsIsPreserved() {
        let all = [candidate("run build", kind: .script), candidate("run dev", kind: .script)]
        let ranked = rankCandidates(all, query: "")
        XCTAssertEqual(ranked.map(\.name), ["run build", "run dev"])
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter 'CompletionEngineTests'
```
Expected: compile error — `type 'CandidateKind' has no member 'script'`. That is the correct first failure; the kind does not exist yet.

- [ ] **Step 3: Add the `.script` kind**

In `Sources/CodaCore/CompletionEngine.swift`, add one case to `CandidateKind`:

```swift
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
```

- [ ] **Step 4: Re-run to see the assertions fail (not the compiler)**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter 'CompletionEngineTests'
```
Expected: it now compiles, and `testScriptsRankAheadOfOtherKindsWithEmptyQuery` / `testScriptsRankAheadWithinTheSameMatchTier` FAIL with `("install", "run dev") is not equal to ("run dev", "install")` and similar. `testPrefixTierStillBeatsAScriptSubstringMatch` and `testScriptOrderAmongScriptsIsPreserved` may already pass — that is fine, they are guardrails against over-correcting in the next step.

- [ ] **Step 5: Implement the script-first partition**

Replace `rankCandidates` in `Sources/CodaCore/CompletionEngine.swift` (currently lines 230-245). Keep the existing doc comment above it and extend it:

```swift
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
```

- [ ] **Step 6: Run the whole suite**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest
```
Expected: all pass — 562 tests (558 baseline + 4 new). If any pre-existing `rankCandidates` or `resolveCompletion` test broke, the partition leaked outside `.script`; fix it rather than editing the old test.

- [ ] **Step 7: Commit**

```bash
git add Sources/CodaCore/CompletionEngine.swift Tests/CodaCoreTests/CompletionEngineTests.swift
git commit -m "$(cat <<'MSG'
feat(completions): add a .script candidate kind ranked ahead of others

rankCandidates returns its input unchanged for an empty query and the controller
assembles static + dynamic, so project scripts would otherwise appear below a
package manager's own subcommands at `npm `. Promote .script within each match
tier — never across tiers, so a substring script can't jump a prefix match.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

### Task 2: Parse and shape `package.json` scripts (pure)

**Files:**
- Create: `Sources/CodaCore/PackageScripts.swift`
- Test: `Tests/CodaCoreTests/PackageScriptsTests.swift`

**Interfaces:**
- Consumes: `Candidate`, `CandidateKind.script` (Task 1), `shellEscapeForInsertion(_:)` from `Sources/CodaCore/DynamicCandidates.swift:95`.
- Produces:
  - `public struct PackageScript: Equatable { public let name: String; public let command: String }`
  - `public func parsePackageScripts(packageJSON: Data) -> [PackageScript]`
  - `public func scriptCandidates(_ scripts: [PackageScript], runPrefixed: Bool, cap: Int = 100) -> [Candidate]`
  - `public let packageScriptDescriptionLimit = 60`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CodaCoreTests/PackageScriptsTests.swift`:

```swift
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

    func testLongCommandIsTruncatedWithEllipsis() {
        let long = String(repeating: "x", count: 200)
        let candidates = scriptCandidates([PackageScript(name: "dev", command: long)],
                                          runPrefixed: false)
        let description = try? XCTUnwrap(candidates.first?.description)
        XCTAssertEqual(description?.count, packageScriptDescriptionLimit)
        XCTAssertTrue(description?.hasSuffix("…") == true)
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter 'PackageScriptsTests'
```
Expected: compile error — `cannot find 'parsePackageScripts' in scope` and `cannot find type 'PackageScript' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CodaCore/PackageScripts.swift`:

```swift
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter 'PackageScriptsTests'
```
Expected: 17 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodaCore/PackageScripts.swift Tests/CodaCoreTests/PackageScriptsTests.swift
git commit -m "$(cat <<'MSG'
feat(completions): parse and shape package.json scripts

Pure half of the feature: parse the scripts object (degrading to [] on every
malformed shape, skipping non-string values while keeping valid siblings) and
shape it into candidates in either the bare (`dev`) or run-prefixed (`run dev`)
form. Descriptions collapse whitespace and truncate, since scripts are often
written across lines and the popup is one line per row.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

### Task 3: Resolve the nearest `package.json` and cache it

**Files:**
- Modify: `Sources/CodaCore/PackageScripts.swift` (append)
- Test: `Tests/CodaCoreTests/PackageScriptStoreTests.swift`

**Interfaces:**
- Consumes: `parsePackageScripts(packageJSON:)`, `scriptCandidates(_:runPrefixed:cap:)` (Task 2).
- Produces:
  - `public func findNearestPackageJSON(startingAt directory: URL) -> URL?`
  - `public final class PackageScriptStore` with `public init()`, `public func scripts(cwd: URL) -> [PackageScript]`, and `public func candidates(cwd: URL, runPrefixed: Bool) -> [Candidate]`

This lives in `CodaCore`, not in the GUI's `CompletionGenerators`, purely so it can be tested — `CodaCoreTests` is the only test target, and `CodaCore` already hosts tested file-I/O types (`Config`, `KeybindingsStore`, `DataDirMigration`).

- [ ] **Step 1: Write the failing tests**

Create `Tests/CodaCoreTests/PackageScriptStoreTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter 'PackageScriptStoreTests'
```
Expected: compile error — `cannot find 'findNearestPackageJSON' in scope`, `cannot find 'PackageScriptStore' in scope`.

- [ ] **Step 3: Write the implementation**

Append to `Sources/CodaCore/PackageScripts.swift`:

```swift
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter 'PackageScriptStoreTests'
```
Expected: 10 tests pass.

If `testCacheIsInvalidatedWhenOnlyTheModificationDateChanges` fails, the stamp is ignoring the modification date — do not weaken the test; fix `currentStamp`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodaCore/PackageScripts.swift Tests/CodaCoreTests/PackageScriptStoreTests.swift
git commit -m "$(cat <<'MSG'
feat(completions): resolve and cache the nearest package.json

Walks up from the cwd like npm does, so scripts complete from a subdirectory of
the project. Cached per resolved path and invalidated on mtime or size change, so
editing package.json is reflected on the next keystroke rather than offering
scripts that no longer exist.

Synchronous by design: one small file read needs none of the git generators'
in-flight/TTL machinery, and candidates appear on the first keystroke.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

### Task 4: Wire the generators into the spec vocabulary and the GUI

**Files:**
- Modify: `Sources/CodaCore/CompletionSpec.swift:101-104` (the `GeneratorID` enum)
- Modify: `Sources/Coda/CompletionGenerators.swift` (add the store + accessor)
- Modify: `Sources/Coda/CompletionController.swift:238-249` (the `resolveDynamicSources` switch)
- Test: `Tests/CodaCoreTests/CompletionEngineTests.swift` (append a new `// MARK: - package script generators` section)

**Interfaces:**
- Consumes: `PackageScriptStore` (Task 3).
- Produces: `GeneratorID.packageScripts`, `GeneratorID.packageScriptsWithRun`, and `CompletionGenerators.packageScripts(cwd:runPrefixed:) -> [Candidate]`.

Adding cases to `GeneratorID` makes the controller's `switch` non-exhaustive, so the compiler will point at the one place that must be updated. That is intentional.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/CodaCoreTests/CompletionEngineTests.swift`. These prove the *engine* offers the right generator at each position, using specs built in code:

```swift
    // MARK: - package script generators

    /// The shape the npm spec relies on: at `npm `, the engine offers the command's own
    /// subcommands AND the positional arg's generator, so scripts and subcommands coexist.
    func testTopLevelPositionOffersSubcommandsAndTheScriptGenerator() {
        let npm = CompletionSpec(
            name: ["npm"],
            subcommands: [CompletionSpec(name: ["install"])],
            args: [SpecArg(name: "script", generator: .packageScriptsWithRun, isOptional: true)]
        )
        let context = resolveCompletion(line: "npm ", cursorOffset: 4, specs: ["npm": npm])
        XCTAssertEqual(context.staticCandidates.map(\.name), ["install"])
        XCTAssertEqual(context.dynamicSources, [.generator(.packageScriptsWithRun)])
    }

    func testAfterRunSubcommandTheBareScriptGeneratorIsOffered() {
        let npm = CompletionSpec(
            name: ["npm"],
            subcommands: [
                CompletionSpec(name: ["run"], args: [SpecArg(generator: .packageScripts)])
            ],
            args: [SpecArg(name: "script", generator: .packageScriptsWithRun, isOptional: true)]
        )
        let context = resolveCompletion(line: "npm run ", cursorOffset: 8, specs: ["npm": npm])
        XCTAssertEqual(context.dynamicSources, [.generator(.packageScripts)])
    }

    func testYarnOffersBareScriptsAtTopLevel() {
        let yarn = CompletionSpec(
            name: ["yarn"],
            args: [SpecArg(generator: .packageScripts, isOptional: true)]
        )
        let context = resolveCompletion(line: "yarn ", cursorOffset: 5, specs: ["yarn": yarn])
        XCTAssertEqual(context.dynamicSources, [.generator(.packageScripts)])
    }
```

Also append to `Tests/CodaCoreTests/CompletionSpecTests.swift`, proving the JSON vocabulary decodes (the loader silently skips files it can't decode, so an unknown id would disable a whole spec):

```swift
    // MARK: - package script generator ids

    func testPackageScriptGeneratorIdsDecodeFromJSON() throws {
        let json = Data("""
        {
          "name": ["npm"],
          "args": [{ "name": "script", "generator": "packageScriptsWithRun" }],
          "subcommands": [
            { "name": ["run"], "args": [{ "generator": "packageScripts" }] }
          ]
        }
        """.utf8)
        let spec = try JSONDecoder().decode(CompletionSpec.self, from: json)
        XCTAssertEqual(spec.args?.first?.generator, .packageScriptsWithRun)
        XCTAssertEqual(spec.subcommands?.first?.args?.first?.generator, .packageScripts)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter 'CompletionEngineTests|CompletionSpecTests'
```
Expected: compile error — `type 'GeneratorID' has no member 'packageScriptsWithRun'`.

- [ ] **Step 3: Add the generator ids**

In `Sources/CodaCore/CompletionSpec.swift`, extend `GeneratorID`:

```swift
public enum GeneratorID: String, Codable, Equatable {
    case gitBranches
    case gitRemotes
    /// The nearest `package.json`'s scripts, as bare names (`dev`). Used after a `run`
    /// subcommand, and at top level for yarn (which runs scripts without `run`).
    case packageScripts
    /// The same scripts rendered `run`-prefixed (`run dev`), for the position *before* `run` has
    /// been typed — so npm/pnpm/bun users never have to type it. Two ids rather than one plus
    /// engine-threaded context: the difference is purely cosmetic, and this keeps the pure engine
    /// untouched and each spec position explicit about the shape it wants.
    case packageScriptsWithRun
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter 'CompletionEngineTests|CompletionSpecTests'
```
Expected: PASS. (`swift test` builds only `CodaCore` + tests, so the GUI's non-exhaustive switch has not bitten yet — that's Step 5.)

- [ ] **Step 5: Wire the GUI (the build will fail until you do)**

Run `swift build` and expect:
`error: switch must be exhaustive` in `Sources/Coda/CompletionController.swift`.

First, in `Sources/Coda/CompletionGenerators.swift`, add the store next to the git caches and an accessor next to `gitRemotes`:

```swift
    /// Resolves `package.json` scripts. Synchronous and self-caching (see `PackageScriptStore`),
    /// so unlike the git generators it needs no in-flight tracking or `onAsyncUpdate` hop.
    private let packageScriptStore = PackageScriptStore()
```

```swift
    // MARK: - package.json scripts (sync, cached by mtime)

    /// Scripts from the nearest `package.json` at or above `cwd`. `runPrefixed` renders them as
    /// `run dev` rather than `dev`. `[]` when there's no `package.json` — e.g. `npm ` in a Swift
    /// project offers only npm's own subcommands.
    func packageScripts(cwd: URL, runPrefixed: Bool) -> [Candidate] {
        packageScriptStore.candidates(cwd: cwd, runPrefixed: runPrefixed)
    }
```

Then extend the switch in `Sources/Coda/CompletionController.swift`:

```swift
            case .generator(.packageScripts):
                return generators.packageScripts(cwd: cwd, runPrefixed: false)
            case .generator(.packageScriptsWithRun):
                return generators.packageScripts(cwd: cwd, runPrefixed: true)
```

- [ ] **Step 6: Build and run the whole suite**

Run:
```bash
swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest
```
Expected: `Build complete!` and **zero test failures** — 593 tests (558 baseline + 4 Task 1 + 17 Task 2 + 10 Task 3 + 4 this task). Ignore SourceKit's phantom cross-module errors; `swift build` is the authority.

- [ ] **Step 7: Commit**

```bash
git add Sources/CodaCore/CompletionSpec.swift Sources/Coda/CompletionGenerators.swift \
        Sources/Coda/CompletionController.swift Tests/CodaCoreTests/CompletionEngineTests.swift \
        Tests/CodaCoreTests/CompletionSpecTests.swift
git commit -m "$(cat <<'MSG'
feat(completions): wire packageScripts generators into specs and the GUI

Two ids rather than one plus engine-threaded positional context: the difference
between `run dev` and `dev` is cosmetic, so letting spec data pick the shape
keeps the pure engine untouched.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

### Task 5: The four spec files

**Files:**
- Create: `Sources/Coda/Resources/completion-specs/npm.json`
- Create: `Sources/Coda/Resources/completion-specs/yarn.json`
- Create: `Sources/Coda/Resources/completion-specs/pnpm.json`
- Create: `Sources/Coda/Resources/completion-specs/bun.json`
- Test: `Tests/CodaCoreTests/BundledSpecsTests.swift`

**Interfaces:**
- Consumes: `GeneratorID.packageScripts` / `.packageScriptsWithRun` (Task 4), `loadCompletionSpecs(from:)` from `Sources/CodaCore/CompletionSpec.swift:131`.
- Produces: the four shipped specs. No Swift API.

The specs directory is auto-discovered (`Package.swift` already declares `resources: [.copy("Resources")]`), so **no `Package.swift` change is needed**.

The test loads the **real** spec directory from the repo, because `loadCompletionSpecs` deliberately *skips* files it can't decode — a JSON typo would silently disable a whole command with no error anywhere.

- [ ] **Step 1: Write the failing test**

Create `Tests/CodaCoreTests/BundledSpecsTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter 'BundledSpecsTests'
```
Expected: FAIL — `testNpmOffersRunPrefixedScriptsAtTopLevel` etc. fail on `XCTUnwrap(specs["npm"])` because no npm spec exists yet. `testEveryBundledSpecFileDecodes` passes (the six existing specs all decode) — it is a guard, not a driver.

- [ ] **Step 3: Create `npm.json`**

Create `Sources/Coda/Resources/completion-specs/npm.json`:

```json
{
  "name": ["npm"],
  "description": "Node package manager",
  "args": [
    { "name": "script", "generator": "packageScriptsWithRun", "isOptional": true }
  ],
  "options": [
    { "name": ["--help", "-h"], "description": "Display help" },
    { "name": ["--version", "-v"], "description": "Print the npm version" }
  ],
  "subcommands": [
    {
      "name": ["run", "run-script"],
      "description": "Run a script from package.json",
      "args": [{ "name": "script", "generator": "packageScripts" }]
    },
    {
      "name": ["install", "i"],
      "description": "Install a package",
      "args": [{ "name": "package", "isOptional": true, "isVariadic": true }],
      "options": [
        { "name": ["--save-dev", "-D"], "description": "Save to devDependencies" },
        { "name": ["--global", "-g"], "description": "Install globally" }
      ]
    },
    { "name": ["ci"], "description": "Clean install from the lockfile" },
    { "name": ["test", "t"], "description": "Run the test script" },
    { "name": ["start"], "description": "Run the start script" },
    {
      "name": ["uninstall", "rm"],
      "description": "Remove a package",
      "args": [{ "name": "package", "isVariadic": true }]
    },
    {
      "name": ["update", "up"],
      "description": "Update packages",
      "args": [{ "name": "package", "isOptional": true, "isVariadic": true }]
    },
    { "name": ["outdated"], "description": "Check for outdated packages" },
    { "name": ["publish"], "description": "Publish a package" },
    { "name": ["exec", "x"], "description": "Run a command from a package" },
    { "name": ["init"], "description": "Create a package.json" },
    { "name": ["link"], "description": "Symlink a package folder" }
  ]
}
```

- [ ] **Step 4: Create `pnpm.json`**

Create `Sources/Coda/Resources/completion-specs/pnpm.json`:

```json
{
  "name": ["pnpm"],
  "description": "Fast, disk-space-efficient package manager",
  "args": [
    { "name": "script", "generator": "packageScriptsWithRun", "isOptional": true }
  ],
  "options": [
    { "name": ["--help", "-h"], "description": "Display help" },
    { "name": ["--version", "-v"], "description": "Print the pnpm version" }
  ],
  "subcommands": [
    {
      "name": ["run"],
      "description": "Run a script from package.json",
      "args": [{ "name": "script", "generator": "packageScripts" }]
    },
    {
      "name": ["install", "i"],
      "description": "Install all dependencies",
      "options": [
        { "name": ["--frozen-lockfile"], "description": "Fail if the lockfile is out of date" }
      ]
    },
    {
      "name": ["add"],
      "description": "Add a package",
      "args": [{ "name": "package", "isVariadic": true }],
      "options": [
        { "name": ["--save-dev", "-D"], "description": "Save to devDependencies" },
        { "name": ["--global", "-g"], "description": "Install globally" }
      ]
    },
    {
      "name": ["remove", "rm"],
      "description": "Remove a package",
      "args": [{ "name": "package", "isVariadic": true }]
    },
    { "name": ["update", "up"], "description": "Update packages" },
    { "name": ["dlx"], "description": "Run a package without installing it" },
    { "name": ["exec"], "description": "Run a shell command from a local dependency" },
    { "name": ["init"], "description": "Create a package.json" }
  ]
}
```

- [ ] **Step 5: Create `bun.json`**

Create `Sources/Coda/Resources/completion-specs/bun.json`:

```json
{
  "name": ["bun"],
  "description": "Fast all-in-one JavaScript runtime and toolkit",
  "args": [
    { "name": "script", "generator": "packageScriptsWithRun", "isOptional": true }
  ],
  "options": [
    { "name": ["--help", "-h"], "description": "Display help" },
    { "name": ["--version", "-v"], "description": "Print the bun version" }
  ],
  "subcommands": [
    {
      "name": ["run"],
      "description": "Run a script or file",
      "args": [{ "name": "script", "generator": "packageScripts" }]
    },
    { "name": ["install", "i"], "description": "Install all dependencies" },
    {
      "name": ["add", "a"],
      "description": "Add a package",
      "args": [{ "name": "package", "isVariadic": true }],
      "options": [
        { "name": ["--dev", "-d"], "description": "Save to devDependencies" },
        { "name": ["--global", "-g"], "description": "Install globally" }
      ]
    },
    {
      "name": ["remove", "rm"],
      "description": "Remove a package",
      "args": [{ "name": "package", "isVariadic": true }]
    },
    { "name": ["update"], "description": "Update packages" },
    { "name": ["x"], "description": "Run a package without installing it" },
    { "name": ["test"], "description": "Run tests with bun's test runner" },
    { "name": ["init"], "description": "Create a package.json" }
  ]
}
```

- [ ] **Step 6: Create `yarn.json`**

Note the difference: `yarn dev` works without `run`, so the **top-level generator is the bare one**.

Create `Sources/Coda/Resources/completion-specs/yarn.json`:

```json
{
  "name": ["yarn"],
  "description": "Yarn package manager",
  "args": [
    { "name": "script", "generator": "packageScripts", "isOptional": true }
  ],
  "options": [
    { "name": ["--help", "-h"], "description": "Display help" },
    { "name": ["--version", "-v"], "description": "Print the yarn version" }
  ],
  "subcommands": [
    {
      "name": ["run"],
      "description": "Run a script from package.json",
      "args": [{ "name": "script", "generator": "packageScripts" }]
    },
    { "name": ["install"], "description": "Install all dependencies" },
    {
      "name": ["add"],
      "description": "Add a package",
      "args": [{ "name": "package", "isVariadic": true }],
      "options": [
        { "name": ["--dev", "-D"], "description": "Save to devDependencies" }
      ]
    },
    {
      "name": ["remove"],
      "description": "Remove a package",
      "args": [{ "name": "package", "isVariadic": true }]
    },
    { "name": ["up"], "description": "Upgrade packages" },
    { "name": ["why"], "description": "Explain why a package is installed" },
    { "name": ["dlx"], "description": "Run a package without installing it" },
    { "name": ["init"], "description": "Create a package.json" }
  ]
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest --filter 'BundledSpecsTests'
```
Expected: 7 tests pass. If `testEveryBundledSpecFileDecodes` now fails, one of the four new files has a JSON error or an unknown generator id — its message names which specs loaded.

- [ ] **Step 8: Confirm the specs reach the built app bundle**

Run:
```bash
./scripts/make-app.sh 2>&1 | tail -3
ls dist/Coda.app/Contents/Resources/Resources/completion-specs/
```
Expected: all ten specs listed, including `npm.json`, `yarn.json`, `pnpm.json`, `bun.json`.

- [ ] **Step 9: Commit**

```bash
git add Sources/Coda/Resources/completion-specs/npm.json \
        Sources/Coda/Resources/completion-specs/yarn.json \
        Sources/Coda/Resources/completion-specs/pnpm.json \
        Sources/Coda/Resources/completion-specs/bun.json \
        Tests/CodaCoreTests/BundledSpecsTests.swift
git commit -m "$(cat <<'MSG'
feat(completions): ship npm, yarn, pnpm and bun specs

Each offers package.json scripts plus a short static subcommand list. yarn takes
the bare script generator at top level since it runs scripts without `run`.

BundledSpecsTests loads the real shipped directory, because loadCompletionSpecs
deliberately SKIPS files it can't decode — so a JSON typo would otherwise
silently disable a whole command with no error anywhere.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

### Task 6: Verify in a running app, then finalise

**Files:** none modified (verification only, plus the plan checkboxes).

**Interfaces:**
- Consumes: everything above.
- Produces: evidence the feature works in the real GUI, not only in tests.

Uses the isolated-instance technique from `CODA_DATA_DIR` (already on this branch) so it cannot disturb an installed Coda: a second instance would otherwise delete and rebind the installed app's hook socket and race it on `local.json`.

- [ ] **Step 1: Build a debug app copy with its own identity**

```bash
./scripts/make-app.sh 2>&1 | tail -3
DBG=/tmp/coda-dbg
rm -rf "$DBG" && mkdir -p "$DBG/data"
cp -R dist/Coda.app "$DBG/CodaDebug.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier net.branchoutonline.coda.debug' \
  "$DBG/CodaDebug.app/Contents/Info.plist"
codesign --force --deep --sign - "$DBG/CodaDebug.app"
```

A distinct bundle identifier matters: sharing one would let this copy disturb the real app's notification authorization.

- [ ] **Step 2: Seed its preferences so completions are on and no modals appear**

```bash
python3 - <<'EOF'
import json, os, pathlib
data = pathlib.Path("/tmp/coda-dbg/data")
prefs = json.loads(pathlib.Path(os.path.expanduser("~/.coda/preferences.json")).read_text())
prefs.update({"completionsEnabled": True, "askedCompletionsConsent": True,
              "declinedHookInstall": True, "notifyOnDone": False,
              "notifyOnNeedsYou": False, "showDockBadge": False})
(data / "preferences.json").write_text(json.dumps(prefs, indent=2))
EOF
```

- [ ] **Step 3: Create a throwaway JS project to complete against**

```bash
mkdir -p /tmp/coda-dbg/demo/src/components
cat > /tmp/coda-dbg/demo/package.json <<'EOF'
{
  "name": "demo",
  "scripts": {
    "dev": "vite --host",
    "build": "tsc && vite build",
    "test": "vitest run",
    "lint": "eslint . --ext .ts,.tsx --max-warnings 0 --cache --cache-location .eslintcache"
  }
}
EOF
```

- [ ] **Step 4: Launch the isolated instance**

```bash
CODA_DATA_DIR=/tmp/coda-dbg/data CODA_DEBUG_COMPLETIONS=1 \
  /tmp/coda-dbg/CodaDebug.app/Contents/MacOS/Coda &
```

Confirm isolation held — an installed Coda must still be running with its own socket untouched:
```bash
ls -la ~/Library/Application\ Support/Coda/hooks.sock
ls /tmp/coda-dbg/data/
```

- [ ] **Step 5: Check each behaviour by hand**

In the debug app, add `/tmp/coda-dbg/demo` (or open a terminal there) and confirm:

| Type this | Expect |
|---|---|
| `npm ` | `run build`, `run dev`, `run lint`, `run test` **first**, then `install`, `ci`, `test`, … |
| `npm run ` | `build`, `dev`, `lint`, `test` — bare names |
| `npm d` | `run dev` offered (substring match) |
| accept `run dev` | line becomes `npm run dev ` |
| `yarn ` | `build`, `dev`, `lint`, `test` bare, plus `add`, `install`, … |
| `npm ` from `demo/src/components` | same scripts — proves the walk-up |
| `npm ` in a **non-JS** dir (e.g. the coda repo) | only npm's own subcommands, no scripts, no error |
| edit `package.json` to add `"deploy": "sh deploy.sh"`, then `npm run ` again | `deploy` appears without restarting |
| `run lint`'s description | truncated with a trailing `…` |

- [ ] **Step 6: Stop the debug app and clean up**

```bash
pkill -f "CodaDebug.app/Contents/MacOS/Coda"
rm -rf /tmp/coda-dbg
```

- [ ] **Step 7: Full suite and a clean build**

```bash
swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest
git status --short
```
Expected: `Build complete!`, zero test failures, and a clean tree — in particular **no stray `.zsh_history`** or other artifact inside `Sources/Coda/Resources/`.

- [ ] **Step 8: Tick every checkbox in this plan and commit it**

```bash
git add docs/superpowers/plans/2026-07-31-package-script-completions.md
git commit -m "$(cat <<'MSG'
docs: mark package script completions plan complete

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

- [ ] **Step 9: Open the PR**

```bash
git push -u origin feat/package-script-completions
gh pr create --base main --title "feat(completions): package.json script completions" --body "..."
```

The PR body should state the two positions (`run dev` at `npm `, bare at `npm run `), why there are two generator ids, that overlap with npm's built-in `test`/`start` subcommands is intentional, and the manual verification results from Step 5.

**Note:** this branch is based on `fix/completions-shell-integration-hijack` (PR #71), not `main`. If #71 has merged by now, rebase onto `main` before pushing:
```bash
git fetch origin && git rebase origin/main
```
Otherwise expect the PR to show #71's two commits as well, and retarget it once #71 lands.

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| Two generator IDs, shaping via spec data | 4 |
| No engine change for the two positions | 4 (proved by the engine tests) |
| `CandidateKind.script` | 1 |
| Pure parse + shape in CodaCore | 2 |
| Alphabetical sort | 2 |
| Description = script command, truncated to 60 | 2 |
| Escaped insertion, trailing space | 2 |
| Walk up to nearest `package.json` | 3 |
| mtime/size-invalidated cache | 3 |
| Synchronous, no async machinery | 3 |
| Scripts rank first, within tier only | 1 |
| Four spec files, yarn bare at top level | 5 |
| `isOptional: true` on top-level script arg | 5 |
| Overlap with `test`/`start` not deduped | 5 (`testNpmKeepsItsBuiltInTestSubcommand`) |
| Every error path degrades to `[]` | 2, 3 |
| Diagnostics only behind `CODA_DEBUG_COMPLETIONS` | no new logging added, so nothing to do |
| Out of scope items | not implemented, by design |

**Placeholder scan:** no TBD/TODO. Every code step carries the actual code; every test step carries the actual assertions. The only `"..."` is the `gh pr create --body` in Task 6 Step 9, immediately followed by the specific points the body must make.

**Type consistency:** `PackageScript(name:command:)`, `parsePackageScripts(packageJSON:)`, `scriptCandidates(_:runPrefixed:cap:)`, `findNearestPackageJSON(startingAt:)`, `PackageScriptStore.scripts(cwd:)` / `.candidates(cwd:runPrefixed:)`, `CompletionGenerators.packageScripts(cwd:runPrefixed:)`, `GeneratorID.packageScripts` / `.packageScriptsWithRun`, `CandidateKind.script` — each spelled identically at every point of use across Tasks 1-5. The existing test helper `candidate(_:kind:)` is used with the signature it actually has at `CompletionEngineTests.swift:38`.
