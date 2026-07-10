import AppKit
import SwiftTerm
import CodaCore

/// A view controller hosting one SwiftTerm terminal that runs `command` (via the
/// login shell) inside `workingDirectory`. If `setupScript` is non-empty it runs
/// before the command (visibly, once).
final class TerminalSurface: NSViewController {
    private let workingDirectory: String
    private let command: String
    private let setupScript: String
    private let hookWorktreeID: String
    private let hookSurfaceID: String
    private let hookSocketPath: String
    private let shell: ResolvedShell
    private let completionsEnabled: Bool
    private var terminal: ClickableTerminalView!
    private var pendingTheme: TerminalTheme?
    private var pendingFont: NSFont?
    /// The per-surface completion conductor. Created in `loadView` ONLY when `completionsEnabled`
    /// is true, so the feature costs nothing when off. `nil` otherwise — every `refresh()` call
    /// site optional-chains through it.
    private var completionController: CompletionController?

    /// Opens a ⌘-clicked `path:line` in the default editor (wired by AppDelegate).
    var onOpenFile: ((String, Int?) -> Void)?
    /// The live terminal title (OSC 0/2, set by the shell/claude), used for the tab label.
    private(set) var terminalTitle: String = ""
    /// Fired when the terminal title changes, so the tab bar can relabel.
    var onTitleChange: ((String) -> Void)?
    /// Fired when this surface's terminal gains focus (forwarded from the terminal view).
    var onFocused: (() -> Void)?
    /// Fired when the terminal's OSC 133-driven prompt phase changes (forwarded from the
    /// terminal view). Set before or after the view loads — wired in `loadView()` below via
    /// `[weak self]`, same idiom as `onOpenFile`/`onFocused`. Consumed by the completion
    /// controller (a later task).
    var onPromptPhaseChange: ((PromptPhase) -> Void)?

    init(workingDirectory: String, command: String, setupScript: String = "",
         hookWorktreeID: String = "", hookSurfaceID: String = "", hookSocketPath: String = "",
         shell: ResolvedShell = ResolvedShell(executablePath: "/bin/zsh"),
         completionsEnabled: Bool = false) {
        self.workingDirectory = workingDirectory
        self.command = command
        self.setupScript = setupScript
        self.hookWorktreeID = hookWorktreeID
        self.hookSurfaceID = hookSurfaceID
        self.hookSocketPath = hookSocketPath
        self.shell = shell
        self.completionsEnabled = completionsEnabled
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        terminal = ClickableTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        terminal.autoresizingMask = [.width, .height]
        terminal.fallbackDirectory = workingDirectory
        terminal.onOpenFile = { [weak self] path, line in self?.onOpenFile?(path, line) }
        terminal.onBecomeFirstResponder = { [weak self] in
            self?.onFocused?()
            self?.completionController?.refresh()
        }
        terminal.onPromptPhaseChange = { [weak self] phase in
            self?.onPromptPhaseChange?(phase)
            self?.completionController?.refresh()
        }
        terminal.processDelegate = self
        view = terminal

        // Own one completion controller, but only when the feature is on — a session with
        // completions disabled never allocates it, so it adds zero overhead (no specs load, no
        // debounce timers, no output hook). Wire it to refresh on prompt-phase changes (above),
        // terminal output (below), and focus changes (above). Keystroke-driven refresh + accept/
        // navigation is Task 10.
        if completionsEnabled {
            completionController = CompletionController(surface: self)
            terminal.onOutput = { [weak self] in self?.completionController?.refresh() }
            // Task 9: wire the controller's show/hide seams to the popup overlay. The controller
            // has already run the pure engine + visibility gate by the time either fires — this
            // is pure "display what it decided," no further gating here.
            completionController?.onShow = { [weak self] candidates, range in
                self?.terminal.showCompletionPopup(candidates, anchorLineOffset: range.lowerBound)
            }
            completionController?.onHide = { [weak self] in self?.terminal.hideCompletionPopup() }
            // Task 10: arrow-key navigation restyles the popup; accept sends erase+insert bytes
            // straight to the PTY (same path as `sendCommand`).
            completionController?.onSelectionChange = { [weak self] idx in
                self?.terminal.setCompletionPopupSelectedIndex(idx)
            }
            completionController?.onAccept = { [weak self] bytes in self?.terminal.send(txt: bytes) }
        }
    }

    // MARK: - Completion popup keyboard control (Task 10)
    //
    // Thin forwarders the app-level key monitor calls while the popup is visible. Each no-ops
    // safely when completions are off (the controller is nil).

