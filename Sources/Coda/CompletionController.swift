import AppKit
import Foundation
import CodaCore

/// The state a `CompletionController` reads from its owning surface. Modeled as a protocol rather
/// than a hard reference to `TerminalSurface` to keep the coupling one-directional and narrow:
/// the controller depends only on these five accessors, and nothing here reaches back into the
/// view hierarchy. `TerminalSurface` conforms and hands `self` in at construction.
protocol CompletionSurface: AnyObject {
    /// Live OSC 133 prompt phase.
    var promptPhase: PromptPhase { get }
    /// Whether this surface holds keyboard focus.
    var isTerminalFocused: Bool { get }
    /// Whether the viewport is at the live bottom (the anchor math is only valid there).
    var isScrolledToBottom: Bool { get }
    /// The shell's cwd, for resolving filesystem/git completion sources (Task 11).
    var currentDirectoryURL: URL { get }
    /// The editable command line from command-start to cursor, or `nil` if unreadable.
    func commandLineToCursor() -> (line: String, cursorOffset: Int)?
}

/// The per-surface conductor for terminal completions. It observes the terminal (it never sits in
/// the keystroke-to-shell path), reads the live command line, runs the pure `CodaCore` engine,
/// applies the pure visibility gate, and hands the result to the popup overlay.
///
/// **Threading:** main-thread-only, no locks — every input (OSC 133 phase changes, PTY output,
/// focus changes) already arrives on the main thread (SwiftTerm posts `dataReceived` on
/// `DispatchQueue.main`), matching the reasoning in `ClickableTerminalView`.
///
/// **Ownership:** `TerminalSurface` creates exactly one of these, and *only* when completions are
/// enabled — so a session with the feature off pays zero cost (the controller isn't even
/// allocated). The surface reference is `weak`; the surface outlives the controller.
///
/// Task 11 (dynamic sources) still stubs `resolveDynamicSources` (returns `[]`). Task 10 added the
/// keyboard-navigation API: the controller now RETAINS what the popup is showing
/// (`shownCandidates`/`shownRange`/`shownQuery`, `selectedIndex`) and exposes `moveSelection(by:)`
/// / `acceptSelected()` plus the `onSelectionChange`/`onAccept` seams that push those decisions to
/// the popup and the PTY. The app-level key monitor drives all of it while `isPopupVisible`.
final class CompletionController {
    private weak var surface: CompletionSurface?

    /// Loaded once at init; `[:]` if the bundled specs dir is missing/unreadable (never crashes).
    private let specs: [String: CompletionSpec]

    /// The in-flight debounced refresh, cancelled and replaced on each `refresh()`.
    private var pendingRefresh: DispatchWorkItem?

    /// Debounce window. Long enough to coalesce a burst of output/keystrokes into one engine run,
    /// short enough to feel live. The keystroke itself reaches the shell immediately regardless —
    /// this only delays *observing* the buffer, never input.
    private let debounceInterval: TimeInterval = 0.04

    /// Post-Esc suppression: set by `suppress()` (Esc handler). While set, the gate keeps the
    /// popup hidden. Cleared not by a per-keystroke hook but by the next *line change* observed in
    /// `performRefresh()` (see `suppressedLine`) — so the popup reappears once the query changes.
    private(set) var isSuppressedUntilNextEdit = false

    /// The command line snapshotted when `suppress()` fired. `performRefresh` lifts suppression as
    /// soon as it sees a line different from this — the output-driven "suppressed until next edit".
    private var suppressedLine: String?

    // MARK: Retained "what the popup is showing" (Task 10)

    /// Whether the popup is currently visible. The key monitor only steals keys while this is true.
    private(set) var isPopupVisible = false
    /// The candidates handed to the popup on the last `show`, indexed by `selectedIndex`.
    private(set) var shownCandidates: [Candidate] = []
    /// The line span the accepted candidate replaces (forwarded to the popup as the anchor).
    private var shownRange: Range<Int> = 0..<0
    /// The current token's typed prefix at show time (`ctx.query`) — its `count` is how many
    /// characters `acceptSelected()` erases before inserting the candidate.
    private var shownQuery = ""
    /// The highlighted row, into `shownCandidates`. Reset to 0 on each `show` (acceptable for v1).
    private(set) var selectedIndex = 0

    /// **Task 9 seam.** Called with the ranked candidates + the line span to replace when the
    /// gate says show. Task 9 wires this to present/update the popup.
    var onShow: (([Candidate], Range<Int>) -> Void)?
    /// **Task 9 seam.** Called whenever the popup should not (or no longer) be visible.
    var onHide: (() -> Void)?
    /// **Task 10 seam.** Pushes a new `selectedIndex` to the popup (→ `popup.selectedIndex`).
    var onSelectionChange: ((Int) -> Void)?
    /// **Task 10 seam.** Emits the exact bytes to send to the PTY on accept (DEL-erase of the typed
    /// prefix + the candidate's insertion). The surface wires this to `terminal.send(txt:)`.
    var onAccept: ((String) -> Void)?

    init(surface: CompletionSurface) {
        self.surface = surface
        if let dir = Bundle.codaAssets.resourceURL?
            .appendingPathComponent("Resources/completion-specs") {
            self.specs = (try? loadCompletionSpecs(from: dir)) ?? [:]
        } else {
            self.specs = [:]
        }
    }

