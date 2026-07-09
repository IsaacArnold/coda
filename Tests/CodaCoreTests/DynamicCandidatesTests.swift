import XCTest
@testable import CodaCore

/// Covers the PURE seams of Task 11's dynamic generators: the path-fragment split, the
/// filesystem-candidate filtering/shaping rules, and the git one-name-per-line parser. The I/O
/// wrappers (`FileManager` enumeration, the throttled git spawn) live in the `Coda` app target and
/// are exercised in the deferred GUI pass.
final class DynamicCandidatesTests: XCTestCase {

    // MARK: - splitPathPrefix

    func testSplitNoSlashIsAllName() {
        let (dir, name) = splitPathPrefix("foo")
        XCTAssertEqual(dir, "")
        XCTAssertEqual(name, "foo")
    }

    func testSplitRelativeWithDotSlash() {
        let (dir, name) = splitPathPrefix("./s")
        XCTAssertEqual(dir, "./")
        XCTAssertEqual(name, "s")
    }

    func testSplitNestedRelative() {
        let (dir, name) = splitPathPrefix("src/ma")
        XCTAssertEqual(dir, "src/")
        XCTAssertEqual(name, "ma")
    }

    func testSplitAbsolute() {
        let (dir, name) = splitPathPrefix("/usr/lo")
        XCTAssertEqual(dir, "/usr/")
        XCTAssertEqual(name, "lo")
    }

    func testSplitTrailingSlashHasEmptyName() {
        let (dir, name) = splitPathPrefix("src/")
        XCTAssertEqual(dir, "src/")
        XCTAssertEqual(name, "")
    }

    // MARK: - filesystemCandidates (pure)

    private let entries = [
        DirectoryEntry(name: "src", isDirectory: true),
        DirectoryEntry(name: "Sources", isDirectory: true),
        DirectoryEntry(name: "setup.sh", isDirectory: false),
        DirectoryEntry(name: "README", isDirectory: false),
        DirectoryEntry(name: ".git", isDirectory: true),
    ]

    func testNamePrefixIsFullFragmentAndInsertionDescends() {
        // "./s" → dir "./", name "s", folders-only: matches src, Sources (case-insensitive).
        let cands = filesystemCandidates(
            from: entries, dirPart: "./", namePrefix: "s", foldersOnly: true
        )
        // name carries the dirPart so it prefix-matches the full query "./s"; dir insertion ends "/".
        XCTAssertEqual(cands.map(\.name), ["./Sources", "./src"])
        XCTAssertTrue(cands.allSatisfy { $0.kind == .directory })
        XCTAssertEqual(cands.first { $0.name == "./src" }?.insertion, "./src/")
    }

    func testFilesIncludedWhenNotFoldersOnlyAndFileInsertionHasNoSlash() {
        let cands = filesystemCandidates(
            from: entries, dirPart: "", namePrefix: "s", foldersOnly: false
        )
        // src, Sources (dirs) + setup.sh (file); README/.git filtered out.
        XCTAssertEqual(Set(cands.map(\.name)), ["src", "Sources", "setup.sh"])
        let file = cands.first { $0.name == "setup.sh" }
        XCTAssertEqual(file?.kind, .file)
        XCTAssertEqual(file?.insertion, "setup.sh") // no trailing slash / space for files in v1
    }

    func testHiddenFilesExcludedUnlessPrefixStartsWithDot() {
        let visible = filesystemCandidates(
            from: entries, dirPart: "", namePrefix: "", foldersOnly: false
        )
        XCTAssertFalse(visible.map(\.name).contains(".git"))

        let hidden = filesystemCandidates(
            from: entries, dirPart: "", namePrefix: ".", foldersOnly: false
        )
        XCTAssertEqual(hidden.map(\.name), [".git"])
    }

    func testDirectoriesSortFirstThenCaseInsensitiveName() {
        let cands = filesystemCandidates(
            from: entries, dirPart: "", namePrefix: "", foldersOnly: false
        )
        // dirs first (Sources, src), then files (README, setup.sh), each case-insensitively sorted.
        XCTAssertEqual(cands.map(\.name), ["Sources", "src", "README", "setup.sh"])
    }