    /// Whether this surface's completion popup is currently visible — the key monitor only steals
    /// ↑/↓/Tab/Esc/Enter while this is true.
    var isCompletionPopupVisible: Bool { completionController?.isPopupVisible ?? false }

    /// Move the popup's highlighted row (arrow keys). Clamps at the ends (no wrap in v1).
    func moveCompletionSelection(_ delta: Int) { completionController?.moveSelection(by: delta) }

    /// Accept the highlighted candidate (Tab): erase the typed prefix and insert the candidate.
    func acceptCompletion() { completionController?.acceptSelected() }

    /// Dismiss the popup (Esc): hide and stay hidden until the next edit.
    func dismissCompletion() { completionController?.suppress() }

    /// Hide the popup (Enter): close it without suppressing, so the command still runs.
    func hideCompletion() { completionController?.hide() }

    /// Current shell prompt phase (OSC 133-driven), for the completion controller (a later
    /// task) to decide whether/when a completion popup makes sense.
    var promptPhase: PromptPhase { terminal?.promptPhase ?? .unknown }

    /// Exit code of the most recently finished command, if any.
    var lastCommandExitCode: Int? { terminal?.lastCommandExitCode }

    /// The terminal's live cursor cell and whether the viewport is scrolled to the live
    /// bottom — both needed by the completion controller to decide/position a popup.
    var cursorCell: (col: Int, row: Int) { terminal?.cursorCell ?? (0, 0) }
    var isScrolledToBottom: Bool { terminal?.isScrolledToBottom ?? true }

    /// Whether the running program has any-event mouse tracking on (hover motion streamed to the
    /// PTY). The app-level hover monitor uses this to swallow hover-select events over this pane.
    var isReportingMouseMotion: Bool { terminal?.isReportingMouseMotion ?? false }

    /// Whether this surface's terminal holds keyboard focus (for the completion gate).
    var isTerminalFocused: Bool { terminal?.isTerminalFocused ?? false }

    /// The shell's cwd as a file URL (for resolving filesystem completion sources). Falls back to
    /// `workingDirectory` before the view exists.
    var currentDirectoryURL: URL {
        terminal?.currentDirectoryURL ?? URL(fileURLWithPath: workingDirectory)
    }

    /// Maps a cursor cell to the view point just below it, for anchoring the completion popup.
    func cursorCellToViewPoint(_ cell: (col: Int, row: Int)) -> CGPoint {
        terminal?.cursorCellToViewPoint(cell) ?? .zero
    }

    /// The editable command line from command-start to cursor, or `nil` if unreadable. Forwarded
    /// from the terminal view (which stays private) for the completion controller.
    func commandLineToCursor() -> (line: String, cursorOffset: Int)? {
        terminal?.commandLineToCursor()
    }

    private var processStarted = false

    /// Type `command` into the live shell (as if the user typed it + Return).
    /// Used by "Launch Claude" to start an agent in a shell-first worktree.
    func sendCommand(_ command: String) {
        guard processStarted else { return }
        terminal.send(txt: command + "\r")
    }

    /// Apply a terminal color scheme: 16 ANSI colors + native fg/bg/cursor. Safe to call
    /// before the PTY starts — the theme is cached and applied once the view lays out.
    func applyTheme(_ theme: TerminalTheme) {
        pendingTheme = theme
        guard terminal != nil else { return }
        terminal.installColors(theme.ansi.map { $0.swiftTermColor })
        terminal.nativeForegroundColor = theme.foreground.nsColor
        terminal.nativeBackgroundColor = theme.background.nsColor
        terminal.caretColor = theme.cursor.nsColor
    }

    /// Set the terminal font. Safe before the PTY starts — cached and applied on layout.
    func applyFont(_ font: NSFont) {
        pendingFont = font
        guard terminal != nil else { return }
        terminal.font = font
    }

    /// Forwarded from AppDelegate's ⌘+click monitor. Returns true if it opened something.
    @discardableResult
    func handleCommandClick(_ event: NSEvent) -> Bool {
        terminal?.handleCommandClick(event) ?? false
    }

    /// Whether a ⌘+click event lands inside this surface's visible terminal.
    func containsClick(_ event: NSEvent) -> Bool {
        terminal?.containsClick(event) ?? false
    }

    /// Whether a ⌘+click here would open a link/file — drives the ⌘-hover pointer cursor.
    func linkExists(at event: NSEvent) -> Bool {
        terminal?.linkExists(at: event) ?? false
    }

    /// Last classified agent state, reused by `currentAgentState()` while the terminal is
    /// idle. `nil` until the first classification.
    private var cachedAgentState: AgentState?

