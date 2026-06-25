import AppKit
import ConductorCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var splitVC: NSSplitViewController!
    private let sidebar = SidebarController()
    private let detail = NSViewController()      // hosts the persistent terminal surfaces
    private var store: WorktreeStore!
    private var currentSurface: TerminalSurface?
    private var selectedWorktree: Worktree?
    // Keeps each worktree's terminal alive across sidebar switches; the handle is
    // the TerminalSurface itself.
    private let surfaces = SurfaceRegistry<TerminalSurface>()
    // Toolbar centre-notch: shows time + focused worktree (agent badge wired in #11).
    private let notchLabel = NSTextField(labelWithString: "No worktree")
    private let notchIcon = NSImageView()
    private var notchTimer: Timer?
    private var prefsStore: PreferencesStore!
    private var preferences = Preferences()
    private var clickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = makeStore()
        let home = FileManager.default.homeDirectoryForCurrentUser
        prefsStore = PreferencesStore(url: home.appendingPathComponent(".conductor/preferences.json"))
        preferences = prefsStore.load()
        buildMenu()
        buildWindow()
        wireSidebar()
        refreshSidebar(select: store.state.worktrees.first?.id)
        // Keep the notch clock current.
        notchTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.updateNotch()
        }
        // iTerm-style ⌘+click to open a path:line in the editor, routed to the focused surface.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.modifierFlags.contains(.command), event.window === self.window,
                  let surface = self.currentSurface else { return event }
            return surface.handleCommandClick(event) ? nil : event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func makeStore() -> WorktreeStore {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = home.appendingPathComponent(".conductor/local.json")
        let worktreeRoot = home.appendingPathComponent(".conductor/worktrees").path
        return WorktreeStore(config: Config(url: configURL),
                             git: GitWorktree(gitPath: "/usr/bin/git"),
                             worktreeRoot: worktreeRoot)
    }

    private func buildWindow() {
        detail.view = NSView()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 180
        let detailItem = NSSplitViewItem(viewController: detail)
        splitVC = NSSplitViewController()
        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(detailItem)

        window = NSWindow(contentViewController: splitVC)
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.title = "Conductor"
        window.titleVisibility = .hidden

        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        updateNotch()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func wireSidebar() {
        sidebar.onSelect = { [weak self] s in self?.select(s) }
    }

    private func refreshSidebar(select id: String?) {
        let sections = groupWorktreesByRepository(repositories: store.state.repositories,
                                                  worktrees: store.state.worktrees)
        sidebar.reload(sections: sections, selectedWorktreeID: id)
    }

    private func openRepoSettings() {
        guard !store.state.repositories.isEmpty else {
            presentMessage("Add a repo first (Add Repo…).")
            return
        }
        let vc = RepoSettingsController(repos: store.state.repositories)
        vc.onSave = { [weak self] id, setup, allowlist in
            do { _ = try self?.store.updateRepository(id: id, setupScript: setup, copyAllowlist: allowlist) }
            catch { self?.presentError(error) }
        }
        splitVC.presentAsSheet(vc)
    }

    private func addRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add Repo"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { _ = try store.addRepository(path: url.path) }
        catch { presentError(error) }
    }

    private func newWorktree() {
        // Add to the repo implied by the sidebar selection, else the first repo.
        let targetRepoID = sidebar.currentRepoID()
        guard let repo = store.state.repositories.first(where: { $0.id == targetRepoID })
                ?? store.state.repositories.first else {
            presentMessage("Add a repo first (Add Repo…).")
            return
        }
        let title = promptForText(prompt: "Worktree title:", defaultValue: "New Worktree") ?? "New Worktree"
        do {
            let s = try store.createWorktree(repoID: repo.id, title: title)
            pendingSetupWorktreeIDs.insert(s.id)
            refreshSidebar(select: s.id)
            select(s)
        } catch { presentError(error) }
    }

    private func archive(_ s: Worktree) {
        do {
            try store.archiveWorktree(id: s.id, deleteBranch: true)
            // Tear down the archived worktree's surface (kills its PTY, no leak).
            if let surface = surfaces.evict(worktreeID: s.id) {
                surface.view.removeFromSuperview()
                surface.removeFromParent()
            }
            if shownWorktreeID == s.id { shownWorktreeID = nil; currentSurface = nil }
            refreshSidebar(select: store.state.worktrees.first?.id)
            select(store.state.worktrees.first)
        } catch { presentError(error) }
    }

    // Worktrees created in THIS app run, whose first terminal should run setupScript.
    private var pendingSetupWorktreeIDs: Set<String> = []

    private var shownWorktreeID: String?

    private func select(_ s: Worktree?) {
        guard shownWorktreeID != s?.id else { return }   // idempotent: ignore redundant reselects
        shownWorktreeID = s?.id
        selectedWorktree = s
        updateNotch()

        // Hide (don't destroy) the surface we're leaving — its PTY keeps running.
        if let activeID = surfaces.activeWorktreeID, let leaving = surfaces.handle(for: activeID) {
            leaving.view.isHidden = true
        }
        surfaces.setActive(s?.id)
        currentSurface = nil
        guard let s else { return }

        // Reuse the live surface if we've seen this worktree before; otherwise build one.
        let surface: TerminalSurface
        if let existing = surfaces.handle(for: s.id) {
            surface = existing
            surface.view.isHidden = false
        } else {
            let repo = store.state.repositories.first { $0.id == s.repoID }
            let isNewlyCreated = pendingSetupWorktreeIDs.contains(s.id)
            let setup = isNewlyCreated ? (repo?.setupScript ?? "") : ""
            pendingSetupWorktreeIDs.remove(s.id)
            // Shell-first: a worktree opens into a plain interactive shell (empty command).
            // Only a freshly created worktree whose repo opted into auto-launch runs Claude.
            let command = (isNewlyCreated && repo?.autoLaunchClaude == true) ? launchCommand(for: repo!) : ""
            surface = TerminalSurface(workingDirectory: s.worktreePath, command: command, setupScript: setup)
            surface.onOpenFile = { [weak self] path, line in self?.openInDefaultEditor(path: path, line: line) }
            surfaces.register(surface, for: s.id)
            detail.addChild(surface)
            surface.view.translatesAutoresizingMaskIntoConstraints = false
            detail.view.addSubview(surface.view)
            NSLayoutConstraint.activate([
                surface.view.topAnchor.constraint(equalTo: detail.view.topAnchor),
                surface.view.bottomAnchor.constraint(equalTo: detail.view.bottomAnchor),
                surface.view.leadingAnchor.constraint(equalTo: detail.view.leadingAnchor),
                surface.view.trailingAnchor.constraint(equalTo: detail.view.trailingAnchor),
            ])
        }
        currentSurface = surface
    }

    // MARK: - native menu bar

    private func buildMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Conductor",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openRepoSettingsAction), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Conductor",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Conductor",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // File menu — repositories live here
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        addItem(to: fileMenu, "Add Repository…", #selector(addRepoAction), "n", modifiers: [.command, .shift])
        fileItem.submenu = fileMenu

        // Edit menu — standard text editing (terminal copy/paste, etc.)
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        // View menu — sidebar toggle
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle Sidebar",
                         action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu

        // Worktree menu — the primary actions, mirroring the toolbar
        let wtItem = NSMenuItem()
        mainMenu.addItem(wtItem)
        let wtMenu = NSMenu(title: "Worktree")
        addItem(to: wtMenu, "New Worktree", #selector(newWorktreeAction), "n")
        addItem(to: wtMenu, "Launch Claude", #selector(launchClaudeAction), "r")
        addItem(to: wtMenu, "Open in Editor", #selector(openInAction), "o")
        wtMenu.addItem(.separator())
        addItem(to: wtMenu, "Archive Worktree", #selector(archiveSelectedAction), "\u{8}") // ⌘⌫
        wtItem.submenu = wtMenu

        // Window menu
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @discardableResult
    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                         modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        menu.addItem(item)
        return item
    }

    // MARK: - actions (shared by menu + toolbar)

    @objc private func newWorktreeAction() { newWorktree() }
    @objc private func addRepoAction() { addRepo() }
    @objc private func openRepoSettingsAction() { openRepoSettings() }

    @objc private func archiveSelectedAction() {
        guard let wt = selectedWorktree else { presentMessage("Select a worktree first."); return }
        archive(wt)
    }

    @objc private func openInAction() {
        guard let wt = selectedWorktree else { presentMessage("Select a worktree first."); return }
        openInDefaultEditor(path: wt.worktreePath, line: nil)
    }

    /// Opens the focused worktree's directory in any installed app the user picks (one-off).
    @objc private func openWithOtherAppAction() {
        guard let wt = selectedWorktree else { presentMessage("Select a worktree first."); return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let appURL = panel.url else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: wt.worktreePath)],
                                withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// Opens a path (worktree dir or file) in the configured default editor. Uses
    /// `/usr/bin/open` — reliable from both `swift run` and the bundled .app, where
    /// NSWorkspace deep-links can return -50. Line-jump via the editor's URL scheme.
    private func openInDefaultEditor(path: String, line: Int?) {
        let editor = preferences.defaultEditor
        if let line, let url = editorOpenURL(scheme: editor.urlScheme, path: path, line: line) {
            runOpen([url.absoluteString])
        } else {
            runOpen(["-b", editor.bundleID, path])
        }
    }

    private func runOpen(_ args: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = args
        do { try task.run() } catch { presentError(error) }
    }

    @objc private func launchClaudeAction() {
        guard let wt = selectedWorktree,
              let repo = store.state.repositories.first(where: { $0.id == wt.repoID }),
              let surface = currentSurface else {
            presentMessage("Select a worktree first.")
            return
        }
        surface.sendCommand(launchCommand(for: repo))
    }

    private static let notchTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    // Matches Supacode's MotivationalStatusView time-of-day glyphs.
    private func notchTimeStyle(hour: Int) -> (symbol: String, color: NSColor) {
        switch hour {
        case 6..<12: return ("sunrise.fill", .systemOrange)
        case 12..<17: return ("sun.max.fill", .systemYellow)
        case 17..<21: return ("sunset.fill", .systemPink)
        default: return ("moon.stars.fill", .systemIndigo)
        }
    }

    private func updateNotch() {
        let now = Date()
        let style = notchTimeStyle(hour: Calendar.current.component(.hour, from: now))
        notchIcon.image = NSImage(systemSymbolName: style.symbol, accessibilityDescription: nil)
        notchIcon.contentTintColor = style.color
        let time = Self.notchTimeFormatter.string(from: now).lowercased()
        let focus = selectedWorktree?.title ?? "No worktree"
        notchLabel.stringValue = "\(time) — \(focus)"
        notchLabel.textColor = .secondaryLabelColor
    }

    // MARK: - small helpers

    private func promptForText(prompt: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func presentError(_ error: Error) { presentMessage("\(error)") }

    private func presentMessage(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.runModal()
    }
}

// MARK: - Unified toolbar

private extension NSToolbarItem.Identifier {
    static let addRepository = NSToolbarItem.Identifier("addRepository")
    static let launchClaude = NSToolbarItem.Identifier("launchClaude")
    static let notch = NSToolbarItem.Identifier("notch")
    static let openIn = NSToolbarItem.Identifier("openIn")
}

extension AppDelegate: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .addRepository,
         .flexibleSpace, .notch, .flexibleSpace,
         .launchClaude, .openIn]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .addRepository:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Add Repository"
            item.toolTip = "Add Repository… (⇧⌘N)"
            item.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "Add Repository")
            item.target = self
            item.action = #selector(addRepoAction)
            item.isBordered = true
            return item

        case .launchClaude:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Launch Claude"
            item.toolTip = "Launch Claude (⌘R)"
            item.image = claudeMarkImage()
            item.target = self
            item.action = #selector(launchClaudeAction)
            item.isBordered = true
            return item

        case .notch:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = ""
            // The toolbar already gives each item a single rounded background, so the
            // notch content sits directly in it — no extra fill (that caused doubling).
            notchIcon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
            notchLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            notchLabel.lineBreakMode = .byTruncatingTail
            notchLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
            let stack = NSStackView(views: [notchIcon, notchLabel])
            stack.orientation = .horizontal
            stack.spacing = 6
            stack.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 8)
            item.view = stack
            return item

        case .openIn:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Open in"
            item.toolTip = "Open the worktree in \(preferences.defaultEditor.name) (⌘O)"
            item.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: "Open in")
            item.target = self
            item.action = #selector(openInAction)   // primary click → default editor
            let menu = NSMenu()
            let openDefault = NSMenuItem(title: "Open in \(preferences.defaultEditor.name)",
                                         action: #selector(openInAction), keyEquivalent: "")
            openDefault.target = self
            menu.addItem(openDefault)
            let openOther = NSMenuItem(title: "Open with Other App…",
                                       action: #selector(openWithOtherAppAction), keyEquivalent: "")
            openOther.target = self
            menu.addItem(openOther)
            item.menu = menu
            return item

        default:
            return nil
        }
    }
}