    func testCapBoundsResultCount() {
        let many = (0..<500).map { DirectoryEntry(name: "d\($0)", isDirectory: true) }
        let cands = filesystemCandidates(
            from: many, dirPart: "", namePrefix: "d", foldersOnly: true, cap: 200
        )
        XCTAssertEqual(cands.count, 200)
    }

    // MARK: - gitNameCandidates (pure)

    func testGitParseSkipsBlankLinesAndTrims() {
        let out = "main\n  master \nfeat/x\n\n"
        let cands = gitNameCandidates(from: out)
        XCTAssertEqual(cands.map(\.name), ["main", "master", "feat/x"])
        XCTAssertTrue(cands.allSatisfy { $0.kind == .argument })
        XCTAssertEqual(cands.first?.insertion, "main ") // trailing space
    }

    func testGitParseEmptyOutput() {
        XCTAssertTrue(gitNameCandidates(from: "").isEmpty)
    }

    // MARK: - shell escaping (insertion only)

    func testShellEscapePlainNameUnchanged() {
        XCTAssertEqual(shellEscapeForInsertion("Documents"), "Documents")
        // Non-special punctuation and non-ASCII stay untouched.
        XCTAssertEqual(shellEscapeForInsertion("my-file.v2_final,café@x:1"), "my-file.v2_final,café@x:1")
    }

    func testShellEscapeSlashStaysLiteral() {
        XCTAssertEqual(shellEscapeForInsertion("src/My File"), "src/My\\ File")
    }

    func testShellEscapeSpecialCharacters() {
        XCTAssertEqual(shellEscapeForInsertion("a b"), "a\\ b")
        XCTAssertEqual(shellEscapeForInsertion("f(1)"), "f\\(1\\)")
        XCTAssertEqual(shellEscapeForInsertion("cost$x"), "cost\\$x")
        XCTAssertEqual(shellEscapeForInsertion("a&b;c|d"), "a\\&b\\;c\\|d")
    }

    func testDirectoryWithSpaceEscapesInsertionButNotName() {
        let entries = [DirectoryEntry(name: "Application Support", isDirectory: true)]
        let cands = filesystemCandidates(from: entries, dirPart: "", namePrefix: "Appl", foldersOnly: true)
        XCTAssertEqual(cands.count, 1)
        // name stays unescaped (query-matchable + displayed); insertion is escaped, trailing / kept.
        XCTAssertEqual(cands[0].name, "Application Support")
        XCTAssertEqual(cands[0].insertion, "Application\\ Support/")
    }

    func testFileWithSpecialCharsEscapedInInsertion() {
        let entries = [DirectoryEntry(name: "totals($).csv", isDirectory: false)]
        let cands = filesystemCandidates(from: entries, dirPart: "", namePrefix: "t", foldersOnly: false)
        XCTAssertEqual(cands[0].name, "totals($).csv")
        XCTAssertEqual(cands[0].insertion, "totals\\(\\$\\).csv") // no trailing slash for files
    }

    func testDirPartWithSlashKeepsSeparatorLiteralAndEscapesSpace() {
        let entries = [DirectoryEntry(name: "My File", isDirectory: false)]
        let cands = filesystemCandidates(from: entries, dirPart: "sub/", namePrefix: "My", foldersOnly: false)
        XCTAssertEqual(cands[0].name, "sub/My File")
        XCTAssertEqual(cands[0].insertion, "sub/My\\ File")
    }

    func testGitBranchWithSpecialCharEscapedTrailingSpacePreserved() {
        let cands = gitNameCandidates(from: "feature/my thing\n")
        XCTAssertEqual(cands[0].name, "feature/my thing")           // unescaped
        XCTAssertEqual(cands[0].insertion, "feature/my\\ thing ")   // escaped body + unescaped space
    }
}
