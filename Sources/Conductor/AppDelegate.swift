import AppKit
import ConductorCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var splitVC: NSSplitViewController!
    private let sidebar = SidebarController()
    private let detail = NSViewController()      // hosts the persistent terminal surfaces
    private let worktreeBar = WorktreeBar()
    private let surfaceTabBar = SurfaceTabBar()
    private var surfaceSeq = 0   // monotonic id source for new surfaces
    private var store: WorktreeStore!
    private var currentSurface: TerminalSurface?
    private var selectedWorktree: Worktree?
    // Keeps each worktree's terminal alive across sidebar switches; the handle is
    // the TerminalSurface itself.
    private let surfaces = SurfaceRegistry<TerminalSurface>()
    // Toolbar centre-notch: time-of-day glyph + time only (worktree name/badge live in the identity bar).
    private let notchLabel = NSTextField(labelWithString: "No worktree")
    private let notchIcon = NSImageView()
    private let notchBadge = NSView()   // layer-drawn agent-state dot
    private var notchTimer: Timer?
    private var stateTimer: Timer?
    private var agentStates: [String: AgentState] = [:]
    private var prefsStore: PreferencesStore!
    private var preferences = Preferences()
    private var themeStore: ThemeStore!
    private var activeTheme: TerminalTheme!
    private let defaultThemeName = "Dracula"
    private var kbStore: KeybindingsStore!
    private var keybindings = Keybindings()
    private var clickMonitor: Any?
    private var settingsWC: NSWindowController?
    // Open-in toolbar item ref, so its icon/tooltip/menu track the chosen default editor.
    private weak var openInItem: NSMenuToolbarItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = makeStore()
        let home = FileManager.default.homeDirectoryForCurrentUser
        prefsStore = PreferencesStore(url: home.appendingPathComponent(".conductor/preferences.json"))
        preferences = prefsStore.load()
        themeStore = ThemeStore(directory: home.appendingPathComponent(".conductor/themes"))
        try? themeStore.seedIfEmpty(from: bundledThemeURLs())
        activeTheme = loadActiveTheme()
        kbStore = KeybindingsStore(url: home.appendingPathComponent(".conductor/keybindings.json"))
        keybindings = kbStore.load()
        buildMenu()
        buildWindow()
        wireSidebar()
        refreshSidebar(select: store.state.worktrees.first?.id)
        applyChromeTheme()
        // Keep the notch clock current.
        notchTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.updateNotch()
        }
        // Poll each live surface's output to drive the heuristic agent-state badges.
        stateTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            self?.pollAgentStates()
        }
        // iTerm-style ⌘+click to open a path:line in the editor, routed to the focused
        // surface. We swallow BOTH the down and up: SwiftTerm activates its own link
        // handler on mouseUp (default NSWorkspace.open → a -50 dialog for non-URL
        // tokens), so consuming the up keeps our editor open as the only handler.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self, event.modifierFlags.contains(.command), event.window === self.window,
                  let surface = self.currentSurface, surface.containsClick(event) else { return event }
            if event.type == .leftMouseDown { surface.handleCommandClick(event) }
            return nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The bundled starter `.itermcolors` shipped as app resources.
    private func bundledThemeURLs() -> [URL] {
        Bundle.module.urls(forResourcesWithExtension: "itermcolors", subdirectory: "Themes") ?? []
    }

    /// The active terminal theme: the user's chosen one, else the default, else a hard
    /// fallback so the app always has a theme to draw.
    private func loadActiveTheme() -> TerminalTheme {
        if let name = preferences.activeTheme, let theme = themeStore.loadTheme(named: name) { return theme }
        if let theme = themeStore.loadTheme(named: defaultThemeName) { return theme }
        // Last-resort fallback (themes dir empty / unreadable): plain black-on-white.
        return TerminalTheme(name: "Default",
                             ansi: Array(repeating: .black, count: 16),
                             foreground: .black, background: .white, cursor: .black)
    }

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
        detail.view.addSubview(worktreeBar)
        NSLayoutConstraint.activate([
            // Inset from the sidebar, right edge, and toolbar so the identity bar floats
            // with breathing room rather than butting up against the window chrome.
            worktreeBar.topAnchor.constraint(equalTo: detail.view.topAnchor, constant: 8),
            worktreeBar.leadingAnchor.constraint(equalTo: detail.view.leadingAnchor, constant: 8),
            // Right edge pulled in slightly more than the surface's -8 so the chip lines up with
            // the terminal's visible content edge (SwiftTerm reserves a gutter on the right).
            worktreeBar.trailingAnchor.constraint(equalTo: detail.view.trailingAnchor, constant: -16),
        ])
        worktreeBar.isHidden = true
        detail.view.addSubview(surfaceTabBar)
        NSLayoutConstraint.activate([
            surfaceTabBar.topAnchor.constraint(equalTo: worktreeBar.bottomAnchor, constant: 6),
            surfaceTabBar.leadingAnchor.constraint(equalTo: detail.view.leadingAnchor, constant: 8),
            surfaceTabBar.trailingAnchor.constraint(equalTo: detail.view.trailingAnchor, constant: -8),
        ])
        surfaceTabBar.isHidden = true
        surfaceTabBar.onNew = { [weak self] in self?.newSurface() }
        surfaceTabBar.onSelect = { [weak self] id in self?.activateSurface(id) }
        surfaceTabBar.onClose = { [weak self] id in self?.closeSurface(id) }
        surfaceTabBar.onContext = { [weak self] id, view in self?.showSurfaceContextMenu(id, anchor: view) }
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 180
        let detailItem = NSSplitViewItem(viewController: detail)
        splitVC = NSSplitViewController()
        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(detailItem)
        // Persist the user's dragged sidebar width across launches; a first-launch
        // default is applied below once the split view is laid out.
        splitVC.splitView.autosaveName = "MainSidebarSplit"

        window = NSWindow(contentViewController: splitVC)
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.title = "Conductor"
        window.titleVisibility = .hidden
        // Let the themed window background flow up through the titlebar/unified toolbar so the
        // toolbar blends into the terminal theme (spec: "toolbar adopts the terminal background").
        // Without this the unified toolbar keeps macOS's default material and reads as default-gray.
        window.titlebarAppearsTransparent = true

        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        updateNotch()
        window.center()
        window.makeKeyAndOrderFront(nil)
        // Default sidebar width on first launch (still freely draggable); the
        // autosave restores the user's own width on every launch after that.
        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames MainSidebarSplit") == nil {
            splitVC.splitView.setPosition(255, ofDividerAt: 0)
        }
    }

    private func wireSidebar() {
        sidebar.onSelect = { [weak self] s in self?.select(s) }
        sidebar.onRepoSettings = { [weak self] repoID in self?.openRepoSettings(repoID: repoID) }
        sidebar.onNewWorktree = { [weak self] repoID in self?.newWorktree(repoID: repoID) }
        sidebar.onSetWorktreeColor = { [weak self] worktreeID, hex in self?.setWorktreeColor(worktreeID, hex) }
        sidebar.onRemoveWorktreeColor = { [weak self] worktreeID in self?.setWorktreeColor(worktreeID, nil) }
        sidebar.onRenameRepo = { [weak self] repoID in self?.renameRepo(repoID) }
        sidebar.onSetRepoColor = { [weak self] repoID, hex in self?.setRepoColor(repoID, hex) }
        sidebar.onRemoveRepoColor = { [weak self] repoID in self?.setRepoColor(repoID, nil) }
    }

    /// Override a worktree's identity color and repaint its bar + sidebar row.
    private func setWorktreeColor(_ worktreeID: String, _ hex: String?) {
        do {
            _ = try store.setWorktreeColor(id: worktreeID, color: hex)
            refreshSidebar(select: selectedWorktree?.id)
            if worktreeID == selectedWorktree?.id {
                selectedWorktree = store.state.worktrees.first { $0.id == worktreeID }
                refreshChromeForActiveSurface()
            }
        } catch { presentError(error) }
    }

    /// Display-only rename of a repository (blank input clears the override).
    private func renameRepo(_ repoID: String) {
        guard let repo = store.state.repositories.first(where: { $0.id == repoID }),
              let input = promptForText(prompt: "Repository name:", defaultValue: repo.sidebarDisplayName)
        else { return }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try store.setRepositoryDisplayName(id: repoID, displayName: trimmed.isEmpty ? nil : trimmed)
            refreshSidebar(select: selectedWorktree?.id)
        } catch { presentError(error) }
    }

    /// Set or clear a repository's identity color and repaint the sidebar.
    private func setRepoColor(_ repoID: String, _ hex: String?) {
        do {
            _ = try store.setRepositoryColor(id: repoID, color: hex)
            refreshSidebar(select: selectedWorktree?.id)
        } catch { presentError(error) }
    }

    private func refreshSidebar(select id: String?) {
        let sections = groupWorktreesByRepository(repositories: store.state.repositories,
                                                  worktrees: store.state.worktrees)
        sidebar.reload(sections: sections, selectedWorktreeID: id)
    }

    /// Refresh and highlight a repository header (e.g. a freshly added repo with no
    /// worktrees yet, which has no worktree row to select).
    private func refreshSidebar(selectRepo id: String?) {
        let sections = groupWorktreesByRepository(repositories: store.state.repositories,
                                                  worktrees: store.state.worktrees)
        sidebar.reload(sections: sections, selectedWorktreeID: nil, selectedRepoID: id)
    }

    /// Per-repo settings, opened as a sheet from that repo in the sidebar (right-click).
    private func openRepoSettings(repoID: String) {
        guard let repo = store.state.repositories.first(where: { $0.id == repoID }) else { return }
        let vc = RepoSettingsController(repo: repo)
        vc.onSave = { [weak self] id, setup, allowlist, autoLaunch in
            do {
                _ = try self?.store.updateRepository(id: id, setupScript: setup,
                                                     copyAllowlist: allowlist, autoLaunchClaude: autoLaunch)
            } catch { self?.presentError(error) }
        }
        splitVC.presentAsSheet(vc)
    }

    private func openSettings() {
        if settingsWC == nil {
            let tab = SettingsTabController(
                editor: preferences.defaultEditor,
                onChangeEditor: { [weak self] editor in self?.setDefaultEditor(editor) },
                keybindings: keybindings,
                onChange: { [weak self] bindings in self?.applyKeybindings(bindings) },
                themeNames: themeStore.themeNames(),
                activeTheme: preferences.activeTheme ?? defaultThemeName,
                onApplyTheme: { [weak self] name in self?.setActiveTheme(named: name) },
                onImportTheme: { [weak self] url in try? self?.themeStore.importTheme(from: url) },
                terminalFont: resolvedTerminalFont(),
                onChangeFont: { [weak self] pref in self?.setTerminalFont(pref) })
            let win = NSWindow(contentViewController: tab)
            win.title = "Settings"
            win.styleMask = [.titled, .closable]
            win.toolbarStyle = .preference
            win.titlebarAppearsTransparent = true   // let the themed bg flow into the tab strip
            win.isReleasedWhenClosed = false
            settingsWC = NSWindowController(window: win)
        }
        // Match the active theme each time it opens (the window is cached, so re-apply here).
        if let win = settingsWC?.window {
            applyWindowChrome(ChromeTheme(terminal: activeTheme), to: win)
        }
        settingsWC?.window?.center()
        settingsWC?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setDefaultEditor(_ editor: Editor) {
        preferences.defaultEditor = editor
        do { try prefsStore.save(preferences) } catch { presentError(error) }
        // Keep the Open-in control's tooltip + icon + menu in sync with the chosen editor.
        openInItem?.toolTip = "Open the worktree in \(editor.name) (⌘O)"
        rebuildOpenInMenu()
    }

    /// An installed app's Finder icon, sized for a menu/toolbar; nil if the app isn't installed.
    private func appIcon(bundleID: String, size: CGFloat = 16) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: size, height: size)
        return icon
    }

    /// Populate the Open-in control like Supacode: the toolbar button shows the default
    /// editor's app icon, and the dropdown lists every installed known editor with its
    /// icon + name (a checkmark on the current default), then "Open with Other App…".
    private func rebuildOpenInMenu() {
        guard let item = openInItem else { return }
        item.image = appIcon(bundleID: preferences.defaultEditor.bundleID, size: 18)
            ?? NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: "Open in")
        let menu = NSMenu()
        for editor in Editor.knownEditors {
            guard let icon = appIcon(bundleID: editor.bundleID) else { continue }   // installed only
            let mi = NSMenuItem(title: "Open in \(editor.name)",
                                action: #selector(openInSpecificEditor(_:)), keyEquivalent: "")
            mi.target = self
            mi.image = icon
            mi.representedObject = editor.bundleID
            mi.state = (editor.bundleID == preferences.defaultEditor.bundleID) ? .on : .off
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let openOther = NSMenuItem(title: "Open with Other App…",
                                   action: #selector(openWithOtherAppAction), keyEquivalent: "")
        openOther.target = self
        menu.addItem(openOther)
        item.menu = menu
    }

    /// Open the selected worktree in a specific known editor (one-off; doesn't change the default).
    @objc private func openInSpecificEditor(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        guard let wt = selectedWorktree else { presentMessage("Select a worktree first."); return }
        runOpen(["-b", bundleID, wt.worktreePath])
    }

    private func addRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add Repo"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Refresh + highlight so the added repo is visibly there (it returns the
            // existing one if already added, which highlights it just the same).
            let repo = try store.addRepository(path: url.path)
            refreshSidebar(selectRepo: repo.id)
        }
        catch { presentError(error) }
    }

    private func newWorktree(repoID: String? = nil) {
        // Add to the given repo (sidebar right-click), else the one implied by the
        // selection, else the first repo.
        let targetRepoID = repoID ?? sidebar.currentRepoID()
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
        // Archiving deletes the branch too and can't be undone — confirm first.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Archive “\(s.title)”?"
        alert.informativeText = "This removes the worktree and deletes its branch (\(s.branch)). This can’t be undone."
        alert.addButton(withTitle: "Archive")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.archiveWorktree(id: s.id, deleteBranch: true)
            // Tear down all of the archived worktree's surfaces (kills every PTY, no leak).
            for surface in surfaces.evict(worktreeID: s.id) {
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
        guard shownWorktreeID != s?.id else { return }   // idempotent
        shownWorktreeID = s?.id
        selectedWorktree = s
        updateNotch()

        // Hide (don't destroy) the leaving worktree's active surface — its PTY keeps running.
        if let leavingID = surfaces.activeWorktreeID,
           let leaving = surfaces.existingSurfaces(for: leavingID)?.activeHandle {
            leaving.view.isHidden = true
        }
        surfaces.setActive(s?.id)
        currentSurface = nil

        guard let s else {
            worktreeBar.update(title: nil, branch: nil, colorHex: nil, agentState: .idle)
            surfaceTabBar.isHidden = true
            return
        }

        let list = surfaces.surfaces(for: s.id)
        if list.isEmpty {
            // First open (or re-focus after the last tab was closed): spawn one shell.
            createSurface(in: s, runSetupAndAutoLaunch: true)
        } else if let active = list.activeHandle {
            active.view.isHidden = false
            currentSurface = active
        }
        refreshChromeForActiveSurface()
        refreshTabBar()
    }

    /// Build a fresh TerminalSurface for `wt`, register it, install it in the detail view,
    /// make it the active surface, and focus it. `runSetupAndAutoLaunch` is true only for the
    /// worktree's very first surface (mirrors the old first-open behavior: setupScript +
    /// optional auto-launch Claude); additional tabs are always plain shells.
    @discardableResult
    private func createSurface(in wt: Worktree, runSetupAndAutoLaunch: Bool) -> TerminalSurface {
        let repo = store.state.repositories.first { $0.id == wt.repoID }
        let isNewlyCreated = runSetupAndAutoLaunch && pendingSetupWorktreeIDs.contains(wt.id)
        let setup = isNewlyCreated ? (repo?.setupScript ?? "") : ""
        pendingSetupWorktreeIDs.remove(wt.id)
        let command = (isNewlyCreated && repo?.autoLaunchClaude == true) ? launchCommand(for: repo!) : ""

        let surface = TerminalSurface(workingDirectory: wt.worktreePath, command: command, setupScript: setup)
        surface.onOpenFile = { [weak self] path, line in self?.openInDefaultEditor(path: path, line: line) }
        surface.onTitleChange = { [weak self] _ in self?.refreshTabBar() }
        surface.applyTheme(activeTheme)
        surface.applyFont(resolvedTerminalFont())

        surfaceSeq += 1
        let id = "surface-\(surfaceSeq)"
        let list = surfaces.surfaces(for: wt.id)
        // Hide the current active surface (we're inserting after it and switching to the new one).
        list.activeHandle?.view.isHidden = true
        list.add(surface, surface: Surface(id: id))

        detail.addChild(surface)
        surface.view.translatesAutoresizingMaskIntoConstraints = false
        detail.view.addSubview(surface.view)
        NSLayoutConstraint.activate([
            surface.view.topAnchor.constraint(equalTo: surfaceTabBar.bottomAnchor, constant: 6),
            surface.view.bottomAnchor.constraint(equalTo: detail.view.bottomAnchor),
            surface.view.leadingAnchor.constraint(equalTo: detail.view.leadingAnchor, constant: 8),
            surface.view.trailingAnchor.constraint(equalTo: detail.view.trailingAnchor, constant: -8),
        ])
        currentSurface = surface
        view(focus: surface)
        refreshChromeForActiveSurface()
        refreshTabBar()
        return surface
    }

    /// Switch the shown worktree's active surface to `id`: hide the old, show the new, focus it.
    private func activateSurface(_ id: String) {
        guard let wtID = shownWorktreeID, let list = surfaces.existingSurfaces(for: wtID),
              list.activeSurfaceID != id, let handle = list.handle(for: id) else { return }
        list.activeHandle?.view.isHidden = true
        list.setActive(id: id)
        handle.view.isHidden = false
        currentSurface = handle
        view(focus: handle)
        refreshChromeForActiveSurface()
        refreshTabBar()
    }

    private func view(focus surface: TerminalSurface) {
        window.makeFirstResponder(surface.view)
    }

    /// Rebuild the tab bar from the shown worktree's surface list.
    private func refreshTabBar() {
        guard let wtID = shownWorktreeID, let list = surfaces.existingSurfaces(for: wtID),
              !list.isEmpty else {
            surfaceTabBar.isHidden = true
            return
        }
        surfaceTabBar.isHidden = false
        let worktreeColor = selectedWorktree?.color.flatMap { RGB(hex: $0) }
        let items: [SurfaceTabItem] = list.entries.enumerated().map { idx, entry in
            let effective = entry.surface.effectiveColor(worktreeColor: worktreeColor)
            return SurfaceTabItem(
                id: entry.surface.id,
                label: surfaceLabel(nameOverride: entry.surface.nameOverride,
                                    terminalTitle: entry.handle.terminalTitle, index: idx),
                state: agentStates[surfaceKey(wtID, entry.surface.id)] ?? .idle,
                isActive: entry.surface.id == list.activeSurfaceID,
                tint: effective?.nsColor)
        }
        surfaceTabBar.update(items: items)
    }

    /// Composite key for the per-surface agent-state map (Task 10 populates it).
    private func surfaceKey(_ worktreeID: String, _ surfaceID: String) -> String {
        "\(worktreeID)#\(surfaceID)"
    }

    private func newSurface() {
        guard let wt = selectedWorktree else { presentMessage("Select a worktree first."); return }
        createSurface(in: wt, runSetupAndAutoLaunch: false)
    }

    /// Close a specific surface (defaults to the active one). Confirms if it looks busy
    /// (non-idle agent state). Closing the last surface leaves the worktree empty.
    private func closeSurface(_ id: String? = nil) {
        guard let wtID = shownWorktreeID, let list = surfaces.existingSurfaces(for: wtID) else { return }
        guard let targetID = id ?? list.activeSurfaceID else { return }
        let state = agentStates[surfaceKey(wtID, targetID)] ?? .idle
        if state != .idle {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Close this tab?"
            alert.informativeText = "A process is still running in this tab. Closing it ends that process."
            alert.addButton(withTitle: "Close Tab")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if let removed = list.close(id: targetID) {
            removed.view.removeFromSuperview()
            removed.removeFromParent()
        }
        if let newActive = list.activeHandle {
            newActive.view.isHidden = false
            currentSurface = newActive
            view(focus: newActive)
        } else {
            // Last tab closed: worktree is now empty. Allow re-focus to spawn a fresh shell.
            currentSurface = nil
            shownWorktreeID = nil
            surfaces.setActive(nil)
        }
        refreshChromeForActiveSurface()
        refreshTabBar()
    }

    private func nextSurface() {
        guard let wtID = shownWorktreeID, let list = surfaces.existingSurfaces(for: wtID),
              let id = list.next() else { return }
        activateSurfaceAfterListMove(id, in: list)
    }

    private func prevSurface() {
        guard let wtID = shownWorktreeID, let list = surfaces.existingSurfaces(for: wtID),
              let id = list.prev() else { return }
        activateSurfaceAfterListMove(id, in: list)
    }

    private func goToSurface(_ oneBased: Int) {
        guard let wtID = shownWorktreeID, let list = surfaces.existingSurfaces(for: wtID),
              let id = list.goTo(index: oneBased - 1) else { return }
        activateSurfaceAfterListMove(id, in: list)
    }

    /// `next/prev/goTo` already moved the list's active id; reflect it in the views.
    private func activateSurfaceAfterListMove(_ id: String, in list: WorktreeSurfaces<TerminalSurface>) {
        for entry in list.entries { entry.handle.view.isHidden = (entry.surface.id != id) }
        currentSurface = list.handle(for: id)
        if let h = currentSurface { view(focus: h) }
        refreshChromeForActiveSurface()
        refreshTabBar()
    }

    /// Repaint the identity bar from the shown worktree + active surface's effective color.
    private func refreshChromeForActiveSurface() {
        guard let wt = selectedWorktree else {
            worktreeBar.update(title: nil, branch: nil, colorHex: nil, agentState: .idle)
            return
        }
        let worktreeColor = wt.color.flatMap { RGB(hex: $0) }
        let active = surfaces.existingSurfaces(for: wt.id)?.activeSurface
        let effective = active?.effectiveColor(worktreeColor: worktreeColor) ?? worktreeColor
        worktreeBar.update(title: wt.title, branch: wt.branch,
                           colorHex: effective?.hexString,
                           agentState: agentStates[wt.id] ?? .idle)
    }

    /// No-op placeholder for the context menu (Task 9 implements rename/color/duplicate).
    private func showSurfaceContextMenu(_ id: String, anchor: NSView) {}

    // MARK: - theming

    /// Switch the global terminal theme: persist the choice, reload it, re-theme
    /// every live terminal and the chrome.
    private func setActiveTheme(named name: String) {
        guard let theme = themeStore.loadTheme(named: name) else { return }
        activeTheme = theme
        preferences.activeTheme = name
        do { try prefsStore.save(preferences) } catch { presentError(error) }
        applyActiveTheme()
    }

    /// Push the active terminal theme to every live surface and repaint the chrome.
    private func applyActiveTheme() {
        for wtID in surfaces.worktreeIDs {
            surfaces.existingSurfaces(for: wtID)?.handles.forEach { $0.applyTheme(activeTheme) }
        }
        applyChromeTheme()
    }

    /// The bundled "Symbols Nerd Font Mono", registered for this process for use as a glyph
    /// fallback; resolves to its PostScript name once (nil if the resource is missing).
    private static let nerdFallbackFontName: String? = {
        guard let url = Bundle.module.url(forResource: "SymbolsNerdFontMono-Regular",
                                          withExtension: "ttf", subdirectory: "Resources") else { return nil }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descs.first,
              let name = CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String else { return nil }
        return name
    }()

    /// The configured terminal font (or the default monospaced font), augmented with the
    /// bundled Nerd Font as a *cascade fallback* so powerline / icon glyphs render even when
    /// the chosen font lacks them. The base font is untouched — fallback only fills glyphs the
    /// base font is missing, so e.g. Dank Mono's own characters render from Dank Mono.
    private func resolvedTerminalFont() -> NSFont {
        let base: NSFont = {
            if let pref = preferences.terminalFont, let font = NSFont(name: pref.name, size: CGFloat(pref.size)) {
                return font
            }
            return .monospacedSystemFont(ofSize: 13, weight: .regular)
        }()
        guard let nerdName = Self.nerdFallbackFontName else { return base }
        let nerdDescriptor = NSFontDescriptor(fontAttributes: [.name: nerdName])
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: [nerdDescriptor]])
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }

    /// Persist a new terminal font and re-apply it to every live surface.
    private func setTerminalFont(_ pref: TerminalFontPref) {
        preferences.terminalFont = pref
        do { try prefsStore.save(preferences) } catch { presentError(error) }
        let font = resolvedTerminalFont()
        for wtID in surfaces.worktreeIDs {
            surfaces.existingSurfaces(for: wtID)?.handles.forEach { $0.applyFont(font) }
        }
    }

    /// iTerm2-style: the window blends into the terminal background and flips
    /// light/dark by its luminance. All chrome colors read from ChromeTheme.
    private func applyChromeTheme() {
        let chrome = ChromeTheme(terminal: activeTheme)
        applyWindowChrome(chrome, to: window)
        sidebar.applyChrome(chrome)
        updateNotch()
        // Re-theme the Settings window too, if it's open (e.g. theme switched from its Themes tab).
        if let settings = settingsWC?.window { applyWindowChrome(chrome, to: settings) }
    }

    /// Apply the derived chrome (appearance + background) to a window so it blends into the
    /// active terminal theme. Shared by the main window and the Settings window.
    private func applyWindowChrome(_ chrome: ChromeTheme, to window: NSWindow) {
        window.appearance = chrome.appearance.nsAppearance
        window.backgroundColor = chrome.color(.windowBackground).nsColor
    }

    // MARK: - native menu bar

    /// Set an NSMenuItem's key equivalent from the command's effective chord (none if disabled).
    private func apply(_ command: ShortcutCommand, to item: NSMenuItem) {
        if let chord = keybindings.effectiveChord(for: command) {
            item.keyEquivalent = chord.key
            item.keyEquivalentModifierMask = chord.modifiers.eventModifierFlags
        } else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }

    /// Persist new bindings and rebuild the menu so shortcuts update live.
    func applyKeybindings(_ bindings: Keybindings) {
        keybindings = bindings
        do { try kbStore.save(bindings) } catch { presentError(error) }
        rebuildMenu()
    }

    private func rebuildMenu() { buildMenu() }

    private func buildMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Conductor",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = addItem(to: appMenu, "Settings…", #selector(openSettingsAction),
                                   command: .openSettings)
        _ = settingsItem
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
        addItem(to: fileMenu, "Add Repository…", #selector(addRepoAction), command: .addRepository)
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
        let sidebarItem = addItem(to: viewMenu, "Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)),
                                  command: .toggleSidebar)
        sidebarItem.target = nil
        viewItem.submenu = viewMenu

        // Worktree menu — the primary actions, mirroring the toolbar
        let wtItem = NSMenuItem()
        mainMenu.addItem(wtItem)
        let wtMenu = NSMenu(title: "Worktree")
        addItem(to: wtMenu, "New Worktree", #selector(newWorktreeAction), command: .newWorktree)
        addItem(to: wtMenu, "Launch Claude", #selector(launchClaudeAction), command: .launchClaude)
        addItem(to: wtMenu, "Open in Editor", #selector(openInAction), command: .openInEditor)
        addItem(to: wtMenu, "Reveal in Finder", #selector(revealInFinderAction), command: .revealInFinder)
        wtMenu.addItem(.separator())
        addItem(to: wtMenu, "Archive Worktree", #selector(archiveSelectedAction), command: .archiveWorktree)
        wtItem.submenu = wtMenu

        // Surface menu — per-worktree terminal tabs
        let surfaceItem = NSMenuItem()
        mainMenu.addItem(surfaceItem)
        let surfaceMenu = NSMenu(title: "Surface")
        addItem(to: surfaceMenu, "New Tab", #selector(newSurfaceAction), command: .newSurface)
        addItem(to: surfaceMenu, "Close Tab", #selector(closeSurfaceAction), command: .closeSurface)
        addItem(to: surfaceMenu, "Split Surface", #selector(splitSurfaceAction), command: .splitSurface)
        surfaceMenu.addItem(.separator())
        addItem(to: surfaceMenu, "Next Tab", #selector(nextSurfaceAction), command: .nextSurface)
        addItem(to: surfaceMenu, "Previous Tab", #selector(prevSurfaceAction), command: .prevSurface)
        surfaceMenu.addItem(.separator())
        let gotoCommands: [(ShortcutCommand, Int)] = [
            (.goToSurface1, 1), (.goToSurface2, 2), (.goToSurface3, 3), (.goToSurface4, 4),
            (.goToSurface5, 5), (.goToSurface6, 6), (.goToSurface7, 7), (.goToSurface8, 8),
            (.goToSurface9, 9)]
        for (cmd, n) in gotoCommands {
            let item = NSMenuItem(title: "Go to Tab \(n)", action: #selector(goToSurfaceAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = n
            apply(cmd, to: item)
            surfaceMenu.addItem(item)
        }
        surfaceItem.submenu = surfaceMenu

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
    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector,
                         command: ShortcutCommand) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        apply(command, to: item)
        menu.addItem(item)
        return item
    }

    // MARK: - actions (shared by menu + toolbar)

    @objc private func newWorktreeAction() { newWorktree() }
    @objc private func addRepoAction() { addRepo() }
    @objc private func openSettingsAction() { openSettings() }

    @objc private func archiveSelectedAction() {
        guard let wt = selectedWorktree else { presentMessage("Select a worktree first."); return }
        archive(wt)
    }

    @objc private func openInAction() {
        guard let wt = selectedWorktree else { presentMessage("Select a worktree first."); return }
        openInDefaultEditor(path: wt.worktreePath, line: nil)
    }

    @objc private func revealInFinderAction() {
        guard let wt = selectedWorktree else { presentMessage("Select a worktree first."); return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: wt.worktreePath)])
    }

    @objc private func newSurfaceAction() { newSurface() }
    @objc private func closeSurfaceAction() { closeSurface() }
    @objc private func nextSurfaceAction() { nextSurface() }
    @objc private func prevSurfaceAction() { prevSurface() }
    @objc private func goToSurfaceAction(_ sender: NSMenuItem) { goToSurface(sender.tag) }
    /// Reserved for PR B (splits). No-op in PR A.
    @objc private func splitSurfaceAction() { /* PR B */ }

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
        if let line, !editor.urlScheme.isEmpty,
           let url = editorOpenURL(scheme: editor.urlScheme, path: path, line: line) {
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

    private func pollAgentStates() {
        var states: [String: AgentState] = [:]
        for wtID in surfaces.worktreeIDs {
            let active = surfaces.existingSurfaces(for: wtID)?.activeHandle
            states[wtID] = active.map { agentState(fromOutput: $0.outputSnapshot()) } ?? .idle
        }
        agentStates = states
        sidebar.updateAgentStates(states)
        updateNotch()
        refreshChromeForActiveSurface()
    }

    private func updateNotch() {
        let now = Date()
        let style = notchTimeStyle(hour: Calendar.current.component(.hour, from: now))
        notchIcon.image = NSImage(systemSymbolName: style.symbol, accessibilityDescription: nil)
        notchIcon.contentTintColor = style.color
        let time = Self.notchTimeFormatter.string(from: now).lowercased()
        notchLabel.stringValue = time
        notchLabel.textColor = (ChromeTheme(terminal: activeTheme).color(.secondaryText).nsColor)
        notchBadge.isHidden = true
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
        // No sidebar-tracking separator: it pins the notch's flexible space to the content
        // region, so the notch drifts as the sidebar resizes. Centring it between the left
        // (toggle+add) and right (launch+open) groups keeps it put in window coordinates.
        [.toggleSidebar, .addRepository,
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
            // Match Supacode's notch (MotivationalStatusView): a `.callout`-sized
            // time-of-day glyph + `.footnote`, monospaced status text.
            notchIcon.symbolConfiguration = .init(
                pointSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
            notchLabel.font = .monospacedSystemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
            notchLabel.lineBreakMode = .byTruncatingTail
            notchLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
            notchBadge.wantsLayer = true
            notchBadge.layer?.cornerRadius = 4
            notchBadge.translatesAutoresizingMaskIntoConstraints = false
            notchBadge.widthAnchor.constraint(equalToConstant: 8).isActive = true
            notchBadge.heightAnchor.constraint(equalToConstant: 8).isActive = true
            let stack = NSStackView(views: [notchIcon, notchLabel, notchBadge])
            stack.orientation = .horizontal
            stack.spacing = 6
            stack.edgeInsets = NSEdgeInsets(top: 3, left: 12, bottom: 3, right: 12)
            item.view = stack
            return item

        case .openIn:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Open in"
            item.toolTip = "Open the worktree in \(preferences.defaultEditor.name) (⌘O)"
            item.target = self
            item.action = #selector(openInAction)   // primary click → default editor
            openInItem = item
            rebuildOpenInMenu()   // sets the default app's icon + the per-app dropdown
            return item

        default:
            return nil
        }
    }
}
