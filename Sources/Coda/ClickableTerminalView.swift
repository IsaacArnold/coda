import AppKit
import SwiftTerm
import CodaCore

/// A LocalProcessTerminalView that adds iTerm-style ⌘+click-to-open-file.
///
/// SwiftTerm's built-in link detection only recognizes URLs, so file paths like
/// `Sources/main.swift:12` are handled here: on a ⌘-click we read the clicked line
/// out of the terminal buffer, pull a path-like token from it, resolve it against
/// the worktree dir, and hand it to `onOpenFile` (which routes to the default editor).
final class ClickableTerminalView: LocalProcessTerminalView {
    /// cwd to resolve relative paths against (the worktree directory).
    var fallbackDirectory: String = FileManager.default.currentDirectoryPath
    /// Latest cwd reported by the shell via OSC 7, when available.
    var currentDirectory: String?
    /// Opens a resolved file (absolute path) at an optional line in the default editor.
    var onOpenFile: ((String, Int?) -> Void)?
    /// Fired when this terminal becomes first responder (click or programmatic focus),
    /// so the owning SplitSurface can mark this pane focused.
    var onBecomeFirstResponder: (() -> Void)?
    override var hasFocus: Bool {
        didSet {
            if hasFocus != oldValue, hasFocus { onBecomeFirstResponder?() }
        }
    }

    /// True when the PTY has delivered output since the agent-state poll last consumed it.
    /// Starts true so the first poll classifies every pane. Touched only on the main thread
    /// — SwiftTerm's `LocalProcess` posts `dataReceived` on `DispatchQueue.main` — so a plain
    /// Bool is race-free against the poll.
    private var outputSinceLastPoll = true

    /// Records that the shell produced output, then feeds it to the terminal as usual. The
    /// agent-state poll uses this to skip re-snapshotting panes whose grid hasn't changed.
    override func dataReceived(slice: ArraySlice<UInt8>) {
        outputSinceLastPoll = true
        super.dataReceived(slice: slice)
    }

    /// Whether new output has arrived since the previous call; resets the flag.
    func consumeOutputSinceLastPoll() -> Bool {
        defer { outputSinceLastPoll = false }
        return outputSinceLastPoll
    }

    // MARK: - Drag & drop (iTerm-style file/text/URL drop)

    /// True while a valid drag hovers this pane; toggles the drop-highlight overlay.
    private var isDragHighlighted = false {
        didSet {
            guard isDragHighlighted != oldValue else { return }
            if isDragHighlighted, dropHighlight.superview == nil {
                dropHighlight.frame = bounds
                addSubview(dropHighlight)
            }
            dropHighlight.isHidden = !isDragHighlighted
        }
    }

    /// Transparent overlay drawn on top of the terminal to show the drop target. Used
    /// because SwiftTerm's `TerminalView.draw(_:)` is `public` (not `open`) and so can't
    /// be overridden from this module.
    private lazy var dropHighlight: DropHighlightOverlay = {
        let v = DropHighlightOverlay(frame: bounds)
        v.autoresizingMask = [.width, .height]
        v.isHidden = true
        return v
    }()

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

