import AppKit
import SwiftTerm
import ConductorCore

/// A view controller hosting one SwiftTerm terminal that runs `command` (via the
/// login shell) inside `workingDirectory`. If `setupScript` is non-empty it runs
/// before the command (visibly, once).
final class TerminalSurface: NSViewController {
    private let workingDirectory: String
    private let command: String
    private let setupScript: String
    private var terminal: ClickableTerminalView!

    /// Opens a ⌘-clicked `path:line` in the default editor (wired by AppDelegate).
    var onOpenFile: ((String, Int?) -> Void)?

    init(workingDirectory: String, command: String, setupScript: String = "") {
        self.workingDirectory = workingDirectory
        self.command = command
        self.setupScript = setupScript
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        terminal = ClickableTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        terminal.autoresizingMask = [.width, .height]
        terminal.fallbackDirectory = workingDirectory
        terminal.onOpenFile = { [weak self] path, line in self?.onOpenFile?(path, line) }
        view = terminal
    }

    private var processStarted = false

    /// Type `command` into the live shell (as if the user typed it + Return).
    /// Used by "Launch Claude" to start an agent in a shell-first worktree.
    func sendCommand(_ command: String) {
        guard processStarted else { return }
        terminal.send(txt: command + "\r")
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

    /// Snapshot of the visible terminal text, for heuristic agent-state classification.
    func outputSnapshot() -> String {
        guard let term = terminal?.getTerminal() else { return "" }
        let rows = term.rows, cols = term.cols
        guard rows > 0, cols > 0 else { return "" }
        return term.getText(start: Position(col: 0, row: 0), end: Position(col: cols - 1, row: rows - 1))
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Start the PTY only once bounds are known (viewDidAppear can fire at zero size).
        guard !processStarted, terminal.bounds.width > 0 else { return }
        processStarted = true
        let line = terminalLaunchLine(workingDirectory: workingDirectory,
                                      setupScript: setupScript,
                                      command: command)
        terminal.startProcess(executable: "/bin/zsh",
                              args: ["-i", "-c", line],
                              environment: nil,
                              execName: "-zsh",
                              currentDirectory: workingDirectory)
    }
}
