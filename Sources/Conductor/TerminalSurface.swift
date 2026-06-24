import AppKit
import SwiftTerm

/// A view controller hosting one SwiftTerm terminal that runs `command` (via the
/// login shell) inside `workingDirectory`. For the slice, command defaults to `claude`.
final class TerminalSurface: NSViewController {
    private let workingDirectory: String
    private let command: String
    private var terminal: LocalProcessTerminalView!

    init(workingDirectory: String, command: String) {
        self.workingDirectory = workingDirectory
        self.command = command
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        terminal.autoresizingMask = [.width, .height]
        view = terminal
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard terminal.bounds.width > 0 else { return }
        // Run an interactive zsh that execs the command, so the user keeps a shell
        // after the command exits. `-i -c` keeps it interactive.
        let line = "cd \(shellQuote(workingDirectory)) && exec \(command)"
        terminal.startProcess(executable: "/bin/zsh",
                              args: ["-i", "-c", line],
                              environment: nil,
                              execName: "-zsh",
                              currentDirectory: workingDirectory)
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
