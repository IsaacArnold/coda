import AppKit
import SwiftTerm

final class AppDelegate: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate {

    private var window: NSWindow!
    private var terminals: [ClickableTerminalView] = []
    private let statusLabel = NSTextField(labelWithString: "Ready. ⌘+click a file path in the terminal to open it in VS Code.")
    private var themes: [ITermTheme] = []
    private var themeIndex = 0
    private let themeButton = NSButton(title: "Theme: —", target: nil, action: nil)
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var splitView: NSSplitView!

    /// Package root, derived from this source file's location at compile time.
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)         // .../Sources/Spike/AppDelegate.swift
            .deletingLastPathComponent()        // .../Sources/Spike
            .deletingLastPathComponent()        // .../Sources
            .deletingLastPathComponent()        // .../swiftterm-spike
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadThemes()
        buildWindow()
        startShells()
        applyTheme(at: 0)
        installCommandClickMonitor()
        installKeyMonitor()
        distributeEvenly()
    }

    /// Intercept ⌘+left-click before it reaches the terminal view, so we can
    /// resolve a file path under the cursor and open it in VS Code.
    private func installCommandClickMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated {
                guard event.modifierFlags.contains(.command),
                      event.window === self.window,
                      let hit = self.window.contentView?.hitTest(event.locationInWindow),
                      let term = self.terminals.first(where: { hit.isDescendant(of: $0) || hit === $0 })
                else { return event }
                term.handleCommandClick(event)
                return nil   // consume the click
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - UI

    private func buildWindow() {
        let frame = NSRect(x: 0, y: 0, width: 1100, height: 680)
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Conductor — SwiftTerm Spike"
        window.center()

        let content = NSView(frame: frame)
        window.contentView = content

        // Top toolbar.
        let inject = NSButton(title: "Inject snippet (⌘ test path)", target: self, action: #selector(injectSnippet))
        themeButton.target = self
        themeButton.action = #selector(cycleTheme)
        let focusBtn = NSButton(title: "Focus other terminal", target: self, action: #selector(focusOther))
        let addBtn = NSButton(title: "+ Add pane", target: self, action: #selector(addPaneAction))
        let topBar = NSStackView(views: [inject, themeButton, focusBtn, addBtn])
        topBar.orientation = .horizontal
        topBar.spacing = 10
        topBar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(topBar)

        // Status bar.
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        content.addSubview(statusLabel)

        // Terminals side by side.
        splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        let split = splitView!

        for _ in 0..<2 { makePane() }
        content.addSubview(split)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: content.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            split.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            statusLabel.topAnchor.constraint(equalTo: split.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])

        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
    }

    /// Create a terminal view and add it to the split (does not start the shell).
    @discardableResult
    private func makePane() -> ClickableTerminalView {
        let index = terminals.count
        let term = ClickableTerminalView(frame: .zero)
        term.processDelegate = self
        term.fallbackDirectory = packageRoot.path
        term.log = { [weak self] msg in self?.setStatus("[term \(index)] \(msg)") }
        terminals.append(term)
        splitView.addArrangedSubview(term)
        return term
    }

    private func startPane(_ term: ClickableTerminalView) {
        term.startProcess(executable: "/bin/zsh",
                          args: ["-l"],
                          environment: nil,
                          execName: "-zsh",
                          currentDirectory: packageRoot.path)
    }

    private func startShells() {
        terminals.forEach(startPane)
        window.makeFirstResponder(terminals.first)
    }

    @objc private func addPaneAction() {
        let term = makePane()
        startPane(term)
        if !themes.isEmpty { applyTheme(at: themeIndex) }
        window.makeFirstResponder(term)
        distributeEvenly()
        setStatus("Added pane #\(terminals.count - 1) — now \(terminals.count) live PTYs in the split")
    }

    /// NSSplitView gives the first arranged subview all the width unless dividers
    /// are positioned explicitly. `setPosition(_:ofDividerAt:)` is the canonical way
    /// to lay panes out evenly; deferred so the split has a real width first.
    private func distributeEvenly() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.splitView.layoutSubtreeIfNeeded()
            let n = self.terminals.count
            guard n > 1 else { return }
            let dividerW = self.splitView.dividerThickness
            let usable = self.splitView.bounds.width - dividerW * CGFloat(n - 1)
            guard usable > 0 else { return }
            let paneW = usable / CGFloat(n)
            for i in 0..<(n - 1) {
                let pos = CGFloat(i + 1) * paneW + CGFloat(i) * dividerW
                self.splitView.setPosition(pos, ofDividerAt: i)
            }
        }
    }

    /// iTerm-style terminal keybinds, layered on top of SwiftTerm by sending
    /// control bytes to the PTY — exactly the "keybinds" feature in scope.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated {
                guard event.modifierFlags.contains(.command), event.window === self.window else { return event }
                if event.charactersIgnoringModifiers == "k" {        // ⌘K → clear screen
                    self.focusedTerminal.send([0x0C])                // Ctrl-L
                    self.setStatus("⌘K → sent Ctrl-L (clear) to focused terminal")
                    return nil
                }
                if event.keyCode == 51 {                             // ⌘⌫ → kill line
                    self.focusedTerminal.send([0x15])                // Ctrl-U
                    self.setStatus("⌘⌫ → sent Ctrl-U (kill line) to focused terminal")
                    return nil
                }
                return event
            }
        }
    }

    // MARK: - Themes

    private func loadThemes() {
        let dir = packageRoot.appendingPathComponent("Themes")
        for name in ["SpikeDark", "SpikeLight"] {
            let url = dir.appendingPathComponent(name + ".itermcolors")
            do {
                themes.append(try ITermTheme.load(from: url))
            } catch {
                NSLog("Failed to load theme \(name): \(error)")
            }
        }
    }

    private func applyTheme(at index: Int) {
        guard !themes.isEmpty else { return }
        themeIndex = index % themes.count
        let theme = themes[themeIndex]
        for term in terminals {
            term.installColors(theme.ansi)
            term.nativeForegroundColor = theme.foreground
            term.nativeBackgroundColor = theme.background
            term.caretColor = theme.cursor
        }
        themeButton.title = "Theme: \(theme.name) (click to cycle)"
        setStatus("Applied .itermcolors theme: \(theme.name)")
    }

    // MARK: - Actions

    @objc private func injectSnippet() {
        let snippet = "printf 'cmd+click this real path -> Sources/Spike/ClickableTerminalView.swift:30\\n'\n"
        focusedTerminal.send(txt: snippet)
        setStatus("Injected snippet into focused terminal via send(txt:)")
    }

    @objc private func cycleTheme() {
        applyTheme(at: themeIndex + 1)
    }

    @objc private func focusOther() {
        guard terminals.count == 2 else { return }
        let current = focusedTerminal
        let other = current === terminals[0] ? terminals[1] : terminals[0]
        window.makeFirstResponder(other)
        setStatus("Focused the other terminal")
    }

    private var focusedTerminal: ClickableTerminalView {
        if let fr = window.firstResponder as? ClickableTerminalView { return fr }
        // first responder may be a subview of the terminal; match by ancestry
        for term in terminals {
            if let fr = window.firstResponder as? NSView, fr.isDescendant(of: term) { return term }
        }
        return terminals.first!
    }

    private func setStatus(_ msg: String) {
        statusLabel.stringValue = msg
        NSLog("%@", msg)
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        MainActor.assumeIsolated {
            if let term = source as? ClickableTerminalView {
                term.currentDirectory = directory
            }
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated {
            setStatus("A shell exited (code \(exitCode.map(String.init) ?? "nil")).")
        }
    }
}
