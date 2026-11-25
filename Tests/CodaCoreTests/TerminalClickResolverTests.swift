import XCTest
@testable import CodaCore

/// Resolver behind ⌘ + click / ⌘-hover on terminal text (issue #79). Every case here
/// failed with the old first-token-that-exists scan in `ClickableTerminalView`.
final class TerminalClickResolverTests: XCTestCase {
    private let base = "/repo"
    private var fs: [String: PathKind] = [:]

    override func setUp() {
        fs = [
            "/repo/a.md": .file,
            "/repo/b.md": .file,
            "/repo/docs": .directory,
            "/repo/docs/plan.md": .file,
            "/repo/notes/plan.md": .file,
            "/repo/__init__.py": .file,
            "/repo/Sources/main.swift": .file,
            "/repo/My Notes/plan.md": .file,
            "/abs/x.md": .file,
        ]
    }

    /// Resolve a click on the first occurrence of `needle` in `line` (offset of its first char).
    private func click(_ line: String, on needle: String, at extra: Int = 0,
                       baseDirs: [String]? = nil) -> TerminalClickTarget? {
        guard let r = line.range(of: needle) else {
            XCTFail("needle \(needle) not in line"); return nil
        }
        let offset = line.distance(from: line.startIndex, to: r.lowerBound) + extra
        return resolveClickTarget(line: line, offset: offset, baseDirs: baseDirs ?? [base],
                                  pathKind: { self.fs[$0] })
    }

    // MARK: click column

    func testPicksTokenUnderClickNotFirstResolvingToken() {
        XCTAssertEqual(click("edited a.md and b.md", on: "b.md"), .file(path: "/repo/b.md", line: nil))
        XCTAssertEqual(click("edited a.md and b.md", on: "a.md"), .file(path: "/repo/a.md", line: nil))
    }

    func testClickOnWhitespaceOrNonPathWordIsNil() {
        XCTAssertNil(click("edited a.md and b.md", on: " and", at: 0))
        XCTAssertNil(click("edited a.md and b.md", on: "edited"))
    }

    func testClickAnywhereInsideTokenResolves() {
        XCTAssertEqual(click("see docs/plan.md", on: "plan.md", at: 3), .file(path: "/repo/docs/plan.md", line: nil))
    }

    func testOutOfRangeOffsetIsNil() {
        XCTAssertNil(resolveClickTarget(line: "a.md", offset: 10, baseDirs: [base], pathKind: { self.fs[$0] }))
        XCTAssertNil(resolveClickTarget(line: "a.md", offset: -1, baseDirs: [base], pathKind: { self.fs[$0] }))
    }

    // MARK: punctuation and markdown

    func testTrailingSentencePunctuationIsStripped() {
        for p in [".", ",", ":", ";", "!", "?"] {
            XCTAssertEqual(click("see notes/plan.md\(p) next", on: "notes"),
                           .file(path: "/repo/notes/plan.md", line: nil), "trailing \(p)")
        }
    }

    func testBoldAndItalicMarkersAreStripped() {
        XCTAssertEqual(click("wrote **docs/plan.md** today", on: "docs"), .file(path: "/repo/docs/plan.md", line: nil))
        XCTAssertEqual(click("wrote _docs/plan.md_ today", on: "docs"), .file(path: "/repo/docs/plan.md", line: nil))
        XCTAssertEqual(click("wrote *docs/plan.md*.", on: "docs"), .file(path: "/repo/docs/plan.md", line: nil))
    }

    func testUnderscoresThatArePartOfTheNameSurvive() {
        XCTAssertEqual(click("open __init__.py", on: "__init"), .file(path: "/repo/__init__.py", line: nil))
    }

    func testBackticksAndQuotesAreStripped() {
        XCTAssertEqual(click("see `docs/plan.md`.", on: "docs"), .file(path: "/repo/docs/plan.md", line: nil))
        XCTAssertEqual(click("see \"docs/plan.md\"", on: "docs"), .file(path: "/repo/docs/plan.md", line: nil))
    }

