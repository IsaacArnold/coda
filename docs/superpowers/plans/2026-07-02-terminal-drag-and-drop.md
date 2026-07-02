# Terminal Drag-and-Drop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users drag files (incl. images), text, and URLs from other apps onto a Coda terminal pane to insert them at the cursor — files as escaped absolute paths, text/URLs verbatim.

**Architecture:** Pure, unit-tested decision + escaping logic lives in `CodaCore/TerminalDrop.swift`. The AppKit `NSDraggingDestination` glue lives in `Coda/ClickableTerminalView.swift` (the existing `LocalProcessTerminalView` subclass): it reads the pasteboard, calls `TerminalDrop.dropText(...)`, and sends the result to the PTY (bracketed-paste-wrapped when the terminal has bracketed paste on).

**Tech Stack:** Swift, AppKit, SwiftTerm (vendored via SwiftPM), swift-testing/XCTest as already used in `Tests/CodaCoreTests`.

## Global Constraints

- Pure logic goes in `Sources/CodaCore` with tests in `Tests/CodaCoreTests`; AppKit/UI glue goes in `Sources/Coda` (no unit tests for AppKit drag plumbing — it is verified by build + manual drag).
- `CodaCore` must not import AppKit. `TerminalDrop` uses only `Foundation` (`URL`).
- File paths inserted for file drops are **absolute** (`URL.path`), backslash-escaped, space-joined, **no trailing space**, **no trailing newline** (never auto-executes).
- Escaping: backslash-escape each **ASCII** character that is not in the safe set `[A-Za-z0-9._/+-]`; leave non-ASCII scalars and multi-scalar graphemes unescaped.
- Content priority for a single drop: file URLs → escaped paths; else non-file URL → `absoluteString`; else string → verbatim; else reject.
- SwiftTerm APIs available (all `public`): `send(txt:)`, `send(data: ArraySlice<UInt8>)`, `getTerminal()`, `getTerminal().bracketedPasteMode`, `EscapeSequences.bracketedPasteStart`, `EscapeSequences.bracketedPasteEnd`.

---

### Task 1: `shellEscape` in CodaCore

**Files:**
- Create: `Sources/CodaCore/TerminalDrop.swift`
- Test: `Tests/CodaCoreTests/TerminalDropTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public enum TerminalDrop { public static func shellEscape(_ path: String) -> String }`

- [ ] **Step 1: Write the failing test**

Create `Tests/CodaCoreTests/TerminalDropTests.swift`. Match the test style already used in that directory (the other files use `XCTest`; use `XCTestCase`):

```swift
import XCTest
@testable import CodaCore

final class TerminalDropTests: XCTestCase {
    func testShellEscapeLeavesSafePathUnchanged() {
        XCTAssertEqual(TerminalDrop.shellEscape("/Users/isaac/file_1.txt"), "/Users/isaac/file_1.txt")
    }

    func testShellEscapeEscapesSpacesAndSpecials() {
        XCTAssertEqual(TerminalDrop.shellEscape("/a b/c(d).txt"), "/a\\ b/c\\(d\\).txt")
        XCTAssertEqual(TerminalDrop.shellEscape("/x&y$z;q*.log"), "/x\\&y\\$z\\;q\\*.log")
        XCTAssertEqual(TerminalDrop.shellEscape("/it's \"here\""), "/it\\'s\\ \\\"here\\\"")
    }

    func testShellEscapeLeavesNonASCIIUnescaped() {
        XCTAssertEqual(TerminalDrop.shellEscape("/tmp/café/x.txt"), "/tmp/café/x.txt")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TerminalDropTests`
Expected: FAIL — compile error, `TerminalDrop` is undefined.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/CodaCore/TerminalDrop.swift`:

```swift
import Foundation

/// Pure logic for turning a drag-and-drop payload into text to insert into the terminal.
/// No AppKit / no pasteboard access — the AppKit glue lives in `ClickableTerminalView`.
public enum TerminalDrop {
    /// ASCII characters that never need escaping in a POSIX shell.
    private static let safeASCII = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/+-")