    /// Schedule a debounced refresh, cancelling any pending one. Cheap to call on every output
    /// chunk / phase change / focus change; the actual work runs once the burst settles.
    func refresh() {
        pendingRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.performRefresh() }
        pendingRefresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    /// Esc pressed: hide and stay hidden until the next edit. Snapshots the current line so
    /// `performRefresh` can detect that "next edit" (a line change) and lift suppression itself —
    /// no per-keystroke hook needed. If the line can't be read, suppression still engages and the
    /// first refresh with a readable, differing line clears it.
    func suppress() {
        isSuppressedUntilNextEdit = true
        suppressedLine = surface?.commandLineToCursor()?.line
        hide()
    }

    /// Hide the popup (or confirm it's hidden). Fires `onHide` and clears the retained shown state;
    /// safe to call redundantly. Does NOT touch suppression — that's owned by `suppress()`/the
    /// line-change check in `performRefresh`.
    func hide() {
        isPopupVisible = false
        shownCandidates = []
        shownRange = 0..<0
        shownQuery = ""
        selectedIndex = 0
        onHide?()
    }

    /// Move the highlighted row by `delta` (clamped to the list bounds — no wrap in v1). No-op
    /// unless the popup is visible with candidates. Pushes the new index to the popup.
    func moveSelection(by delta: Int) {
        guard isPopupVisible, !shownCandidates.isEmpty else { return }
        let clamped = max(0, min(selectedIndex + delta, shownCandidates.count - 1))
        guard clamped != selectedIndex else { return }
        selectedIndex = clamped
        onSelectionChange?(clamped)
    }

    /// Accept the highlighted candidate: emit the bytes that erase the token's already-typed
    /// prefix and insert the candidate, then hide. No-op unless the popup is visible with a valid
    /// selection.
    ///
    /// **Bytes:** `String(repeating: "\u{7f}", count: shownQuery.count) + candidate.insertion`.
    /// `\u{7f}` (DEL) is zsh's `backward-delete-char`, so it rubs out the `query.count` characters
    /// the user already typed for the current token; `insertion` then supplies the full token
    /// (carrying its own trailing space for static candidates).
    ///
    /// **v1 assumption:** the cursor sits at the end of the current token on a single input row —
    /// the same assumption `commandLineToCursor` documents. Under it, `query.count` DELs land
    /// exactly on the typed prefix.
    func acceptSelected() {
        guard isPopupVisible, shownCandidates.indices.contains(selectedIndex) else { return }
        let candidate = shownCandidates[selectedIndex]
        let erase = String(repeating: "\u{7f}", count: shownQuery.count)
        onAccept?(erase + candidate.insertion)
        hide()
    }

    private func performRefresh() {
        guard let surface, let (line, offset) = surface.commandLineToCursor() else {
            hide()
            return
        }

        // "Suppressed until the next edit" resolves here, output-driven: once the line differs
        // from the one snapshotted at Esc, lift suppression before the gate reads it, so the
        // popup can reappear for the changed query.
        if isSuppressedUntilNextEdit, line != suppressedLine {
            isSuppressedUntilNextEdit = false
            suppressedLine = nil
        }

        let ctx = resolveCompletion(line: line, cursorOffset: offset, specs: specs)
        let dynamic = resolveDynamicSources(ctx.dynamicSources, cwd: surface.currentDirectoryURL)
        let ranked = rankCandidates(ctx.staticCandidates + dynamic, query: ctx.query)

        // Re-tokenize for the gate's `hasCommandToken`/`endsWithSeparator` inputs. This repeats
        // work `resolveCompletion` already did internally, but it's cheap (line-to-cursor only)
        // and keeps the gate's inputs honest and explicit rather than threaded out of the engine.
        let tokenized = tokenizeCommandLine(line, cursorOffset: offset)

        let show = shouldShowCompletions(
            phase: surface.promptPhase,
            isFocused: surface.isTerminalFocused,
            isScrolledToBottom: surface.isScrolledToBottom,
            isSuppressed: isSuppressedUntilNextEdit,
            query: ctx.query,
            endsWithSeparator: tokenized.endsWithSeparator,
            hasCommandToken: !tokenized.tokens.isEmpty,
            rankedCount: ranked.count
        )

        guard show else {
            hide()
            return
        }

        // Retain what we're about to show so the key monitor can navigate/accept against it.
        // selectedIndex resets to 0 on every show (acceptable for v1).
        shownCandidates = ranked
        shownRange = ctx.replacementRange
        shownQuery = ctx.query
        selectedIndex = 0
        isPopupVisible = true

        if ProcessInfo.processInfo.environment["CODA_DEBUG_COMPLETIONS"] != nil {
            let names = ranked.map(\.name).joined(separator: ", ")
            print("[completions] query=\"\(ctx.query)\" → [\(names)]")
        }
        onShow?(ranked, ctx.replacementRange)
    }

    /// Resolves the dynamic (I/O-backed) completion sources into concrete candidates.
    ///
    /// **STUB (Task 11):** returns `[]`. The real signature is in place so Task 11 only fills the
    /// body — `cwd` is the directory filesystem sources resolve against and git generators run in.
    private func resolveDynamicSources(_ sources: [DynamicSource], cwd: URL) -> [Candidate] {
        // TODO(Task 11): filesystem (filepaths/folders) + git (gitBranches/gitRemotes) generators.
        []
    }
}
