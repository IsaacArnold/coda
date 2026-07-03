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
    private var terminal: ClickableTerminalView!
    private var pendingTheme: TerminalTheme?
    private var pendingFont: NSFont?

    /// Opens a ⌘-clicked `path:line` in the default editor (wired by AppDelegate).
    var onOpenFile: ((String, Int?) -> Void)?
    /// The live terminal title (OSC 0/2, set by the shell/claude), used for the tab label.
    private(set) var terminalTitle: String = ""
    /// Fired when the terminal title changes, so the tab bar can relabel.
    var onTitleChange: ((String) -> Void)?
    /// Fired when this surface's terminal gains focus (forwarded from the terminal view).
    var onFocused: (() -> Void)?

    init(workingDirectory: String, command: String, setupScript: String = "",
         hookWorktreeID: String = "", hookSurfaceID: String = "", hookSocketPath: String = "") {
        self.workingDirectory = workingDirectory
        self.command = command
        self.setupScript = setupScript
        self.hookWorktreeID = hookWorktreeID
        self.hookSurfaceID = hookSurfaceID
        self.hookSocketPath = hookSocketPath
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        terminal = ClickableTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        terminal.autoresizingMask = [.width, .height]
        terminal.fallbackDirectory = workingDirectory
        terminal.onOpenFile = { [weak self] path, line in self?.onOpenFile?(path, line) }
        terminal.onBecomeFirstResponder = { [weak self] in self?.onFocused?() }
        terminal.processDelegate = self
        view = terminal
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
                                     command: command)
        // Inject the CODA_* hook-correlation vars only when we actually have a socket +
        // ids (a fully wired-up surface); otherwise pass nil so the shell inherits the
        // app's own environment unmodified, same as before this surface existed.
        var envArray: [String]? = nil
        if !hookSocketPath.isEmpty, !hookWorktreeID.isEmpty, !hookSurfaceID.isEmpty {
            let dict = hookEnvironment(base: ProcessInfo.processInfo.environment,
                                       socketPath: hookSocketPath,
                                       worktreeID: hookWorktreeID, surfaceID: hookSurfaceID)
            envArray = dict.map { "\($0.key)=\($0.value)" }
        }
        terminal.startProcess(executable: "/bin/zsh",
                              args: args,
                              environment: envArray,
                              execName: "-zsh",
                              currentDirectory: workingDirectory)
        if let pendingFont { applyFont(pendingFont) }
        if let pendingTheme { applyTheme(pendingTheme) }
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