    /// Give a focused terminal first crack at ⌘-combos it owns (clear, line-kill) before
    /// the main menu's key-equivalents see them — otherwise e.g. ⌘⌫ would hit the menu's
    /// "Archive Worktree". AppKit consults a view's `performKeyEquivalent` ahead of the
    /// menu, so consuming the event here (returning true) keeps it out of the menu; passing
    /// through (returning false) lets the menu act, including when another view is focused.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, isFocusedSurface else {
            return super.performKeyEquivalent(with: event)
        }
        let mods = event.modifierFlags
        switch terminalKeyAction(charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                                 command: mods.contains(.command), shift: mods.contains(.shift)) {
        case .clear:
            // Clear the emulator directly so it's instant and independent of shell state.
            // Ctrl-L alone only redraws the viewport once the shell is next idle (so it
            // lags behind a busy shell) and never touches scrollback (so old output
            // survives a scroll-up). \e[3J trims scrollback, \e[2J clears the screen,
            // \e[H homes the cursor.
            feed(text: "\u{1b}[3J\u{1b}[2J\u{1b}[H")
            // \e[3J trims scrollback, but SwiftTerm's feed() path never refreshes the
            // scroller — so the scroll bar lingers as if the history were still there.
            // Re-asserting the current scrollback size forces updateScroller() to recompute
            // canScroll/knob; it's a no-op on buffer contents (same size => nothing trimmed).
            changeScrollback(getTerminal().options.scrollback)
            // Nudge the shell to reprint its prompt on the now-empty screen.
            send(txt: "\u{0c}")
            return true
        case .deleteToLineStart:
            send(txt: "\u{15}")          // Ctrl-U: kill input line back to the prompt
            return true
        case .passThrough, .insertNewline:
            return super.performKeyEquivalent(with: event)
        }
    }

    /// Send a soft newline (LF, 0x0a — Claude Code's chat:newline) to the PTY. Called by the
    /// app-level key monitor for ⌘/⇧/⌥+Enter: SwiftTerm seals `keyDown` (public, not open),
    /// so these combos can't be intercepted by overriding keyDown on the terminal view.
    func sendSoftNewline() {
        send(data: [UInt8(0x0a)][0...])
    }

    /// True only for the visible terminal that currently holds keyboard focus — AppKit
    /// calls `performKeyEquivalent` on every view in the window, including hidden surfaces.
    private var isFocusedSurface: Bool {
        guard !isHiddenOrHasHiddenAncestor, let window, window.isKeyWindow,
              let responder = window.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    /// Whether `event`'s location falls inside this (visible) terminal. Used to gate
    /// the app's ⌘+click monitor so it only acts on the focused surface.
    func containsClick(_ event: NSEvent) -> Bool {
        guard !isHiddenOrHasHiddenAncestor, window != nil else { return false }
        return bounds.contains(convert(event.locationInWindow, from: nil))
    }

    /// Called by the app's ⌘+click monitor (SwiftTerm's `mouseDown`/`requestOpenLink`
    /// are `public` but not `open`, so we can't override them). Returns true if it
    /// opened something.
    @discardableResult
    func handleCommandClick(_ event: NSEvent) -> Bool {
        guard containsClick(event) else { return false }
        let point = convert(event.locationInWindow, from: nil)

        let term = getTerminal()
        let cols = term.cols, rows = term.rows
        guard rows > 0, cols > 0, bounds.height > 0 else { return false }

        let cellHeight = bounds.height / CGFloat(rows)
        let yFromTop = isFlipped ? point.y : (bounds.height - point.y)
        let screenRow = max(0, min(rows - 1, Int(yFromTop / cellHeight)))

        // Scan the clicked row plus neighbors: row math is approximate and a path can
        // wrap. Assumes no scrollback offset (screen row == buffer row).
        for dr in [0, -1, 1] {
            let rr = screenRow + dr
            guard rr >= 0, rr < rows else { continue }
            let line = term.getText(start: Position(col: 0, row: rr),
                                    end: Position(col: cols - 1, row: rr))
            if let (path, lineNo) = resolvePath(in: line) {
                onOpenFile?(path, lineNo)
                return true
            }
            if let url = firstURL(in: line) {
                NSWorkspace.shared.open(url)
                return true
            }
        }
        return false
    }

    private var baseDirs: [String] {
        var dirs: [String] = []
        if let cwd = currentDirectory {
            if cwd.hasPrefix("file://"), let u = URL(string: cwd) {
                dirs.append(u.path)
            } else {
                dirs.append((cwd as NSString).removingPercentEncoding ?? cwd)
            }
        }
        dirs.append(fallbackDirectory)
        return dirs
    }

    /// First token on the line that resolves to a file that exists. Supports
    /// `path`, `path:line`, and `path:line:col`.
    private func resolvePath(in line: String) -> (path: String, line: Int?)? {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        for raw in tokens {
            var token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'(),[]{}<>"))
            if let r = token.range(of: "\\") { token = String(token[..<r.lowerBound]) }
            if token.isEmpty { continue }

            let parts = token.split(separator: ":", maxSplits: 2).map(String.init)
            let pathPart = parts[0]
            let lineNo = parts.count > 1 ? Int(parts[1]) : nil

            let expanded = (pathPart as NSString).expandingTildeInPath
            let candidates = expanded.hasPrefix("/")
                ? [expanded]
                : baseDirs.map { ($0 as NSString).appendingPathComponent(expanded) }
            for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
                return (candidate, lineNo)
            }
        }
        return nil
    }

    private func firstURL(in line: String) -> URL? {
        for raw in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'(),[]{}<>"))
            if token.hasPrefix("http://") || token.hasPrefix("https://"), let url = URL(string: token) {
                return url
            }
        }
        return nil
    }
}

/// Non-interactive overlay that strokes a focus-ring border while a drag hovers the
/// terminal. `hitTest` returns nil so it never intercepts the drop or any mouse event.
private final class DropHighlightOverlay: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: inset, xRadius: 4, yRadius: 4)
        path.lineWidth = 3
        NSColor.keyboardFocusIndicatorColor.setStroke()
        path.stroke()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