    func testMarkdownLinkOpensTargetWhenClickingTarget() {
        XCTAssertEqual(click("read [Plan](docs/plan.md) first", on: "docs"),
                       .file(path: "/repo/docs/plan.md", line: nil))
    }

    func testMarkdownLinkOpensTargetWhenClickingLinkText() {
        XCTAssertEqual(click("read [Plan](docs/plan.md) first", on: "Plan"),
                       .file(path: "/repo/docs/plan.md", line: nil))
        XCTAssertEqual(click("read [The plan](docs/plan.md).", on: "The"),
                       .file(path: "/repo/docs/plan.md", line: nil))
    }

    func testMarkdownLinkWithWebTargetOpensURL() {
        XCTAssertEqual(click("[docs](https://example.com/x)", on: "docs"),
                       .url(URL(string: "https://example.com/x")!))
    }

    func testBoxDrawingTableBordersAreSeparators() {
        XCTAssertEqual(click("│docs/plan.md│ done │", on: "docs"), .file(path: "/repo/docs/plan.md", line: nil))
        XCTAssertEqual(click("│ docs/plan.md │ done │", on: "docs"), .file(path: "/repo/docs/plan.md", line: nil))
        XCTAssertEqual(click("| a.md | docs/plan.md |", on: "docs"), .file(path: "/repo/docs/plan.md", line: nil))
        XCTAssertNil(click("│docs/plan.md│ done │", on: "│", at: 0))
    }

    // MARK: spaces in paths

    func testPathWithSpacesMatchesWhenClickedOnAnyPart() {
        XCTAssertEqual(click("open My Notes/plan.md now", on: "Notes"),
                       .file(path: "/repo/My Notes/plan.md", line: nil))
        XCTAssertEqual(click("open My Notes/plan.md now", on: "My"),
                       .file(path: "/repo/My Notes/plan.md", line: nil))
    }

