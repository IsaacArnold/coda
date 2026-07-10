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

    /// Fired (main thread) after the terminal absorbs a chunk of PTY output, so the completion
    /// controller can re-read the command line — output can change what's on the prompt line
    /// (e.g. shell autosuggestions, a redraw) without a keystroke passing through Coda. Unset
    /// it's a no-op; wired by `TerminalSurface` only when completions are enabled.
    var onOutput: (() -> Void)?

    /// Records that the shell produced output, then feeds it to the terminal as usual. The
    /// agent-state poll uses this to skip re-snapshotting panes whose grid hasn't changed.
    override func dataReceived(slice: ArraySlice<UInt8>) {
        outputSinceLastPoll = true
        // SwiftTerm yanks the viewport back to the live bottom on every new line: its
        // `Terminal.scroll()` forces `yDisp = yBase` unless an internal `userScrolling` flag
        // is set — and that flag is never set anywhere (and is module-internal, so we can't
        // set it either). The upshot is that scrolling up to read history is interrupted the
        // instant the agent prints another line. Capture the scroll state before feeding, and
        // if the user had scrolled up, restore their top row afterward so live output no
        // longer steals the viewport. When the buffer is trimmed (full scrollback) the content
        // shifts by the trimmed count and this drifts by that much — still vastly better than
        // snapping to the bottom, and exact in the common not-yet-full case.
        let wasScrolledUp = !isScrolledToBottom
        let savedTopRow = getTerminal().getTopVisibleRow()
        super.dataReceived(slice: slice)
        // Both the `super` feed (which pinned to the bottom) and this restore mark the view
        // dirty within one synchronous main-thread call, so AppKit coalesces them into a
        // single redraw at the live scroll position — no flash of the bottom.
        if wasScrolledUp {
            scrollTo(row: savedTopRow)
        }
        // After `super` so the buffer reflects this chunk before the controller reads it.
        onOutput?()
    }

    /// True when the running program has turned on any-event mouse tracking (DECSET 1003), i.e.
    /// SwiftTerm will stream pointer *motion* (not just clicks) to the PTY. Claude Code's TUI uses
    /// those motion reports to move its selection to follow the cursor, so a plain hover "selects"
    /// an option. SwiftTerm's `mouseMoved` is `public` (not `open`), so we can't override it on the
    /// view; the app-level hover monitor consults this to swallow those hover events instead.
    var isReportingMouseMotion: Bool {
        getTerminal().mouseMode.sendMotionEvent()
    }

    /// Whether new output has arrived since the previous call; resets the flag.
    func consumeOutputSinceLastPoll() -> Bool {
        defer { outputSinceLastPoll = false }
        return outputSinceLastPoll
    }

    // MARK: - Drag & drop (iTerm-style file/text/URL drop)

    // MARK: - Prompt phase (OSC 133)

    /// Pure reduction of OSC 133 markers to a prompt phase. Fed exclusively from the OSC 133
    /// handler registered in `viewDidMoveToWindow`, which runs on the main thread (SwiftTerm's
    /// `LocalProcess` posts `dataReceived` on `DispatchQueue.main`, same reasoning as
    /// `outputSinceLastPoll` above) — so this is race-free as a plain stored property.
    private var phaseMachine = PromptPhaseMachine()
    /// Current shell phase, kept in sync with `phaseMachine.phase` after every marker.
    private(set) var promptPhase: PromptPhase = .unknown
    /// Exit code of the most recently finished command (from the `D;<code>` marker), if any.
    var lastCommandExitCode: Int? { phaseMachine.lastCommandExitCode }
    /// Fired when `promptPhase` changes (i.e. on a real transition, not every marker). The
    /// completion controller (a later task) wires this up; unset here it's a no-op.
    var onPromptPhaseChange: ((PromptPhase) -> Void)?
    /// Guards one-time OSC 133 registration in `viewDidMoveToWindow` (mirrors the drag-type
    /// registration below, which is safe to redo but doesn't need to be).
    private var didRegisterOsc133 = false

    /// Where the editable command line begins, captured at the OSC 133 `B` marker (command
    /// start — the shell is ready for input). `col` is 0-based; `absRow` is an ABSOLUTE buffer
    /// row (scrollback + screen), so it stays valid as the screen scrolls. The `B` sequence is
    /// emitted at the very END of the zsh PS1 (a zero-width `%{…%}` wrap), so at consume-time the
    /// cursor sits exactly where typed input begins. Cleared to `nil` on `C`/`D` (a command
    /// started running / finished) so a stale anchor from a previous prompt is never read.
    /// Main-thread-only, same reasoning as `phaseMachine`.
    private(set) var commandStart: (col: Int, absRow: Int)?

    /// Registers the OSC 133 handler once the terminal exists. The parser splits the OSC
    /// string on the first `;`, so for `ESC ] 133 ; A BEL` the handler receives `"A"`, and for
    /// `ESC ] 133 ; D ; 0 BEL` it receives `"D;0"` — exactly the payload `PromptPhaseMachine`
    /// expects, so it's passed straight through with no re-splitting.
    private func registerOsc133Handler() {
        getTerminal().registerOscHandler(code: 133) { [weak self] data in
            guard let self else { return }
            let payload = String(decoding: data, as: UTF8.self)
            let old = self.promptPhase
            self.phaseMachine.consume(payload)
            let new = self.phaseMachine.phase
            self.promptPhase = new
            // Capture/clear the command-start anchor from the raw marker letter — this must
            // happen even when the phase doesn't transition (a `B` after an `A` both read
            // `.atPrompt`, yet `B` is the marker that pins where input begins), so it's done
            // before the transition-only early-return below.
            switch payload.first {
            case "B":
                let b = self.getTerminal().buffer
                self.commandStart = (col: b.x, absRow: self.getTerminal().getTopVisibleRow() + b.y)
            case "C", "D":
                self.commandStart = nil
            default:
                break
            }
            guard new != old else { return }
            if ProcessInfo.processInfo.environment["CODA_DEBUG_OSC133"] != nil {
                print("[osc133] \(old) → \(new) payload=\(payload) exit=\(String(describing: self.phaseMachine.lastCommandExitCode))")
            }
            self.onPromptPhaseChange?(new)
        }
    }

    // MARK: - Cursor cell / scroll accessors (for the completion popup, a later task)

    /// The live cursor position: 0-based column and screen-relative row (0..<rows), i.e. NOT
    /// adjusted for scrollback — matches what `cursorCellToViewPoint` expects.
    var cursorCell: (col: Int, row: Int) {
        let b = getTerminal().buffer
        return (b.x, b.y)
    }

    /// True when the viewport is showing the live bottom of the buffer (no scrollback, or
    /// scrolled all the way down) — i.e. `cursorCell` is trustworthy against the visible grid.
    var isScrolledToBottom: Bool {
        !canScroll || scrollPosition >= 1.0
    }

    /// Reads the editable command line from the command-start anchor up to the cursor, for the
    /// completion controller to classify. Returns `nil` (silent-off — never a popup, never a
    /// crash) whenever the buffer math can't be trusted:
    /// - not `.atPrompt`, no anchor, or scrolled off the live bottom (the anchor's absolute-row
    ///   arithmetic only holds at the bottom, same constraint as `cursorCell`);
    /// - **v1 single-row limitation:** the cursor has moved off the anchor's row (a wrapped or
    ///   multi-line command). Reading a spanning region would need per-row reconstruction; until
    ///   then, wrapped commands simply get no completions rather than a wrong one.
    ///
    /// On success returns `(line, cursorOffset)` where `line` is the text strictly before the
    /// cursor (so `cursorOffset == line.count`) — `resolveCompletion` classifies up to the cursor.
    func commandLineToCursor() -> (line: String, cursorOffset: Int)? {
        guard promptPhase == .atPrompt, let anchor = commandStart, isScrolledToBottom else {
            return nil
        }
        let term = getTerminal()
        let b = term.buffer
        let cursorAbsRow = term.getTopVisibleRow() + b.y
        let cursorCol = b.x
        // Single-row only for v1: a wrapped/multi-line command reads as no completions.
        guard cursorAbsRow == anchor.absRow else { return nil }
        // Cursor at or before the anchor column ⇒ the command is empty.
        guard cursorCol > anchor.col else { return ("", 0) }
        // `getText`'s end column is EXCLUSIVE (its inner loop is `startCol..<endCol`), so passing
        // `cursorCol` yields exactly the text in `[commandStart.col, cursorCol)` — the characters
        // strictly before the cursor. (A `-1` here would drop the last typed char and, on a
        // single-char token, make start == end ⇒ empty, so tokens never completed.)
        let line = term.getText(start: Position(col: anchor.col, row: anchor.absRow),
                                end: Position(col: cursorCol, row: cursorAbsRow))
        return (line, line.count)
    }

    /// True only for the visible terminal that currently holds keyboard focus — the completion
    /// gate uses this so a background pane never pops up. Exposes the existing
    /// `isFocusedSurface` computed property under a clearer name for the controller.
    var isTerminalFocused: Bool { isFocusedSurface }

    /// The shell's current working directory as a file URL, for resolving filesystem completion
    /// sources (Task 11). Reuses the same `currentDirectory`-then-`fallbackDirectory` resolution
    /// as ⌘+click's `baseDirs` (OSC 7 `file://` URL or a bare path, percent-decoded), so both
    /// features agree on "where are we". `baseDirs` always ends with `fallbackDirectory`, so
    /// `.first` is non-nil.
    var currentDirectoryURL: URL {
        URL(fileURLWithPath: baseDirs.first ?? fallbackDirectory)
    }

    /// Maps a screen-relative cell (as produced by `cursorCell`) to a view point at the
    /// BOTTOM edge of that cell — i.e. where a completion popup should anchor to sit just
    /// below the current line. This is the exact inverse of `clickTarget(at:)`'s forward
    /// mapping (~lines 233–235):
    ///   forward:  yFromTop = isFlipped ? point.y : (bounds.height - point.y)
    ///             screenRow = Int(yFromTop / cellHeight)
    /// So a point at the BOTTOM of `screenRow` has `yFromTop = (screenRow + 1) * cellHeight`;
    /// inverting the `isFlipped` branch gives `point.y` back. Column maps the same way but
    /// left-to-right in both coordinate systems, so no flip is needed there.
    func cursorCellToViewPoint(_ cell: (col: Int, row: Int)) -> CGPoint {
        let term = getTerminal()
        let cols = term.cols, rows = term.rows
        guard rows > 0, cols > 0, bounds.width > 0, bounds.height > 0 else { return .zero }

        let cellWidth = bounds.width / CGFloat(cols)
        let cellHeight = bounds.height / CGFloat(rows)
        let x = CGFloat(cell.col) * cellWidth
        let yFromTop = CGFloat(cell.row + 1) * cellHeight
        let y = isFlipped ? yFromTop : (bounds.height - yFromTop)
        return CGPoint(x: x, y: y)
    }

    // MARK: - Completion popup (Task 9)

    /// Lazily created on first use, like `dropHighlight` below — a session with completions
    /// disabled (or one where the gate never fires) never allocates it.
    private lazy var completionPopup: CompletionPopupView = {
        let v = CompletionPopupView(frame: .zero)
        // No autoresizing: every `showCompletionPopup` call sets an explicit frame, there's
        // nothing to track between calls.
        return v
    }()

    /// Shows (or repositions) the completion popup for `candidates`, anchored just below the
    /// in-progress token. `anchorLineOffset` is the column offset — from the command-start
    /// anchor — where the token being completed begins (`CompletionContext.replacementRange
    /// .lowerBound`, forwarded by `CompletionController.onShow`).
    ///
    /// **v1 single-row ASCII assumption**, same one `commandLineToCursor` documents: 1 character
    /// = 1 column, so the token's start column is simply `commandStart.col + anchorLineOffset`.
    /// A completion whose line contains wide/combining characters before the token would anchor
    /// a column or two off — an accepted v1 limitation, not a crash risk.
    ///
    /// Idempotent: safe to call again on every cursor move / candidate refresh — always
    /// repositions (recomputing the below/above flip) and resets to a freshly-built row set with
    /// `selectedIndex` 0. Silent-off (hides instead) on any degenerate geometry: empty
    /// candidates, a zero-sized grid, or zero view bounds.
    func showCompletionPopup(_ candidates: [Candidate], anchorLineOffset: Int) {
        guard !candidates.isEmpty else {
            hideCompletionPopup()
            return
        }
        let term = getTerminal()
        let cols = term.cols, rows = term.rows
        guard cols > 0, rows > 0, bounds.width > 0, bounds.height > 0 else {
            hideCompletionPopup()
            return
        }

        let anchorCol = (commandStart?.col ?? cursorCell.col) + anchorLineOffset
        let anchorRow = cursorCell.row

        let size = CompletionPopupView.preferredSize(for: candidates)
        guard size.width > 0, size.height > 0 else {
            hideCompletionPopup()
            return
        }

        if completionPopup.superview == nil {
            addSubview(completionPopup)
        }

        // `below` is the point at the BOTTOM edge of the anchor cell (see
        // `cursorCellToViewPoint`'s doc comment) — where the popup naturally hangs, left-aligned
        // to the token's start column, growing downward.
        let below = cursorCellToViewPoint((col: anchorCol, row: anchorRow))

        // Extending "downward on screen" from `below`: in a flipped view (y grows downward) the
        // popup's top-left origin IS `below`, and it grows toward larger y. In a non-flipped
        // view (y grows upward; frame origin is the BOTTOM-left corner) `below` is instead the
        // popup's TOP edge, so the origin sits `size.height` below it.
        var origin = isFlipped ? below : CGPoint(x: below.x, y: below.y - size.height)

        // Flip-above trigger: the popup's far edge would fall outside the terminal's own
        // bounds — flipped: its bottom (origin.y + height) past bounds.height; non-flipped:
        // its bottom (origin.y itself) below zero.
        let overflowsBottom = isFlipped
            ? (origin.y + size.height > bounds.height)
            : (origin.y < 0)

        if overflowsBottom, anchorRow > 0 {
            // Hang the popup off the TOP of the cursor's row instead, extending upward. `top`
            // is the bottom edge of the row above `anchorRow`, which is exactly the top edge of
            // `anchorRow` — the same `cursorCellToViewPoint` primitive, one row up. (If
            // `anchorRow` is already the topmost screen row there's nowhere to flip to, so this
            // branch is skipped; and if the popup is too tall to fit above a low `anchorRow`,
            // the vertical clamp below keeps it inside the pane regardless.)
            let top = cursorCellToViewPoint((col: anchorCol, row: anchorRow - 1))
            origin = isFlipped
                ? CGPoint(x: top.x, y: top.y - size.height)
                : CGPoint(x: top.x, y: top.y)
        }

        // Clamp WIDTH first: in a pane narrower than the popup's min width (160pt) the frame
        // would otherwise overflow the right edge even with origin.x pinned to 0. Capping the
        // width to the pane keeps it fully inside; over-long rows already tail-truncate.
        let width = min(size.width, bounds.width)

        // Clamp HORIZONTALLY so the popup never runs off the right (or, after the width cap,
        // the left) edge of the terminal.
        origin.x = max(0, min(origin.x, bounds.width - width))

        // Clamp VERTICALLY so the popup frame is never partly outside the pane, in EITHER the
        // below or flipped-above placement — the flip-above branch above only guarantees the
        // popup sits above the cursor row, not that it fits above it, so a tall list with the
        // cursor near the top of the screen would otherwise extend past the pane's edge.
        //
        // The frame occupies `[origin.y, origin.y + size.height]` in the superview's coordinate
        // system regardless of `isFlipped`; the *visual top* (where row 0 renders) depends on
        // orientation — non-flipped: top edge = `origin.y + height`; flipped: top edge =
        // `origin.y`. When the popup fits, clamp the whole frame inside the pane. When it's
        // taller than the entire pane (very rare — needs a pane shorter than the ~8-row visible
        // cap), degrade to keeping the top rows visible (the scroll view spills its lower rows
        // off the far edge), which means pinning whichever edge is the visual top.
        if size.height <= bounds.height {
            origin.y = min(max(origin.y, 0), bounds.height - size.height)
        } else {
            origin.y = isFlipped ? 0 : bounds.height - size.height
        }

        completionPopup.frame = NSRect(origin: origin,
                                       size: CGSize(width: width, height: size.height))
        completionPopup.show(candidates: candidates,
                             anchorCell: (col: anchorCol, row: anchorRow),
                             selectedIndex: 0)
    }

    /// Hides the completion popup. Safe to call redundantly or before it's ever been shown.
    func hideCompletionPopup() {
        completionPopup.hide()
    }

    /// Push a new highlighted row to the popup (arrow-key navigation). The popup's `selectedIndex`
    /// `didSet` restyles the affected rows and scrolls the selection into view.
    func setCompletionPopupSelectedIndex(_ index: Int) {
        completionPopup.selectedIndex = index
    }

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
        if window != nil, !didRegisterOsc133 {
            didRegisterOsc133 = true
            registerOsc133Handler()
        }
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

    /// A ⌘-clickable target under the pointer. iTerm parity: URLs open in the browser, files
    /// in the editor, and directories (e.g. the cwd printed in the shell prompt) in Finder.
    private enum ClickTarget {
        case url(URL)
        case file(path: String, line: Int?)
        case directory(path: String)
    }

    /// Called by the app's ⌘+click monitor (SwiftTerm's `mouseDown`/`requestOpenLink`
    /// are `public` but not `open`, so we can't override them). Returns true if it
    /// opened something.
    @discardableResult
    func handleCommandClick(_ event: NSEvent) -> Bool {
        switch clickTarget(at: event) {
        case .url(let url):
            NSWorkspace.shared.open(url)
            return true
        case .file(let path, let line):
            onOpenFile?(path, line)
            return true
        case .directory(let path):
            // iTerm opens a clicked directory (typically the prompt's cwd) in Finder.
            NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
            return true
        case nil:
            return false
        }
    }

    /// Whether a ⌘+click at this location would open something. Used by the app's ⌘-hover
    /// monitor to show the pointing-hand cursor over links without acting on them.
    func linkExists(at event: NSEvent) -> Bool {
        clickTarget(at: event) != nil
    }

    /// The URL or file path under `event`, or nil — the single source of truth shared by the
    /// ⌘+click handler and the ⌘-hover cursor, so the affordance and the action never disagree.
    private func clickTarget(at event: NSEvent) -> ClickTarget? {
        guard containsClick(event) else { return nil }
        let point = convert(event.locationInWindow, from: nil)

        let term = getTerminal()
        let cols = term.cols, rows = term.rows
        guard rows > 0, cols > 0, bounds.height > 0 else { return nil }

        let cellHeight = bounds.height / CGFloat(rows)
        let yFromTop = isFlipped ? point.y : (bounds.height - point.y)
        let screenRow = max(0, min(rows - 1, Int(yFromTop / cellHeight)))
        // `getText` addresses the absolute buffer (scrollback + on-screen rows), but the
        // click gives a screen-relative row. Add the scroll offset — `getTopVisibleRow()`
        // is `buffer.yDisp`, the top visible buffer row — to land on the line actually under
        // the cursor, mirroring SwiftTerm's own `bufferRow = screenRow + yDisp`. Without this,
        // any scrollback (i.e. almost always in a busy session) read a stale line from the top
        // of history, so URLs fell through to the file route or matched nothing.
        let bufferRow = screenRow + term.getTopVisibleRow()

        // Scan the clicked row plus neighbors: row math is approximate and a path/URL can
        // wrap. `getText` clamps the upper bound itself, so only guard against negatives.
        // A URL on a line wins over the file/directory route. Directories are only honoured on
        // the clicked row (dr == 0): the prompt's cwd is an existing directory, and matching it
        // from a *neighbouring* row would let it hijack a click aimed at a (non-resolving) file.
        for dr in [0, -1, 1] {
            let rr = bufferRow + dr
            guard rr >= 0 else { continue }
            let line = term.getText(start: Position(col: 0, row: rr),
                                    end: Position(col: cols - 1, row: rr))
            if let url = firstWebURL(in: line) {
                return .url(url)
            }
            if let hit = resolvePath(in: line, allowDirectory: dr == 0) {
                return hit.isDirectory ? .directory(path: hit.path)
                                       : .file(path: hit.path, line: hit.line)
            }
        }
        return nil
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

    /// First token on the line that resolves to an existing filesystem path, with whether it's
    /// a directory. Supports `path`, `path:line`, and `path:line:col`. When `allowDirectory` is
    /// false, directory matches are skipped (so a neighbouring prompt's cwd can't hijack a click
    /// aimed at a file) — the editor route ignores the line number for directories anyway.
    private func resolvePath(in line: String,
                             allowDirectory: Bool) -> (path: String, line: Int?, isDirectory: Bool)? {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        for raw in tokens {
            // Backticks included: this terminal shows Claude's markdown output, where file
            // paths routinely appear as `inline code`. A leading backtick would make the path
            // fail to resolve, sending the click to a neighbouring URL/editor route instead.
            var token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`(),[]{}<>"))
            if let r = token.range(of: "\\") { token = String(token[..<r.lowerBound]) }
            if token.isEmpty { continue }

            let parts = token.split(separator: ":", maxSplits: 2).map(String.init)
            let pathPart = parts[0]
            let lineNo = parts.count > 1 ? Int(parts[1]) : nil

            let expanded = (pathPart as NSString).expandingTildeInPath
            let candidates = expanded.hasPrefix("/")
                ? [expanded]
                : baseDirs.map { ($0 as NSString).appendingPathComponent(expanded) }
            for candidate in candidates {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir) else { continue }
                if isDir.boolValue && !allowDirectory { continue }
                return (candidate, lineNo, isDir.boolValue)
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
