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
    private var pendingTheme: TerminalTheme?

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

    /// Forwarded from AppDelegate's ⌘+click monitor. Returns true if it opened something.
    @discardableResult
    func handleCommandClick(_ event: NSEvent) -> Bool {
        terminal?.handleCommandClick(event) ?? false
    }

    /// Whether a ⌘+click event lands inside this surface's visible terminal.
    func containsClick(_ event: NSEvent) -> Bool {
        terminal?.containsClick(event) ?? false
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
        let line = terminalLaunchLine(workingDirectory: workingDirectory,
                                      setupScript: setupScript,
                                      command: command)
        terminal.startProcess(executable: "/bin/zsh",
                              args: ["-i", "-c", line],
                              environment: nil,
                              execName: "-zsh",
                              currentDirectory: workingDirectory)
        if let pendingTheme { applyTheme(pendingTheme) }
    }
}