    func testBackslashEscapedSpacesMatch() {
        XCTAssertEqual(click(#"open My\ Notes/plan.md now"#, on: "Notes"),
                       .file(path: "/repo/My Notes/plan.md", line: nil))
    }

    // MARK: line numbers, ~, absolute, base dirs, directories

    func testPathLineAndColumnSuffixes() {
        XCTAssertEqual(click("Sources/main.swift:12", on: "main"), .file(path: "/repo/Sources/main.swift", line: 12))
        XCTAssertEqual(click("Sources/main.swift:12:5: error", on: "main"), .file(path: "/repo/Sources/main.swift", line: 12))
        XCTAssertEqual(click("at Sources/main.swift:12.", on: "main"), .file(path: "/repo/Sources/main.swift", line: 12))
    }

    func testTildeExpands() {
        let home = NSHomeDirectory()
        fs[home + "/notes.md"] = .file
        XCTAssertEqual(click("see ~/notes.md", on: "~"), .file(path: home + "/notes.md", line: nil))
    }

    func testAbsolutePathIgnoresBaseDirs() {
        XCTAssertEqual(click("see /abs/x.md", on: "/abs"), .file(path: "/abs/x.md", line: nil))
    }

    func testBaseDirsTriedInOrder() {
        fs["/cwd/a.md"] = .file
        XCTAssertEqual(click("a.md", on: "a.md", baseDirs: ["/cwd", "/repo"]), .file(path: "/cwd/a.md", line: nil))
        XCTAssertEqual(click("b.md", on: "b.md", baseDirs: ["/cwd", "/repo"]), .file(path: "/repo/b.md", line: nil))
    }

    func testDirectoryResolvesAsDirectory() {
        XCTAssertEqual(click("cd docs", on: "docs"), .directory(path: "/repo/docs"))
    }

    func testNonexistentPathIsNil() {
        XCTAssertNil(click("see missing.md", on: "missing"))
    }

    // MARK: URLs

    func testURLUnderClickWinsOnlyWhenClicked() {
        let line = "wrote a.md see https://example.com/x"
        XCTAssertEqual(click(line, on: "a.md"), .file(path: "/repo/a.md", line: nil))
        XCTAssertEqual(click(line, on: "https"), .url(URL(string: "https://example.com/x")!))
    }

    func testURLTrailingPunctuationIsStripped() {
        XCTAssertEqual(click("see https://example.com/x.", on: "example"), .url(URL(string: "https://example.com/x")!))
        XCTAssertEqual(click("(see localhost:3000)", on: "localhost"), .url(URL(string: "http://localhost:3000")!))
    }

    // MARK: OSC 8 hyperlinks

    func testHyperlinkWebURL() {
        XCTAssertEqual(resolveHyperlink("https://example.com/a", pathKind: { self.fs[$0] }),
                       .url(URL(string: "https://example.com/a")!))
    }

    func testHyperlinkFileURL() {
        XCTAssertEqual(resolveHyperlink("file:///repo/docs/plan.md", pathKind: { self.fs[$0] }),
                       .file(path: "/repo/docs/plan.md", line: nil))
        XCTAssertEqual(resolveHyperlink("file://my-mac.local/repo/docs", pathKind: { self.fs[$0] }),
                       .directory(path: "/repo/docs"))
        XCTAssertEqual(resolveHyperlink("file:///repo/My%20Notes/plan.md", pathKind: { self.fs[$0] }),
                       .file(path: "/repo/My Notes/plan.md", line: nil))
    }

    func testHyperlinkMissingFileIsNil() {
        XCTAssertNil(resolveHyperlink("file:///repo/nope.md", pathKind: { self.fs[$0] }))
        XCTAssertNil(resolveHyperlink("", pathKind: { self.fs[$0] }))
    }

    // MARK: logical line (wrapped rows)

    private func row(_ s: String, wrapped: Bool = false) -> TerminalRowText {
        TerminalRowText(cells: s.map { Optional($0) }, continuesPrevious: wrapped)
    }

    func testWrappedRowsJoinIntoOneLogicalLine() {
        let rows = [row("$ ls"), row("see docs/pl"), row("an.md now", wrapped: true), row("next")]
        let hit = logicalLine(rows: rows, row: 2, column: 1)
        XCTAssertEqual(hit?.text, "see docs/plan.md now")
        XCTAssertEqual(hit?.offset, 12)   // the "n" of "an.md"
        let hitTop = logicalLine(rows: rows, row: 1, column: 4)
        XCTAssertEqual(hitTop?.text, "see docs/plan.md now")
        XCTAssertEqual(hitTop?.offset, 4)
    }

    func testUnwrappedRowStandsAlone() {
        let rows = [row("first"), row("second"), row("third")]
        XCTAssertEqual(logicalLine(rows: rows, row: 1, column: 2)?.text, "second")
        XCTAssertEqual(logicalLine(rows: rows, row: 1, column: 2)?.offset, 2)
    }

    func testWideCharContinuationCellsMapToTheirCharacter() {
        // "日" occupies two columns; the second is a continuation cell (nil).
        let rows = [TerminalRowText(cells: ["日", nil, " ", "a", ".", "m", "d"], continuesPrevious: false)]
        XCTAssertEqual(logicalLine(rows: rows, row: 0, column: 1)?.offset, 0)
        XCTAssertEqual(logicalLine(rows: rows, row: 0, column: 3)?.offset, 2)
        XCTAssertEqual(logicalLine(rows: rows, row: 0, column: 3)?.text, "日 a.md")
    }

    func testLogicalLineOutOfRangeIsNil() {
        XCTAssertNil(logicalLine(rows: [row("x")], row: 3, column: 0))
        XCTAssertNil(logicalLine(rows: [row("x")], row: 0, column: 5))
    }

    func testEndToEndWrappedPathResolves() {
        let rows = [row("wrote docs/p"), row("lan.md.", wrapped: true)]
        let hit = logicalLine(rows: rows, row: 1, column: 2)!
        XCTAssertEqual(resolveClickTarget(line: hit.text, offset: hit.offset, baseDirs: [base],
                                          pathKind: { self.fs[$0] }),
                       .file(path: "/repo/docs/plan.md", line: nil))
    }
}
