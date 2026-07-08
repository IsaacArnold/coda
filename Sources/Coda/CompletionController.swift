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
/// This task builds the controller, its debounce, and its gate wiring only. Two seams are stubbed:
/// - **Task 9 (popup UI):** `onShow`/`onHide` are the seam. Until wired, a `show` decision either
///   logs (when `CODA_DEBUG_COMPLETIONS` is set) or is a no-op.
/// - **Task 11 (dynamic sources):** `resolveDynamicSources` returns `[]` for now.
/// Task 10 (keystroke interception / accept / navigation) calls `suppress()`/`noteEdit()`, which
/// are exposed now but not yet driven from anywhere.
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

    /// Post-Esc suppression: set by `suppress()` (Task 10's Esc handler), cleared by `noteEdit()`
    /// (the next character/backspace). While set, the gate keeps the popup hidden.
    private(set) var isSuppressedUntilNextEdit = false

    /// **Task 9 seam.** Called with the ranked candidates + the line span to replace when the
    /// gate says show. Task 9 wires this to present/update the popup.
    var onShow: (([Candidate], Range<Int>) -> Void)?
    /// **Task 9 seam.** Called whenever the popup should not (or no longer) be visible.
    var onHide: (() -> Void)?

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

    /// Esc pressed: hide and stay hidden until the next edit. (Task 10 calls this.)
    func suppress() {
        isSuppressedUntilNextEdit = true
        hide()
    }

    /// A character/backspace was typed: lift post-Esc suppression. (Task 10 calls this.)
    func noteEdit() {
        isSuppressedUntilNextEdit = false
    }

    /// Hide the popup (or confirm it's hidden). Fires `onHide`; safe to call redundantly.
    func hide() {
        onHide?()
    }

    private func performRefresh() {
        guard let surface, let (line, offset) = surface.commandLineToCursor() else {
            hide()
            return
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
