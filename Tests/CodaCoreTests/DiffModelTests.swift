import XCTest
@testable import CodaCore

final class DiffModelTests: XCTestCase {
    func testParsesModifiedFileWithOneHunk() {
        let patch = """
        diff --git a/foo.txt b/foo.txt
        index e69de29..b6fc4c6 100644
        --- a/foo.txt
        +++ b/foo.txt
        @@ -1,2 +1,2 @@
         context line
        -old line
        +new line
        """
        let files = parseUnifiedDiff(patch)
        XCTAssertEqual(files.count, 1)
        let f = files[0]
        XCTAssertEqual(f.path, "foo.txt")
        XCTAssertEqual(f.kind, .modified)
        XCTAssertFalse(f.isBinary)
        XCTAssertEqual(f.hunks.count, 1)
        XCTAssertEqual(f.hunks[0].lines, [
            DiffLine(kind: .context, text: "context line"),
            DiffLine(kind: .deletion, text: "old line"),
            DiffLine(kind: .addition, text: "new line"),
        ])
        XCTAssertEqual(f.insertions, 1)
        XCTAssertEqual(f.deletions, 1)
    }

    func testParsesAddedFile() {
        let patch = """
        diff --git a/new.txt b/new.txt
        new file mode 100644
        index 0000000..3b18e51
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,1 @@
        +hello
        """
        let f = parseUnifiedDiff(patch)[0]
        XCTAssertEqual(f.kind, .added)
        XCTAssertEqual(f.path, "new.txt")
        XCTAssertEqual(f.insertions, 1)
        XCTAssertEqual(f.deletions, 0)
    }

    func testParsesDeletedFile() {
        let patch = """
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index 3b18e51..0000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1,1 +0,0 @@
        -bye
        """
        let f = parseUnifiedDiff(patch)[0]
        XCTAssertEqual(f.kind, .deleted)
        XCTAssertEqual(f.path, "gone.txt")
        XCTAssertEqual(f.deletions, 1)
    }

    func testParsesRename() {
        let patch = """
        diff --git a/old/name.txt b/new/name.txt
        similarity index 100%
        rename from old/name.txt
        rename to new/name.txt
        """
        let f = parseUnifiedDiff(patch)[0]
        XCTAssertEqual(f.kind, .renamed)
        XCTAssertEqual(f.oldPath, "old/name.txt")
        XCTAssertEqual(f.path, "new/name.txt")
    }

    func testParsesBinaryFile() {
        let patch = """
        diff --git a/img.png b/img.png
        index 1234567..89abcde 100644
        Binary files a/img.png and b/img.png differ
        """
        let f = parseUnifiedDiff(patch)[0]
        XCTAssertTrue(f.isBinary)
        XCTAssertEqual(f.path, "img.png")
        XCTAssertTrue(f.hunks.isEmpty)
    }

    func testParsesMultipleFilesAndMultipleHunks() {
        let patch = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1,1 +1,1 @@
        -a
        +A
        @@ -10,1 +10,1 @@
        -b
        +B
        diff --git a/c.txt b/c.txt
        --- a/c.txt
        +++ b/c.txt
        @@ -1,0 +1,1 @@
        +c
        """
        let files = parseUnifiedDiff(patch)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].hunks.count, 2)
        XCTAssertEqual(files[0].insertions, 2)
        XCTAssertEqual(files[1].path, "c.txt")
    }

    func testIgnoresNoNewlineMarker() {
        let patch = """
        diff --git a/n.txt b/n.txt
        --- a/n.txt
        +++ b/n.txt
        @@ -1,1 +1,1 @@
        -a
        +b
        \\ No newline at end of file
        """
        let f = parseUnifiedDiff(patch)[0]
        XCTAssertEqual(f.hunks[0].lines, [
            DiffLine(kind: .deletion, text: "a"),
            DiffLine(kind: .addition, text: "b"),
        ])
    }

    func testParsesUnquotedNonASCIIPath() {
        // git's default core.quotePath=true would octal-escape this path (e.g. "a/caf\303\251.txt"),
        // which the `" b/"` split in parseUnifiedDiff cannot handle. With core.quotePath=false
        // (which GitWorktree now passes), the header comes through unquoted, like this:
        let patch = """
        diff --git a/café.txt b/café.txt
        index e69de29..b6fc4c6 100644
        --- a/café.txt
        +++ b/café.txt
        @@ -1,1 +1,1 @@
        -old
        +new
        """
        let files = parseUnifiedDiff(patch)
        XCTAssertEqual(files.count, 1)
        let f = files[0]
        XCTAssertEqual(f.path, "café.txt")
        XCTAssertEqual(f.kind, .modified)
        XCTAssertEqual(f.insertions, 1)
        XCTAssertEqual(f.deletions, 1)
    }

    func testEmptyAndMalformedAreSafe() {
        XCTAssertTrue(parseUnifiedDiff("").isEmpty)
        XCTAssertTrue(parseUnifiedDiff("not a diff at all\njust text").isEmpty)
    }

    func testIsLargeDiff() {
        let big = DiffFile(path: "x", oldPath: nil, kind: .modified, isBinary: false,
            hunks: [DiffHunk(header: "@@",
                lines: Array(repeating: DiffLine(kind: .addition, text: "x"), count: 2_001))])
        XCTAssertTrue(isLargeDiff(big))
        let small = DiffFile(path: "y", oldPath: nil, kind: .modified, isBinary: false, hunks: [])
        XCTAssertFalse(isLargeDiff(small))
    }
}