    /// Agent state for this surface's terminal, recomputed only when the PTY produced new
    /// output since the last call — otherwise the previously classified state is returned.
    /// This keeps the ~1s agent-state poll from snapshotting every pane's full grid on the
    /// main thread every tick (background panes included), which showed up as periodic
    /// UI stutter; an unchanged terminal can't have changed state.
    func currentAgentState() -> AgentState {
        let changed = terminal?.consumeOutputSinceLastPoll() ?? false
        if changed || cachedAgentState == nil {
            cachedAgentState = agentState(fromOutput: outputSnapshot())
        }
        return cachedAgentState ?? .idle
    }

    /// Snapshot of the *visible* terminal text, for heuristic agent-state classification.
    /// Uses `getLine` (screen-relative, applies the scroll offset) — NOT `getText` with
    /// absolute rows, which would read the top of scrollback, not the live status line.
    func outputSnapshot() -> String {
        guard let term = terminal?.getTerminal() else { return "" }
        let rows = term.rows
        guard rows > 0 else { return "" }
        var out = ""
        for row in 0..<rows {
            if let line = term.getLine(row: row) {
                out += line.translateToString(trimRight: true) + "\n"
            }
        }
        return out
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Start the PTY only once bounds are known (viewDidAppear can fire at zero size).
        guard !processStarted, terminal.bounds.width > 0 else { return }
        processStarted = true
        let args = terminalShellArgs(workingDirectory: workingDirectory,
                                     setupScript: setupScript,
                                     command: command, shell: shell.name)
        // Build the PTY environment. `hookEnvironment` folds in the CODA_* hook-correlation
        // vars only when this surface is wired to the hook socket (non-empty ids), the bundled
        // zsh shell-integration (completions) whenever it's enabled, and the TERM/COLORTERM
        // defaults SwiftTerm would otherwise inject. These are INDEPENDENT: a scratch terminal,
        // or an app launched without a bundle id (so the hook socket never started), has empty
        // hook ids but must still get the ZDOTDIR injection — otherwise no OSC 133 markers ever
        // arrive and the completion popup never shows. So we always build and pass the env,
        // rather than gating the whole thing on the hook ids (which regressed completions to
        // hook-wired surfaces only).
        let dict = hookEnvironment(base: ProcessInfo.processInfo.environment,
                                   socketPath: hookSocketPath,
                                   worktreeID: hookWorktreeID, surfaceID: hookSurfaceID,
                                   shellIntegration: resolvedShellIntegrationEnv())
        let envArray = dict.map { "\($0.key)=\($0.value)" }
        terminal.startProcess(executable: shell.executablePath,
                              args: args,
                              environment: envArray,
                              execName: shell.loginArgv0,
                              currentDirectory: workingDirectory)
        if let pendingFont { applyFont(pendingFont) }
        if let pendingTheme { applyTheme(pendingTheme) }
    }

    /// Resolves the env additions that route this surface's shell through Coda's bundled
    /// OSC 133 wrapper (see `Sources/Coda/Resources/shell-integration/zsh` and
    /// `ShellIntegration.swift`). Silent-off (returns `[:]`) if the bundled wrapper can't be
    /// located — a spawn must never fail because of this.
    private func resolvedShellIntegrationEnv() -> [String: String] {
        // Zero overhead when the feature is off: skip the bundle lookup entirely.
        guard completionsEnabled else { return [:] }
        guard let bundleZdotdir = Bundle.codaBundledResource("shell-integration/zsh"),
              FileManager.default.fileExists(atPath: bundleZdotdir.appendingPathComponent(".zshrc").path)
        else { return [:] }
        let userZdotdir: URL
        if let existing = ProcessInfo.processInfo.environment["ZDOTDIR"], !existing.isEmpty {
            userZdotdir = URL(fileURLWithPath: existing)
        } else {
            userZdotdir = FileManager.default.homeDirectoryForCurrentUser
        }
        return shellIntegrationEnv(enabled: true, shell: shell,
                                   bundleZdotdir: bundleZdotdir, userZdotdir: userZdotdir)
    }
}

extension TerminalSurface: LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        terminalTitle = title
        onTitleChange?(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        terminal.currentDirectory = directory
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {}
}

/// Conformance is satisfied entirely by accessors declared above (`promptPhase`,
/// `isTerminalFocused`, `isScrolledToBottom`, `currentDirectoryURL`, `commandLineToCursor()`) —
/// this only declares the relationship the controller depends on.
extension TerminalSurface: CompletionSurface {}
