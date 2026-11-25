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
        refreshLinkHover()
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

    /// Whether *any* OSC 133 marker has ever arrived on this terminal — the signal that the shell
    /// integration actually loaded. Deliberately not derived from `promptPhase`: a `D` marker
    /// resets that to `.unknown`, so a working integration reads `.unknown` for the whole time a
    /// command runs. Latches true and never clears. Consumed by `TerminalSurface` to tell "no
    /// integration" apart from "mid-command" (see `shellIntegrationStatus`).
    private(set) var didSeeAnyPromptMarker = false

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
            self.didSeeAnyPromptMarker = true
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
    /// below the current line. It inverts the usual point→cell mapping:
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

    /// Called by the app's ⌘+click monitor (SwiftTerm's `mouseDown`/`requestOpenLink`
    /// are `public` but not `open`, so we can't override them). Returns true if it
    /// opened something.
    @discardableResult
    func handleCommandClick(_ event: NSEvent) -> Bool {
        switch clickHit(at: viewPoint(of: event))?.target {
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

    // MARK: - ⌘-hover underline (#87)

    /// ⌘-hover at `event`: underlines exactly what a ⌘+click there would open and returns
    /// whether there is anything (which drives the pointing-hand cursor). Called by the app's
    /// hover monitor only while ⌘ is held.
    ///
    /// Where SwiftTerm already underlines the cell itself (its own ⌘-hover highlight covers
    /// URLs, `./`/`~/`/`/` paths and OSC 8 links) we draw nothing, so there's never a double
    /// underline. Its highlight state is module-internal, so we can't drive it for our matches.
    func updateLinkHover(at event: NSEvent) -> Bool {
        guard let point = viewPoint(of: event), let hit = clickHit(at: point) else {
            clearLinkHover()
            return false
        }
        let term = getTerminal()
        let swiftTermUnderlines = term.link(at: .screen(hit.cell), mode: .explicitAndImplicit) != nil
        setLinkUnderline(swiftTermUnderlines ? [] : hit.underline)
        return true
    }

    /// Removes the ⌘-hover underline (⌘ released, pointer left the link or this pane).
    func clearLinkHover() {
        setLinkUnderline([])
    }

    /// Re-run the hover against the pointer's current position: output and scrolling move text
    /// under a stationary pointer, so a drawn underline would otherwise point at stale cells.
    private func refreshLinkHover() {
        guard linkUnderline.superview != nil, !linkUnderline.runs.isEmpty else { return }
        guard NSEvent.modifierFlags.contains(.command), let window,
              let hit = clickHit(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        else { clearLinkHover(); return }
        let swiftTermUnderlines = getTerminal().link(at: .screen(hit.cell), mode: .explicitAndImplicit) != nil
        setLinkUnderline(swiftTermUnderlines ? [] : hit.underline)
    }

    // MARK: - Live-resize PTY gate (#80)

    /// SwiftTerm sends TIOCSWINSZ from `sizeChanged` (public, not open) on every frame of a
    /// window drag, but takes the size from `getWindowSize()` — which IS open. Reporting the
    /// last committed size for the duration of the drag means the kernel (which only signals
    /// SIGWINCH on an actual change) never wakes the program mid-reflow; SwiftTerm still
    /// re-wraps and draws its own buffer live. The final size is pushed once the drag ends.
    private var ptyGate = LiveResizePtyGate()

    override func getWindowSize() -> winsize {
        let actual = super.getWindowSize()
        return winsize(ptyGate.sizeToReport(actual: PtySize(actual), inLiveResize: inLiveResize))
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        guard let process, process.running,
              let size = ptyGate.endLiveResize(actual: PtySize(super.getWindowSize())) else { return }
        var ws = winsize(size)
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &ws)
    }

    override func scrolled(source terminal: Terminal, yDisp: Int) {
        super.scrolled(source: terminal, yDisp: yDisp)
        refreshLinkHover()
    }

    private lazy var linkUnderline: LinkUnderlineOverlay = {
        let v = LinkUnderlineOverlay(frame: bounds)
        v.autoresizingMask = [.width, .height]
        return v
    }()

    /// Draw (or, with `[]`, remove) underlines beneath the given screen-row column runs.
    private func setLinkUnderline(_ runs: [RowColumns]) {
        if runs.isEmpty && linkUnderline.superview == nil { return }
        let cell = cellSize
        let thickness = max(1, (cell.height / 16).rounded())
        let rects = runs.map { run in
            CGRect(x: CGFloat(run.columns.lowerBound) * cell.width,
                   y: CGFloat(run.row + 1) * cell.height - thickness,
                   width: CGFloat(run.columns.count) * cell.width,
                   height: thickness)
        }
        if linkUnderline.superview == nil {
            linkUnderline.frame = bounds
            addSubview(linkUnderline)
        }
        linkUnderline.color = nativeForegroundColor
        linkUnderline.runs = rects
    }

    /// What a ⌘+click / ⌘-hover at a view point means: the target, the clicked screen cell,
    /// and the screen-row column runs holding the text it was read from (empty for OSC 8,
    /// whose link SwiftTerm underlines itself).
    private struct ClickHit {
        let target: TerminalClickTarget
        let cell: Position
        let underline: [RowColumns]
    }

    private func viewPoint(of event: NSEvent) -> CGPoint? {
        containsClick(event) ? convert(event.locationInWindow, from: nil) : nil
    }

    /// The single source of truth shared by ⌘+click, the ⌘-hover cursor and the underline, so
    /// the affordance and the action never disagree.
    ///
    /// Only what is under the clicked cell counts (#79): an OSC 8 hyperlink on the cell wins;
    /// otherwise the soft-wrapped rows around the click are joined into one logical line and
    /// `resolveClickMatch` (CodaCore) picks the URL/path under the clicked column.
    private func clickHit(at point: CGPoint?) -> ClickHit? {
        guard let point, bounds.contains(point) else { return nil }
        let term = getTerminal()
        let cols = term.cols, rows = term.rows
        guard rows > 0, cols > 0 else { return nil }

        let cell = cellSize
        let yFromTop = isFlipped ? point.y : (bounds.height - point.y)
        let screenRow = max(0, min(rows - 1, Int(yFromTop / cell.height)))
        let screenCol = max(0, min(cols - 1, Int(point.x / cell.width)))
        let clicked = Position(col: screenCol, row: screenRow)

        // OSC 8: an explicit hyperlink on the clicked cell (Claude Code emits these) is the
        // most reliable signal there is — no guessing at token boundaries.
        if let link = term.link(at: .screen(clicked), mode: .explicitOnly),
           let target = resolveHyperlink(link, pathKind: Self.diskPathKind) {
            return ClickHit(target: target, cell: clicked, underline: [])
        }

        // Rows are screen-relative here; `getText` wants absolute buffer rows, so offset by
        // the top visible row (`buffer.yDisp`) — otherwise any scrollback reads a stale line.
        let top = term.getTopVisibleRow()
        var first = screenRow
        while first > 0 && isSoftWrapContinuation(term, bufferRow: first + top) { first -= 1 }
        var last = screenRow
        while last + 1 < rows && isSoftWrapContinuation(term, bufferRow: last + 1 + top) { last += 1 }

        let rowTexts = (first...last).map { r in
            TerminalRowText(cells: cells(term, screenRow: r, cols: cols),
                            continuesPrevious: r != first)
        }
        guard let line = logicalLine(rows: rowTexts, row: screenRow - first, column: screenCol),
              let match = resolveClickMatch(line: line.text, offset: line.offset,
                                            baseDirs: baseDirs, pathKind: Self.diskPathKind)
        else { return nil }
        let underline = line.rowColumns(for: match.range).map {
            RowColumns(row: $0.row + first, columns: $0.columns)
        }
        return ClickHit(target: match.target, cell: clicked, underline: underline)
    }

    /// Whether buffer row `bufferRow` is a soft-wrap continuation of the row above.
    /// SwiftTerm keeps `BufferLine.isWrapped` internal, but `getText` only inserts a newline
    /// between two rows when the second one is NOT wrapped — so a two-row read without "\n"
    /// means a wrap. The row itself must have content: `getText` never emits a newline for a
    /// blank trailing row, which would otherwise glue unrelated lines together.
    private func isSoftWrapContinuation(_ term: Terminal, bufferRow: Int) -> Bool {
        guard bufferRow > 0 else { return false }
        let own = term.getText(start: Position(col: 0, row: bufferRow),
                               end: Position(col: term.cols, row: bufferRow))
        guard !own.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let both = term.getText(start: Position(col: 0, row: bufferRow - 1),
                                end: Position(col: term.cols, row: bufferRow))
        return !both.contains("\n")
    }

    /// One screen row as a cell-per-column array: `nil` for the continuation cell of a
    /// double-width character, a space for empty cells.
    private func cells(_ term: Terminal, screenRow: Int, cols: Int) -> [Character?] {
        (0..<cols).map { col in
            guard let cd = term.getCharData(col: col, row: screenRow) else { return " " }
            if cd.width == 0 { return nil }
            let ch = term.getCharacter(for: cd)
            return ch == "\u{0}" ? " " : ch
        }
    }

    /// Cell size, computed the way SwiftTerm's (internal) `computeFontDimensions` does — the
    /// "W" advance and the line height of `font`, snapped to the pixel grid — so the clicked
    /// column matches the drawn one even across a wide row. `bounds.width / cols` drifts:
    /// the view's width includes the scroller and any leftover sub-cell slack.
    private var cellSize: CGSize {
        let f = font
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let w = f.advancement(forGlyph: f.glyph(withName: "W")).width
        let h = CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f)
        return CGSize(width: max(1, ceil(w * scale) / scale),
                      height: max(1, ceil(ceil(h) * scale) / scale))
    }

    private static func diskPathKind(_ path: String) -> PathKind? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        return isDir.boolValue ? .directory : .file
    }

    private var baseDirs: [String] {
        var dirs: [String] = []
        // OSC 7 cwd (sent on every prompt by Coda's zsh integration), then the worktree root.
        if let cwd = currentDirectory.flatMap(directoryPath(fromOSC7:)) {
            dirs.append(cwd)
        }
        dirs.append(fallbackDirectory)
        return dirs
    }

}

/// Non-interactive overlay that draws the ⌘-hover link underline (#87). `hitTest` returns nil
/// so it never intercepts a click; flipped so rects are laid out from the top like cell rows.
private final class LinkUnderlineOverlay: NSView {
    var runs: [CGRect] = [] {
        didSet { if runs != oldValue { needsDisplay = true } }
    }
    var color: NSColor = .textColor {
        didSet { if color != oldValue { needsDisplay = true } }
    }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        runs.forEach { $0.fill() }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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

private extension PtySize {
    init(_ ws: winsize) {
        self.init(cols: Int(ws.ws_col), rows: Int(ws.ws_row), width: Int(ws.ws_xpixel), height: Int(ws.ws_ypixel))
    }
}

private extension winsize {
    init(_ size: PtySize) {
        func clamp(_ v: Int) -> UInt16 { UInt16(clamping: max(0, v)) }
        self.init(ws_row: clamp(size.rows), ws_col: clamp(size.cols),
                  ws_xpixel: clamp(size.width), ws_ypixel: clamp(size.height))
    }
}