    /// Backslash-escape each ASCII character that isn't in `safeASCII`. Non-ASCII scalars
    /// (accented letters, emoji, …) are left as-is — a backslash before them is pointless
    /// and only makes the inserted text ugly; they aren't shell-special.
    public static func shellEscape(_ path: String) -> String {
        var out = ""
        out.reserveCapacity(path.count)
        for ch in path {
            if needsEscape(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    private static func needsEscape(_ ch: Character) -> Bool {
        let scalars = ch.unicodeScalars
        guard scalars.count == 1, let s = scalars.first, s.value < 128 else { return false }
        return !safeASCII.contains(ch)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TerminalDropTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CodaCore/TerminalDrop.swift Tests/CodaCoreTests/TerminalDropTests.swift
git commit -m "feat(core): add TerminalDrop.shellEscape for drag-and-drop paths"
```

---

### Task 2: `dropText` content-priority in CodaCore

**Files:**
- Modify: `Sources/CodaCore/TerminalDrop.swift`
- Test: `Tests/CodaCoreTests/TerminalDropTests.swift`

**Interfaces:**
- Consumes: `TerminalDrop.shellEscape(_:)` from Task 1.
- Produces: `public static func dropText(fileURLs: [URL], text: String?, url: URL?) -> String?`
  - Returns the exact string to insert at the cursor, or `nil` when there is nothing insertable.

- [ ] **Step 1: Write the failing test**

Append to `Tests/CodaCoreTests/TerminalDropTests.swift`:

```swift
extension TerminalDropTests {
    func testDropTextSingleFile() {
        let u = URL(fileURLWithPath: "/a b/c.txt")
        XCTAssertEqual(TerminalDrop.dropText(fileURLs: [u], text: nil, url: nil), "/a\\ b/c.txt")
    }

    func testDropTextMultipleFilesSpaceJoinedNoTrailingSpace() {
        let a = URL(fileURLWithPath: "/x/one.txt")
        let b = URL(fileURLWithPath: "/y/t wo.txt")
        XCTAssertEqual(TerminalDrop.dropText(fileURLs: [a, b], text: nil, url: nil),
                       "/x/one.txt /y/t\\ wo.txt")
    }

    func testDropTextFilesBeatUrlAndString() {
        let f = URL(fileURLWithPath: "/f.txt")
        let web = URL(string: "https://example.com")!
        XCTAssertEqual(TerminalDrop.dropText(fileURLs: [f], text: "ignored", url: web), "/f.txt")
    }

    func testDropTextUrlWhenNoFiles() {
        let web = URL(string: "https://example.com/path?q=1")!
        XCTAssertEqual(TerminalDrop.dropText(fileURLs: [], text: "ignored", url: web),
                       "https://example.com/path?q=1")
    }

    func testDropTextStringWhenNoFilesOrUrl() {
        XCTAssertEqual(TerminalDrop.dropText(fileURLs: [], text: "hello world", url: nil), "hello world")
    }

    func testDropTextNilWhenEmpty() {
        XCTAssertNil(TerminalDrop.dropText(fileURLs: [], text: nil, url: nil))
        XCTAssertNil(TerminalDrop.dropText(fileURLs: [], text: "", url: nil))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TerminalDropTests`
Expected: FAIL — compile error, `dropText` is undefined.

- [ ] **Step 3: Write minimal implementation**

Add to `TerminalDrop` in `Sources/CodaCore/TerminalDrop.swift`:

```swift
    /// Decide what to insert for a drop. Priority: file URLs (escaped absolute paths,
    /// space-joined) → non-file URL (`absoluteString`) → plain text (verbatim). Returns
    /// nil when nothing is insertable.
    public static func dropText(fileURLs: [URL], text: String?, url: URL?) -> String? {
        if !fileURLs.isEmpty {
            return fileURLs.map { shellEscape($0.path) }.joined(separator: " ")
        }
        if let url { return url.absoluteString }
        if let text, !text.isEmpty { return text }
        return nil
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TerminalDropTests`
Expected: PASS (9 tests total).

- [ ] **Step 5: Commit**

```bash
git add Sources/CodaCore/TerminalDrop.swift Tests/CodaCoreTests/TerminalDropTests.swift
git commit -m "feat(core): add TerminalDrop.dropText content-priority logic"
```

---

### Task 3: Wire drag-and-drop into ClickableTerminalView

**Files:**
- Modify: `Sources/Coda/ClickableTerminalView.swift`

**Interfaces:**
- Consumes: `TerminalDrop.dropText(fileURLs:text:url:)` and `TerminalDrop.shellEscape(_:)` from Tasks 1–2; SwiftTerm's `send(txt:)`, `send(data:)`, `getTerminal().bracketedPasteMode`, `EscapeSequences.bracketedPasteStart/End`.
- Produces: `ClickableTerminalView` now accepts file/text/URL drops. No new public API consumed by other Coda code.

- [ ] **Step 1: Add drag registration, highlight state, and the NSDraggingDestination methods**

In `Sources/Coda/ClickableTerminalView.swift`, add this block inside the `ClickableTerminalView` class body (e.g. just after the `outputSinceLastPoll` machinery, before `performKeyEquivalent`):

```swift
    // MARK: - Drag & drop (iTerm-style file/text/URL drop)

    /// True while a valid drag hovers this pane; drives the drop highlight in `draw`.
    private var isDragHighlighted = false {
        didSet { if isDragHighlighted != oldValue { needsDisplay = true } }
    }

    /// Register the pasteboard types we accept once the view is in a window. Done here
    /// (rather than in an initializer) to avoid overriding SwiftTerm's init chain;
    /// re-registering on each window move is harmless.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    /// Pull the insertable string out of a drag's pasteboard, or nil if there's nothing
    /// we handle. File URLs win; then a non-file URL; then plain text.
    private func droppedText(_ sender: NSDraggingInfo) -> String? {
        let pb = sender.draggingPasteboard
        let fileURLs = (pb.readObjects(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        var url: URL?
        if fileURLs.isEmpty,
           let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first, !first.isFileURL {
            url = first
        }
        let text = pb.string(forType: .string)
        return TerminalDrop.dropText(fileURLs: fileURLs, text: text, url: url)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard droppedText(sender) != nil else { return [] }
        isDragHighlighted = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return droppedText(sender) != nil ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragHighlighted = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDragHighlighted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragHighlighted = false
        guard let text = droppedText(sender) else { return false }
        sendDroppedText(text)
        return true
    }

    /// Send dropped text to the PTY. Mirrors SwiftTerm's own paste: when bracketed-paste
    /// mode is on, wrap the payload so a multi-line text drop can't auto-run lines.
    private func sendDroppedText(_ text: String) {
        if getTerminal().bracketedPasteMode {
            send(data: EscapeSequences.bracketedPasteStart[0...])
            send(txt: text)
            send(data: EscapeSequences.bracketedPasteEnd[0...])
        } else {
            send(txt: text)
        }
    }

    /// Draw the drop highlight on top of the terminal contents when a drag is over us.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isDragHighlighted else { return }
        let inset = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: inset, xRadius: 4, yRadius: 4)
        path.lineWidth = 3
        NSColor.keyboardFocusIndicatorColor.setStroke()
        path.stroke()
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors. (If the compiler complains that `draggingEntered`/etc. are not overrides on this base class, remove `override` from the flagged NSDraggingDestination method; `viewDidMoveToWindow`/`draw` remain `override`.)

- [ ] **Step 3: Run the full test suite**

Run: `swift test`
Expected: all existing tests plus the 9 `TerminalDropTests` pass; nothing regresses.

- [ ] **Step 4: Manual verification (drag-and-drop end-to-end)**

Build and launch the app (per the project's run flow), then in a terminal pane:
1. Drag a file with a space in its name from Finder → drop → the escaped absolute path appears at the cursor, no trailing newline, prompt does not execute.
2. Drag an image file → its path appears (not a rendered image).
3. Drag 2+ files at once → paths appear space-separated, no trailing space.
4. Drag a URL from Safari's address bar → the URL string appears.
5. Select text in Notes and drag it in → the text appears.
6. While dragging over a pane, confirm the focus-ring highlight shows and clears on exit/drop.
7. With two split panes, drop onto each and confirm the text lands in the pane under the cursor.

Note any deviation; if all pass, proceed.

- [ ] **Step 5: Commit**

```bash
git add Sources/Coda/ClickableTerminalView.swift
git commit -m "feat(terminal): drag-and-drop files, text, and URLs into a pane"
```

---

## Self-Review

- **Spec coverage:** file drop → escaped abs paths (Tasks 1–3 ✓); text/URL verbatim (Task 2 ✓); priority files>url>string (Task 2 ✓); no trailing space/newline (Task 2 test + Task 3 ✓); drag highlight (Task 3 ✓); per-pane targeting (per-view registration in Task 3 ✓); bracketed-paste-aware insertion (Task 3 ✓); pure-core/AppKit split (Tasks 1–2 in CodaCore, Task 3 in Coda ✓). Out-of-scope items (scp upload, modifier keys, inline rendering) intentionally absent.
- **Placeholder scan:** none — all steps carry real code and exact commands.
- **Type consistency:** `shellEscape(_:)` and `dropText(fileURLs:text:url:)` signatures match across Tasks 1–3; `sendDroppedText`/`droppedText` are private and self-consistent.
