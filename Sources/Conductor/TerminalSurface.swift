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
    private var terminal: LocalProcessTerminalView!

    init(workingDirectory: String, command: String, setupScript: String = "") {
        self.workingDirectory = workingDirectory
        self.command = command
        self.setupScript = setupScript
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        terminal.autoresizingMask = [.width, .height]
        view = terminal
    }

    private var processStarted = false

    /// Type `command` into the live shell (as if the user typed it + Return).
    /// Used by "Launch Claude" to start an agent in a shell-first worktree.
    func sendCommand(_ command: String) {
        guard processStarted else { return }
        terminal.send(txt: command + "\r")
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
