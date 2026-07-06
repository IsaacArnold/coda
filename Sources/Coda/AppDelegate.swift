import AppKit
import UserNotifications
import CodaCore

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var window: NSWindow!
    private var splitVC: NSSplitViewController!
    private let sidebar = SidebarController()
    private let detail = NSViewController()      // hosts the persistent terminal surfaces
    private let worktreeBar = WorktreeBar()
    private let surfaceTabBar = SurfaceTabBar()
    private var surfaceSeq = 0   // monotonic id source for new surfaces
    private var store: WorktreeStore!
    private var currentSurface: SplitSurface?
    private var selectedWorktree: Worktree?
    private var diffPane: DiffPaneViewController!
    private var diffPaneItem: NSSplitViewItem!
    /// Coalesces bursts of "files changed" signals (hook events, HEAD moves) into one
    /// `refreshDiffPane()` ~0.4s after the last signal, instead of recomputing per event.
    private var diffRefreshWork: DispatchWorkItem?
    /// Per-worktree debounce for `recomputeDiffStats(for:)` from the hook-event path. Claude
    /// fires `PostToolUse` in bursts, so without this a burst spawns N redundant git
    /// subprocesses per worktree, and `.utility`-queue scheduling jitter can let an
    /// earlier-dispatched compute finish after a later one and clobber
    /// `diffStatsByWorktree[wt.id]` with a stale value. Keyed by worktree id; main-thread-only
    /// (scheduled from `handleHookEvent`, which always runs on main — see
    /// `AgentHookSocketServer`'s `DispatchQueue.main.async` around its event callback).
    private var statsRecomputeWork: [String: DispatchWorkItem] = [:]
    /// repoID → current branch of its main checkout, kept fresh by `headWatcher`.
    private var currentBranches: [String: String] = [:]
    /// worktree id → cheap +/- line counts, shown in the sidebar and mirrored in the
    /// WorktreeBar for the active worktree — both views read this SAME cache so they
    /// always agree. Populated by the launch sweep and kept live by the diff pane's
    /// triggers (hook events, HEAD changes, activation).
    private var diffStatsByWorktree: [String: DiffStats] = [:]
    private let headWatcher = HeadWatcher()
    // Keeps each worktree's terminal alive across sidebar switches; the handle is
    // a SplitSurface (single-pane in PR A; splits added in PR B).
    private let surfaces = SurfaceRegistry<SplitSurface>()
    // Toolbar centre-notch: time-of-day glyph + time only (worktree name/badge live in the identity bar).
    private let notchLabel = NSTextField(labelWithString: "No worktree")
    private let notchIcon = NSImageView()
    private let notchBadge = NSView()   // layer-drawn agent-state dot
    private var notchTimer: Timer?
    private var stateTimer: Timer?
    private var agentStates: [String: AgentState] = [:]
    private var hookServer: AgentHookSocketServer?
    // surfaceKeys with a live Claude run (SessionStart..SessionEnd) — these own their agent
    // state via hook events; the heuristic poll skips them so it never fights an event.
    private var claudePresent: Set<String> = []
    // Lock-protected snapshot of known surfaceKeys, read by AgentHookSocketServer's
    // `isKnownSurface` closure from a BACKGROUND thread — never read `surfaces` (main-thread
    // owned) from there directly, that would be a data race.
    private let surfaceAllowlistLock = NSLock()
    private var surfaceAllowlistSnapshot: Set<String> = []
    private var prefsStore: PreferencesStore!
    private var preferences = Preferences()
    private var themeStore: ThemeStore!
    private var activeTheme: TerminalTheme!
    private let defaultThemeName = "Dracula"
    private var kbStore: KeybindingsStore!
    private var keybindings = Keybindings()
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var hoverMonitor: Any?
    private var settingsWC: NSWindowController?
    // Open-in toolbar item ref, so its icon/tooltip/menu track the chosen default editor.
    private weak var openInItem: NSMenuToolbarItem?
    // Toggle-diff toolbar item ref, so its appearance tracks the diff pane's open/closed
    // state on every toggle path (toolbar click, View menu, ⌃⌘D) — mirrors the openInItem
    // pattern above (store the ref, mutate its appearance from the single state-changing spot).
    private weak var toggleDiffToolbarItem: NSToolbarItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyDockIcon()
        let home = FileManager.default.homeDirectoryForCurrentUser
        // One-time settings migration from the app's former name (~/.conductor → ~/.coda).
        DataDirMigration.migrateSettings(from: home.appendingPathComponent(".conductor"),
                                         to: home.appendingPathComponent(".coda"))
        store = makeStore()
        prefsStore = PreferencesStore(url: home.appendingPathComponent(".coda/preferences.json"))
        preferences = prefsStore.load()
        themeStore = ThemeStore(directory: home.appendingPathComponent(".coda/themes"))
        try? themeStore.seedIfEmpty(from: bundledThemeURLs())
        activeTheme = loadActiveTheme()
        kbStore = KeybindingsStore(url: home.appendingPathComponent(".coda/keybindings.json"))
        keybindings = kbStore.load()
        buildMenu()
        buildWindow()
        wireSidebar()
        seedBranchesAndWatchers()
        startHookServer()
        promptForHookInstallIfNeeded()
        // UNUserNotificationCenter requires a real app bundle (CFBundleIdentifier); under
        // `swift run`/`swift test` there is none, and just touching `.current()` throws
        // NSInternalInconsistencyException, crashing the dev workflow. Badges still work
        // without this — only banner notifications are unavailable when unbundled.
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
            AgentNotifier.requestAuthorization()
        }
        refreshSidebar(select: allDisplayWorktrees().first?.id)
        applyChromeTheme()
        applyUIMetrics()
        startDiffStatsSweep()
        // Keep the notch clock current.
        notchTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.updateNotch()
        }
        // Fallback sweep for surfaces that never emitted a hook event (plain shells, or a
        // Claude run started before the hook was installed): event-owned surfaces
        // (`claudePresent`) are skipped here, so this is just a safety net. 2s keeps the
        // non-event path reasonably snappy without the old 1.2s per-tick full-grid scan cost.
        stateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollAgentStates()
        }
        // iTerm-style ⌘+click to open a path:line in the editor, routed to the focused
        // surface. We swallow BOTH the down and up: SwiftTerm activates its own link
        // handler on mouseUp (default NSWorkspace.open → a -50 dialog for non-URL
        // tokens), so consuming the up keeps our editor open as the only handler.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self, event.modifierFlags.contains(.command), event.window === self.window,
                  let split = self.currentSurface, let pane = split.paneContaining(event) else { return event }
            if event.type == .leftMouseDown { pane.handleCommandClick(event) }
            return nil
        }
        // ⌘/⇧/⌥+Enter → soft newline (LF), Claude Code's chat:newline. SwiftTerm seals
        // keyDown (public, not open), so we can't override it on the terminal view; an
        // app-level keyDown monitor (like the ⌘+click monitor above) reliably catches these
        // combos and routes LF to the focused terminal. Plain Enter passes through (submit).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let mods = event.modifierFlags
            guard terminalKeyAction(charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                                    command: mods.contains(.command), shift: mods.contains(.shift),
                                    option: mods.contains(.option)) == .insertNewline,
                  let term = self.focusedTerminalView() else { return event }
            term.sendSoftNewline()
            return nil
        }
        // ⌘-hover over a link → pointing-hand cursor, like a browser. Mirrors the ⌘+click
        // monitor. Only meaningful while ⌘ is held — which is also when SwiftTerm turns on its
        // mouse-move tracking area, so these events reliably flow to us.
        hoverMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .flagsChanged]) { [weak self] event in
            self?.updateLinkCursor(for: event)
            return event
        }
    }

    /// Show the pointing-hand cursor while ⌘ is held over a clickable link/file. SwiftTerm
    /// hard-codes an I-beam cursor rect and seals its mouse/cursor methods (`public`, not
    /// `open`), so we can't set the cursor on the terminal view directly. Our monitor runs
    /// *before* the window re-applies that I-beam rect for the same event, so we defer the
    /// hand cursor to the next runloop tick to land after it. When not over a link we do
    /// nothing — SwiftTerm's I-beam rect already reasserts itself for the event.
    private func updateLinkCursor(for event: NSEvent) {
        let overLink: Bool = {
            guard window != nil, window.isKeyWindow, event.window === window,
                  event.modifierFlags.contains(.command),
                  let pane = currentSurface?.paneContaining(event) else { return false }
            return pane.linkExists(at: event)
        }()
        guard overLink else { return }
        DispatchQueue.main.async { NSCursor.pointingHand.set() }
    }

    /// The ClickableTerminalView that currently holds keyboard focus in the main window, or
    /// nil. Walks up from the first responder, since the responder may be the terminal view
    /// itself or a descendant.
    private func focusedTerminalView() -> ClickableTerminalView? {
        var view = window.firstResponder as? NSView
        while let current = view {
            if let terminal = current as? ClickableTerminalView { return terminal }
            view = current.superview
        }
        return nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        headWatcher.unwatchAll()
        hookServer?.stop()
    }

    /// Start the Claude Code hook socket server before any surface exists, so every PTY
    /// spawned afterwards can be handed a live `socketPath` to seed. `isKnownSurface` is
    /// invoked on a background thread (the server's read queue) — it reads the lock-protected
    /// `surfaceAllowlistSnapshot`, never the main-thread-owned `surfaces` registry.
    private func startHookServer() {
        let socketURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Coda/hooks.sock")
        let server = AgentHookSocketServer(
            socketURL: socketURL,
            isKnownSurface: { [weak self] wt, s in self?.isKnownSurface(wt, s) ?? false },
            onEvent: { [weak self] event in self?.handleHookEvent(event) })
        try? server.start()
        hookServer = server
    }

    /// One-time consent prompt (Security §6): only shown when the hook isn't already
    /// installed AND the user hasn't previously declined. States exactly what changes
    /// (a single hook entry added to ~/.claude/settings.json) and how to remove it.
    private func promptForHookInstallIfNeeded() {
        guard !HookInstaller.isInstalled(), !preferences.declinedHookInstall else { return }
        let alert = NSAlert()
        alert.messageText = "Enable live agent status?"
        alert.informativeText = """
        Coda can show accurate 🟡/🔴/🟢 badges and notifications by adding one hook to \
        ~/.claude/settings.json. It only reports to Coda while a terminal is open here, and \
        is ignored by any claude you run elsewhere. You can remove it anytime from the menu.
        """
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Not now")
        if alert.runModal() == .alertFirstButtonReturn {
            try? HookInstaller.install()
        } else {
            preferences.declinedHookInstall = true
            do { try prefsStore.save(preferences) } catch { presentError(error) }
        }
    }

    // MARK: - Thread-safe surface allowlist (read by the hook socket server's background queue)

    private func allowlistAdd(_ key: String) {
        surfaceAllowlistLock.lock(); surfaceAllowlistSnapshot.insert(key); surfaceAllowlistLock.unlock()
    }

    private func allowlistRemove(_ key: String) {
        surfaceAllowlistLock.lock(); surfaceAllowlistSnapshot.remove(key); surfaceAllowlistLock.unlock()
    }

    /// Called from AgentHookSocketServer's background read queue — must not touch anything
    /// main-thread-owned. Reads only the lock-protected snapshot.
    private func isKnownSurface(_ worktreeID: String, _ surfaceID: String) -> Bool {
        let key = surfaceKey(worktreeID, surfaceID)
        surfaceAllowlistLock.lock(); defer { surfaceAllowlistLock.unlock() }
        return surfaceAllowlistSnapshot.contains(key)
    }

    /// Drop every trace of a closed/evicted surface: it can no longer receive hook events
    /// (allowlist), isn't mid-Claude-run any more (claudePresent), and its stale badge
    /// shouldn't linger in the map (agentStates). Call on every path that removes a surface.
    private func forgetSurface(worktreeID: String, surfaceID: String) {
        let key = surfaceKey(worktreeID, surfaceID)
        allowlistRemove(key)
        claudePresent.remove(key)
        agentStates[key] = nil
    }

    /// `surfaces.evict(worktreeID:)`, plus allowlist/claudePresent/agentStates cleanup for
    /// every surface that worktree had. Use this instead of calling `surfaces.evict` directly.
    @discardableResult
    private func evictSurfaces(worktreeID: String) -> [SplitSurface] {
        let ids = surfaces.existingSurfaces(for: worktreeID)?.entries.map { $0.surface.id } ?? []
        let handles = surfaces.evict(worktreeID: worktreeID)
        ids.forEach { forgetSurface(worktreeID: worktreeID, surfaceID: $0) }
        return handles
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Set the Dock/app-switcher icon at runtime. We run as a bare `swift run`
    /// executable with no `.app` bundle (so no `CFBundleIconFile`), so the icon must
    /// be applied programmatically from the bundled multi-resolution `Coda.icns`.
    private func applyDockIcon() {
        if let url = Bundle.codaAssets.url(forResource: "Coda", withExtension: "icns", subdirectory: "Resources"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }

    /// The bundled starter `.itermcolors` shipped as app resources.
    private func bundledThemeURLs() -> [URL] {
        Bundle.codaAssets.urls(forResourcesWithExtension: "itermcolors", subdirectory: "Themes") ?? []
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
        let configURL = home.appendingPathComponent(".coda/local.json")
        let worktreeRoot = home.appendingPathComponent(".coda/worktrees").path
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
        diffPane = DiffPaneViewController()
        diffPane.onRefresh = { [weak self] in self?.refreshDiffPane() }
        let diffItem = NSSplitViewItem(sidebarWithViewController: diffPane)
        diffItem.canCollapse = true
        diffItem.isCollapsed = true                       // default closed (Q8)
        diffItem.minimumThickness = 280
        diffPaneItem = diffItem
        splitVC = NSSplitViewController()
        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(detailItem)
        splitVC.addSplitViewItem(diffItem)
        // Persist the user's dragged sidebar width across launches; a first-launch
        // default is applied below once the split view is laid out.
        splitVC.splitView.autosaveName = "MainSidebarSplit"

        window = NSWindow(contentViewController: splitVC)
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.title = "Coda"
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
        sidebar.onRemoveRepo = { [weak self] repoID in self?.removeRepo(repoID) }
    }

    /// Override a worktree's identity color and repaint its bar + sidebar row.
    private func setWorktreeColor(_ worktreeID: String, _ hex: String?) {
        do {
            _ = try store.setWorktreeColor(id: worktreeID, color: hex)
            refreshSidebar(select: selectedWorktree?.id)
            if worktreeID == selectedWorktree?.id {
                selectedWorktree = store.state.worktrees.first { $0.id == worktreeID }
                refreshChromeForActiveSurface()
                // Keep the focused-pane border tint in sync with the new color.
                currentSurface?.identityColor = (store.state.worktrees.first { $0.id == worktreeID }?.color).flatMap { NSColor(hex: $0) }
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

    /// Sidebar sections WITH each repo's synthesized main-checkout row prepended.
    private func displaySections() -> [RepositorySection] {
        sectionsWithMainCheckouts(repositories: store.state.repositories,
                                  worktrees: store.state.worktrees,
                                  branchForRepo: currentBranches)
    }

    /// Every worktree the sidebar shows — synthesized main checkouts + real worktrees.
    private func allDisplayWorktrees() -> [Worktree] {
        displaySections().flatMap { $0.worktrees }
    }

    /// Look up a display worktree (incl. a synthesized main checkout) by id.
    private func displayWorktree(id: String?) -> Worktree? {
        guard let id else { return nil }
        return allDisplayWorktrees().first { $0.id == id }
    }

    private func refreshSidebar(select id: String?) {
        sidebar.reload(sections: displaySections(), selectedWorktreeID: id)
    }

    /// Read each repo's current branch and start a HEAD watcher for it (call once at launch).
    private func seedBranchesAndWatchers() {
        headWatcher.onChange = { [weak self] repoID in
            guard let self else { return }
            self.currentBranches[repoID] = try? self.store.currentBranch(repoID: repoID)
            self.refreshSidebar(select: self.shownWorktreeID)
            if self.selectedWorktree?.repoID == repoID { self.scheduleDiffRefresh() }
        }
        for repo in store.state.repositories {
            currentBranches[repo.id] = try? store.currentBranch(repoID: repo.id)
            headWatcher.watch(repoID: repo.id, repoPath: repo.path)
        }
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
                onChangeFont: { [weak self] pref in self?.setTerminalFont(pref) },
                uiScale: preferences.uiScale,
                onChangeUIScale: { [weak self] scale in self?.setUIScale(scale) },
                notifyOnNeedsYou: preferences.notifyOnNeedsYou,
                onChangeNotifyOnNeedsYou: { [weak self] on in self?.setNotifyOnNeedsYou(on) },
                notifyOnDone: preferences.notifyOnDone,
                onChangeNotifyOnDone: { [weak self] on in self?.setNotifyOnDone(on) },
                shell: preferences.shell,
                onChangeShell: { [weak self] choice in self?.setShell(choice) })
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
            let repo = try store.addRepository(path: url.path)
            currentBranches[repo.id] = try? store.currentBranch(repoID: repo.id)
            headWatcher.watch(repoID: repo.id, repoPath: repo.path)
            let mainID = "\(repo.id)#main"
            refreshSidebar(select: mainID)
            select(displayWorktree(id: mainID))
        }
        catch { presentError(error) }
    }

    /// Forget a repository (no disk changes): confirm, remove from the store, evict every
    /// surface for the repo's worktrees + its main checkout, stop its HEAD watcher.
    private func removeRepo(_ repoID: String) {
        guard let repo = store.state.repositories.first(where: { $0.id == repoID }) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove “\(repo.sidebarDisplayName)”?"
        alert.informativeText = "Coda will forget this repository and its worktrees. "
            + "Your files, branches, and worktree directories are left untouched on disk."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let removed = try store.removeRepository(id: repoID)
            var evictIDs = removed.map { $0.id }
            evictIDs.append("\(repoID)#main")
            for id in evictIDs {
                for split in evictSurfaces(worktreeID: id) { tearDown(split) }
            }
            headWatcher.unwatch(repoID: repoID)
            currentBranches[repoID] = nil
            if let shown = shownWorktreeID, evictIDs.contains(shown) {
                shownWorktreeID = nil
                currentSurface = nil
                selectedWorktree = nil
            }
            refreshSidebar(select: allDisplayWorktrees().first?.id)
            select(allDisplayWorktrees().first)
        } catch { presentError(error) }
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
        guard let (title, base) = promptForNewWorktree(repo: repo) else { return }
        do {
            let s = try store.createWorktree(repoID: repo.id, title: title, base: base)
            pendingSetupWorktreeIDs.insert(s.id)
            refreshSidebar(select: s.id)
            select(s)
        } catch { presentError(error) }
    }

    /// Tear down a surface’s panes + views (kills every PTY). Used by archive and repo removal.
    private func tearDown(_ split: SplitSurface) {
        split.allPanes.forEach { $0.view.removeFromSuperview(); $0.removeFromParent() }
        split.view.removeFromSuperview()
        split.removeFromParent()
    }

    private func archive(_ s: Worktree) {
        // Archiving deletes the branch too and can’t be undone — confirm first.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Archive “\(s.title)”?"
        alert.informativeText = "This removes the worktree and deletes its branch (\(s.branch)). This can’t be undone."
        alert.addButton(withTitle: "Archive")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.archiveWorktree(id: s.id, deleteBranch: true)
            // Tear down all of the archived worktree’s surfaces (kills every PTY, no leak).
            for split in evictSurfaces(worktreeID: s.id) { tearDown(split) }
            if shownWorktreeID == s.id {
                shownWorktreeID = nil
                currentSurface = nil
                selectedWorktree = nil
            }
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
        refreshDiffPane()
        if let s { recomputeDiffStats(for: s) }
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
        // Force an immediate repaint from current agent state so the switched-to worktree's
        // badges (sidebar + notch + tabs) are correct instantly, rather than waiting for the
        // next hook event or the fallback poll. (Superset of refreshChrome+refreshTabBar.)
        recomputeRollupsAndRefreshUI()
    }

    /// Build a fresh SplitSurface (single-pane) for `wt`, register it, install it in the detail
    /// view, make it the active surface, and focus it. `runSetupAndAutoLaunch` is true only for
    /// the worktree's very first surface (mirrors the old first-open behavior: setupScript +
    /// optional auto-launch Claude); additional tabs are always plain shells.
    @discardableResult
    private func createSurface(in wt: Worktree, runSetupAndAutoLaunch: Bool) -> SplitSurface {
        shownWorktreeID = wt.id
        surfaces.setActive(wt.id)
        let repo = store.state.repositories.first { $0.id == wt.repoID }
        let isNewlyCreated = runSetupAndAutoLaunch && pendingSetupWorktreeIDs.contains(wt.id)
        let setup = isNewlyCreated ? (repo?.setupScript ?? "") : ""
        pendingSetupWorktreeIDs.remove(wt.id)
        let command = (isNewlyCreated && repo?.autoLaunchClaude == true) ? launchCommand(for: repo!) : ""

        // The surface id is minted up front (not after) so every pane in this split — the
        // first one and any split later adds — can be tagged with the SAME hookSurfaceID;
        // all panes of one tab correlate hook events under one surface key.
        surfaceSeq += 1
        let id = "surface-\(surfaceSeq)"

        // The first pane carries setup/command; split panes are plain shells (makePane).
        let firstPane = makePane(in: wt, command: command, setup: setup, surfaceID: id)
        let split = SplitSurface(
            firstPane: firstPane, firstID: nextPaneID(),
            makePane: { [weak self, wt, id] in
                let pane = self?.makePane(in: wt, command: "", setup: "", surfaceID: id)
                    ?? TerminalSurface(workingDirectory: wt.worktreePath, command: "", setupScript: "")
                return (self?.nextPaneID() ?? UUID().uuidString, pane)
            })
        split.onFocusChange = { [weak self] in self?.refreshTabBar(); self?.refreshChromeForActiveSurface() }

        let list = surfaces.surfaces(for: wt.id)
        list.activeHandle?.view.isHidden = true
        list.add(split, surface: Surface(id: id))
        allowlistAdd(surfaceKey(wt.id, id))

        detail.addChild(split)
        split.view.translatesAutoresizingMaskIntoConstraints = false
        detail.view.addSubview(split.view)
        NSLayoutConstraint.activate([
            split.view.topAnchor.constraint(equalTo: surfaceTabBar.bottomAnchor, constant: 6),
            split.view.bottomAnchor.constraint(equalTo: detail.view.bottomAnchor),
            split.view.leadingAnchor.constraint(equalTo: detail.view.leadingAnchor, constant: 8),
            split.view.trailingAnchor.constraint(equalTo: detail.view.trailingAnchor, constant: -8),
        ])
        currentSurface = split
        split.identityColor = (selectedWorktree?.color).flatMap { NSColor(hex: $0) }
        view(focus: split)
        refreshChromeForActiveSurface()
        refreshTabBar()
        return split
    }

    /// Build a fully-configured terminal pane for a worktree (cwd, theme, font, callbacks).
    /// `surfaceID` is the owning `Surface.id` (shared by every pane in a split), used both to
    /// tag the PTY's hook-correlation env vars and to key `agentStates`/the allowlist.
    private func makePane(in wt: Worktree, command: String, setup: String, surfaceID: String) -> TerminalSurface {
        let pane = TerminalSurface(workingDirectory: wt.worktreePath, command: command, setupScript: setup,
                                   hookWorktreeID: wt.id, hookSurfaceID: surfaceID,
                                   hookSocketPath: hookServer?.socketPath ?? "",
                                   shell: resolvedShell())
        pane.onOpenFile = { [weak self] path, line in self?.openInDefaultEditor(path: path, line: line) }
        pane.onTitleChange = { [weak self] _ in self?.refreshTabBar() }
        pane.applyTheme(activeTheme)
        pane.applyFont(resolvedTerminalFont())
        return pane
    }

    private var paneSeq = 0
    private func nextPaneID() -> String { paneSeq += 1; return "pane-\(paneSeq)" }

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

    private func view(focus surface: SplitSurface) {
        window.makeFirstResponder(surface.focusedPane.view)
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
        let repoName = store.state.worktrees.first { $0.id == wtID }
            .flatMap { wt in store.state.repositories.first { $0.id == wt.repoID } }?.name
        let items: [SurfaceTabItem] = list.entries.enumerated().map { idx, entry in
            let effective = entry.surface.effectiveColor(worktreeColor: worktreeColor)
            return SurfaceTabItem(
                id: entry.surface.id,
                label: surfaceLabel(nameOverride: entry.surface.nameOverride,
                                    repoName: repoName, index: idx),
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
    /// (non-idle agent state). Closing the last surface spawns a fresh shell — a selected
    /// worktree always has at least one surface (never an empty pane).
    private func closeSurface(_ id: String? = nil) {
        // ⌘W (no explicit surface id): close the focused PANE first; only close the tab
        // when the surface is down to its last pane.
        if id == nil, let split = currentSurface, split.allPanes.count > 1 {
            _ = split.closeFocused()
            refreshChromeForActiveSurface()
            refreshTabBar()
            return
        }
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
            forgetSurface(worktreeID: wtID, surfaceID: targetID)
            removed.allPanes.forEach { $0.view.removeFromSuperview(); $0.removeFromParent() }
            removed.view.removeFromSuperview()
            removed.removeFromParent()
        }
        if let newActive = list.activeHandle {
            newActive.view.isHidden = false
            currentSurface = newActive
            view(focus: newActive)
        } else if let wt = selectedWorktree {
            // Never leave a worktree empty: closing the last tab spawns a fresh shell.
            // createSurface re-establishes shownWorktreeID + active and refreshes chrome/tab bar.
            currentSurface = nil
            createSurface(in: wt, runSetupAndAutoLaunch: false)
            return
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
    private func activateSurfaceAfterListMove(_ id: String, in list: WorktreeSurfaces<SplitSurface>) {
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
                           agentState: agentStates[wt.id] ?? .idle,
                           diffStats: diffStatsByWorktree[wt.id])
        sidebar.setIdentityOverride(effective?.nsColor, forWorktree: wt.id)
        currentSurface?.identityColor = effective?.nsColor
    }

    /// Right-click on a surface tab: rename, color, or close it.
    private func showSurfaceContextMenu(_ surfaceID: String, anchor: NSView) {
        let menu = NSMenu()
        let rename = NSMenuItem(title: "Rename…", action: #selector(renameSurfaceAction(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = surfaceID
        menu.addItem(rename)
        menu.addItem(ColorMenu.makeSetColorItem(
            targetID: surfaceID, target: self,
            setColor: #selector(setSurfaceColorAction(_:)),
            removeColor: #selector(removeSurfaceColorAction(_:))))
        menu.addItem(.separator())
        let close = NSMenuItem(title: "Close Tab", action: #selector(closeSurfaceMenuAction(_:)), keyEquivalent: "")
        close.target = self
        close.representedObject = surfaceID
        menu.addItem(close)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height), in: anchor)
    }

    @objc private func renameSurfaceAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let wtID = shownWorktreeID,
              let list = surfaces.existingSurfaces(for: wtID) else { return }
        let current = list.entry(for: id)?.surface.nameOverride ?? ""
        guard let input = promptForText(prompt: "Tab name:", defaultValue: current) else { return }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        list.rename(id: id, to: trimmed.isEmpty ? nil : trimmed)   // blank clears → auto-label
        refreshTabBar()
    }

    @objc private func setSurfaceColorAction(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let id = info["id"], let hex = info["hex"], let rgb = RGB(hex: hex),
              let wtID = shownWorktreeID, let list = surfaces.existingSurfaces(for: wtID) else { return }
        list.setColor(id: id, to: rgb)
        refreshTabBar()
        refreshChromeForActiveSurface()
        refreshSidebar(select: selectedWorktree?.id)
    }

    @objc private func removeSurfaceColorAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let wtID = shownWorktreeID,
              let list = surfaces.existingSurfaces(for: wtID) else { return }
        list.setColor(id: id, to: nil)
        refreshTabBar()
        refreshChromeForActiveSurface()
        refreshSidebar(select: selectedWorktree?.id)
    }

    @objc private func closeSurfaceMenuAction(_ sender: NSMenuItem) {
        (sender.representedObject as? String).map { closeSurface($0) }
    }

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
            surfaces.existingSurfaces(for: wtID)?.handles.forEach { split in
                split.allPanes.forEach { $0.applyTheme(activeTheme) }
            }
        }
        applyChromeTheme()
    }

    /// The bundled "Symbols Nerd Font Mono", registered for this process for use as a glyph
    /// fallback; resolves to its PostScript name once (nil if the resource is missing).
    private static let nerdFallbackFontName: String? = {
        guard let url = Bundle.codaAssets.url(forResource: "SymbolsNerdFontMono-Regular",
                                          withExtension: "ttf", subdirectory: "Resources") else { return nil }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descs.first,
              let name = CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String else { return nil }
        return name
    }()

    /// The configured terminal font (or the default monospaced font), augmented with the
    /// bundled Nerd Font as a *cascade fallback* so powerline / icon glyphs render even when
    /// the chosen font lacks them. The base font's own text characters are untouched.
    ///
    /// Some coding fonts (e.g. Dank Mono) ship a handful of powerline/icon glyphs in the
    /// Private Use Area that are taller than the font's ascent. SwiftTerm sizes its cells from
    /// the ascent, so those glyph tops get clipped (the branch/separator icons in a powerline
    /// prompt look sliced). To avoid it, we drop from the base font's *declared coverage* any
    /// PUA codepoint that the bundled Nerd Font also provides, so those icons render from the
    /// Nerd Font (whose glyphs are sized to fit a terminal cell) instead of the base font. The
    /// base font's non-PUA glyphs — all normal text — are unaffected.
    private func resolvedTerminalFont() -> NSFont {
        let base: NSFont = {
            if let pref = preferences.terminalFont, let font = NSFont(name: pref.name, size: CGFloat(pref.size)) {
                return font
            }
            return .monospacedSystemFont(ofSize: 13, weight: .regular)
        }()
        guard let nerdName = Self.nerdFallbackFontName else { return base }
        let nerdDescriptor = NSFontDescriptor(fontAttributes: [.name: nerdName])

        var baseDescriptor = base.fontDescriptor
        if let nerdFont = NSFont(descriptor: nerdDescriptor, size: base.pointSize) {
            let baseSet = CTFontCopyCharacterSet(base as CTFont) as CharacterSet
            let nerdSet = CTFontCopyCharacterSet(nerdFont as CTFont) as CharacterSet
            // PUA icon codepoints the Nerd Font covers → let it own them (avoids oversized base glyphs).
            var pua = CharacterSet()
            pua.insert(charactersIn: UnicodeScalar(0xE000)!...UnicodeScalar(0xF8FF)!)
            pua.insert(charactersIn: UnicodeScalar(0xF0000)!...UnicodeScalar(0xFFFFD)!)
            pua.insert(charactersIn: UnicodeScalar(0x100000)!...UnicodeScalar(0x10FFFD)!)
            let restricted = baseSet.subtracting(nerdSet.intersection(pua))
            baseDescriptor = baseDescriptor.addingAttributes([.characterSet: restricted as NSCharacterSet])
        }
        let descriptor = baseDescriptor.addingAttributes([.cascadeList: [nerdDescriptor]])
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }

    /// The shell to spawn in new terminals, per the user's preference. `.automatic` uses the
    /// login shell from `$SHELL`, falling back to the password DB, then to /bin/zsh.
    private func resolvedShell() -> ResolvedShell {
        let login = ProcessInfo.processInfo.environment["SHELL"] ?? loginShellFromPasswordDB()
        return resolveShell(choice: preferences.shell, loginShell: login)
    }

    /// The current user's login shell from the password database (getpwuid), or nil.
    /// Fallback for the rare case `$SHELL` is absent (e.g. an unusual launch context).
    private func loginShellFromPasswordDB() -> String? {
        guard let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell else { return nil }
        let path = String(cString: shell)
        return path.isEmpty ? nil : path
    }

    /// Current chrome metrics from the saved interface-size preference.
    private var uiMetrics: UIMetrics { UIMetrics(scale: preferences.uiScale) }

    /// Push the current metrics to every chrome view and relayout live.
    private func applyUIMetrics() {
        let m = uiMetrics
        sidebar.apply(metrics: m)
        worktreeBar.apply(metrics: m)
        surfaceTabBar.apply(metrics: m)
        refreshTabBar()   // rebuild tab views at the new metrics
    }

    /// Persist a new interface scale and re-apply it live (no relaunch).
    private func setUIScale(_ scale: UIScale) {
        preferences.uiScale = scale
        do { try prefsStore.save(preferences) } catch { presentError(error) }
        applyUIMetrics()
    }

    /// Persist the shell preference. Applies to new terminals only; running shells keep
    /// their process.
    private func setShell(_ shell: ShellChoice) {
        preferences.shell = shell
        do { try prefsStore.save(preferences) } catch { presentError(error) }
        // Applies to new terminals only; running shells keep their process.
    }

    /// Persist the "notify when an agent needs you" toggle.
    private func setNotifyOnNeedsYou(_ on: Bool) {
        preferences.notifyOnNeedsYou = on
        do { try prefsStore.save(preferences) } catch { presentError(error) }
    }

    /// Persist the "notify when an agent finishes" toggle.
    private func setNotifyOnDone(_ on: Bool) {
        preferences.notifyOnDone = on
        do { try prefsStore.save(preferences) } catch { presentError(error) }
    }

    /// Persist a new terminal font and re-apply it to every live surface.
    private func setTerminalFont(_ pref: TerminalFontPref) {
        preferences.terminalFont = pref
        do { try prefsStore.save(preferences) } catch { presentError(error) }
        let font = resolvedTerminalFont()
        for wtID in surfaces.worktreeIDs {
            surfaces.existingSurfaces(for: wtID)?.handles.forEach { split in
                split.allPanes.forEach { $0.applyFont(font) }
            }
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
        appMenu.addItem(withTitle: "About Coda",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = addItem(to: appMenu, "Settings…", #selector(openSettingsAction),
                                   command: .openSettings)
        _ = settingsItem
        appMenu.addItem(.separator())
        let enableHookItem = NSMenuItem(title: "Enable Agent Status Hook",
                                        action: #selector(enableAgentStatusHookAction), keyEquivalent: "")
        enableHookItem.target = self
        appMenu.addItem(enableHookItem)
        let removeHookItem = NSMenuItem(title: "Remove Agent Status Hook",
                                        action: #selector(removeAgentStatusHookAction), keyEquivalent: "")
        removeHookItem.target = self
        appMenu.addItem(removeHookItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Coda",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Coda",
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
        addItem(to: viewMenu, "Toggle Diff", #selector(toggleDiffAction), command: .toggleDiff)
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
        addItem(to: surfaceMenu, "Split Right", #selector(splitSurfaceAction), command: .splitSurface)
        addItem(to: surfaceMenu, "Split Down", #selector(splitDownAction), command: .splitDown)
        surfaceMenu.addItem(.separator())
        addItem(to: surfaceMenu, "Focus Pane Left",  #selector(focusPaneLeftAction),  command: .focusPaneLeft)
        addItem(to: surfaceMenu, "Focus Pane Right", #selector(focusPaneRightAction), command: .focusPaneRight)
        addItem(to: surfaceMenu, "Focus Pane Up",    #selector(focusPaneUpAction),    command: .focusPaneUp)
        addItem(to: surfaceMenu, "Focus Pane Down",  #selector(focusPaneDownAction),  command: .focusPaneDown)
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

    @objc private func toggleDiffAction() {
        diffPaneItem.animator().isCollapsed.toggle()
        updateToggleDiffAppearance()
        if !diffPaneItem.isCollapsed { refreshDiffPane() }   // populate on open
    }

    /// Reflect the diff pane's open/closed state on the toolbar button (spec: "Shows a
    /// selected state when open"). A plain NSToolbarItem has no built-in selected look, so we
    /// tint the glyph with the accent color while open and revert to the plain template glyph
    /// while closed. No-op if the toolbar hasn't been built yet (`toggleDiffToolbarItem` nil).
    private func updateToggleDiffAppearance() {
        toggleDiffToolbarItem?.image = toggleDiffImage(active: !diffPaneItem.isCollapsed)
    }

    /// The Toggle Diff glyph: the plain template symbol when closed, or the same symbol
    /// tinted with the accent color when open. `isTemplate = false` is required on the tinted
    /// variant — template images are recolored by the system for their control state, which
    /// would otherwise erase the accent tint we just applied.
    private func toggleDiffImage(active: Bool) -> NSImage? {
        guard let base = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Toggle Diff")
        else { return nil }
        guard active else { return base }
        let tinted = base.withSymbolConfiguration(.init(paletteColors: [.controlAccentColor])) ?? base
        tinted.isTemplate = false
        return tinted
    }

    /// Recompute the diff pane's contents from `DiffService` and repaint it — but only while
    /// the pane is open (collapsed = nothing to show, so skip the git work entirely). Runs the
    /// actual `git diff` off the main thread; the result is applied back on main, re-guarded
    /// against the selection/visibility having changed while the background work was in flight
    /// (e.g. the user switched worktrees or closed the pane mid-compute).
    private func refreshDiffPane() {
        guard !diffPaneItem.isCollapsed else { return }          // closed → compute nothing
        guard let wt = selectedWorktree else { diffPane.showEmpty(message: "No worktree selected"); return }
        let git = GitWorktree(gitPath: "/usr/bin/git")
        let mainBranch = wt.isMain ? nil : mainCheckoutBranch(forRepo: wt.repoID)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = DiffService.compute(worktree: wt, mainBranch: mainBranch, git: git)
            DispatchQueue.main.async {
                guard let self, self.selectedWorktree?.id == wt.id, !self.diffPaneItem.isCollapsed else { return }
                self.diffPane.show(files: result.files)
            }
        }
    }

    /// The branch checked out in the repo's main working directory (the fork-base fallback).
    /// Reads the `currentBranches` cache (kept fresh by `headWatcher`) rather than shelling out
    /// to git — this runs on the main thread on every worktree activation and debounced refresh,
    /// so a synchronous `Process` here would defeat the point of backgrounding the diff compute.
    /// A cache miss (repo not yet seeded) returns nil, which degrades to working-tree-only via
    /// `resolveDiffBase`'s fallback and self-corrects on the next HEAD event/activation.
    private func mainCheckoutBranch(forRepo repoID: String) -> String? {
        currentBranches[repoID]
    }

    /// Debounced trigger for `refreshDiffPane()` — Claude fires `PostToolUse` in bursts and
    /// `HeadWatcher` can fire on rapid successive commits, so coalesce to one recompute.
    /// Also recomputes the active worktree's cheap +/- figure on the same cadence, so the
    /// sidebar/bar and the pane never drift apart.
    private func scheduleDiffRefresh() {
        diffRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refreshDiffPane()
            if let wt = self.selectedWorktree { self.recomputeDiffStats(for: wt) }
        }
        diffRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Populate `diffStatsByWorktree` for every worktree on launch, so cold-started worktrees
    /// that never see a hook event or HEAD change still get an initial figure. Runs on a single
    /// serial `.utility` queue and computes worktrees ONE AT A TIME (not fanned out) so a repo
    /// with many worktrees doesn't thrash git subprocesses or starve the interactive queues;
    /// each result is posted back to the sidebar as it lands rather than waiting for the sweep
    /// to finish, so figures appear incrementally.
    private func startDiffStatsSweep() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let worktrees = DispatchQueue.main.sync { self.store.state.worktrees }
            let git = GitWorktree(gitPath: "/usr/bin/git")
            for wt in worktrees {
                let mainBranch = wt.isMain ? nil : DispatchQueue.main.sync { self.mainCheckoutBranch(forRepo: wt.repoID) }
                let stats = DiffService.stats(worktree: wt, mainBranch: mainBranch, git: git)
                DispatchQueue.main.async {
                    self.diffStatsByWorktree[wt.id] = stats
                    self.sidebar.updateDiffStats(self.diffStatsByWorktree)
                    if self.selectedWorktree?.id == wt.id { self.refreshChromeForActiveSurface() }
                }
            }
        }
    }

    /// Recompute one worktree's cheap +/- figure off the main thread, then write it into
    /// `diffStatsByWorktree` and repaint the sidebar (always) and the WorktreeBar (only when
    /// `wt` is the active worktree). `mainCheckoutBranch` is an O(1) cache read, so it's safe
    /// to call before hopping to the background queue.
    private func recomputeDiffStats(for wt: Worktree) {
        let git = GitWorktree(gitPath: "/usr/bin/git")
        let mainBranch = wt.isMain ? nil : mainCheckoutBranch(forRepo: wt.repoID)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let stats = DiffService.stats(worktree: wt, mainBranch: mainBranch, git: git)
            DispatchQueue.main.async {
                guard let self else { return }
                self.diffStatsByWorktree[wt.id] = stats
                self.sidebar.updateDiffStats(self.diffStatsByWorktree)
                if self.selectedWorktree?.id == wt.id { self.refreshChromeForActiveSurface() }
            }
        }
    }

    /// Debounced wrapper around `recomputeDiffStats(for:)` for the hook-event path — coalesces
    /// a `PostToolUse` burst for one worktree into a single recompute, and guarantees the
    /// last-scheduled request wins (an earlier in-flight schedule is cancelled before it can
    /// dispatch, so a stale result can never land after a fresher one). Must only be called
    /// from the main thread, since `statsRecomputeWork` is main-thread-only state.
    private func scheduleStatsRecompute(for wt: Worktree) {
        statsRecomputeWork[wt.id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.statsRecomputeWork[wt.id] = nil
            self?.recomputeDiffStats(for: wt)
        }
        statsRecomputeWork[wt.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    @objc private func enableAgentStatusHookAction() {
        do {
            try HookInstaller.install()
            presentMessage("The agent-status hook is now enabled in ~/.claude/settings.json.")
        } catch {
            presentError(error)
        }
    }

    @objc private func removeAgentStatusHookAction() {
        do {
            try HookInstaller.uninstall()
            presentMessage("The agent-status hook has been removed from ~/.claude/settings.json.")
        } catch {
            presentError(error)
        }
    }

    @objc private func archiveSelectedAction() {
        guard let wt = selectedWorktree else { presentMessage("Select a worktree first."); return }
        if wt.isMain {
            presentMessage("The main checkout can't be archived. Use Remove Repository to forget the repo.")
            return
        }
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
    @objc private func splitSurfaceAction() { currentSurface?.splitFocused(axis: .horizontal) }
    @objc private func splitDownAction() { currentSurface?.splitFocused(axis: .vertical) }
    @objc private func focusPaneLeftAction()  { currentSurface?.moveFocus(.left) }
    @objc private func focusPaneRightAction() { currentSurface?.moveFocus(.right) }
    @objc private func focusPaneUpAction()    { currentSurface?.moveFocus(.up) }
    @objc private func focusPaneDownAction()  { currentSurface?.moveFocus(.down) }

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
              let split = currentSurface else {
            presentMessage("Select a worktree first.")
            return
        }
        split.focusedPane.sendCommand(launchCommand(for: repo))
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

    /// Fallback heuristic sweep. Surfaces with a live hook-reported Claude run
    /// (`claudePresent`) are event-owned and are left untouched here — this only classifies
    /// surfaces the event path has never heard from (plain shells, or a Claude run predating
    /// the hook install).
    private func pollAgentStates() {
        var states: [String: AgentState] = [:]
        for wtID in surfaces.worktreeIDs {
            guard let list = surfaces.existingSurfaces(for: wtID) else { continue }
            for entry in list.entries {
                let key = surfaceKey(wtID, entry.surface.id)
                states[key] = claudePresent.contains(key)
                    ? (agentStates[key] ?? .idle)
                    : rollup(entry.handle.allPanes.map { $0.currentAgentState() })
            }
        }
        agentStates = states
        recomputeRollupsAndRefreshUI()
    }

    /// Roll each worktree's per-surface states up to a worktree-level badge and push the
    /// result to every UI surface that shows agent state. Shared tail of `pollAgentStates`
    /// (the heuristic fallback) and `handleHookEvent` (the event-driven path) — DRY.
    private func recomputeRollupsAndRefreshUI() {
        var rollups: [String: AgentState] = [:]
        for wtID in surfaces.worktreeIDs {
            guard let list = surfaces.existingSurfaces(for: wtID) else { continue }
            let perSurface = list.entries.map { agentStates[surfaceKey(wtID, $0.surface.id)] ?? .idle }
            rollups[wtID] = rollup(perSurface)
        }
        for (k, v) in rollups { agentStates[k] = v }
        sidebar.updateAgentStates(rollups)
        updateNotch()
        refreshChromeForActiveSurface()
        refreshTabBar()
    }

    /// Route one decoded Claude Code hook event into the same `agentStates` map the poll
    /// maintains, so the sidebar/notch/tab badges are driven by real lifecycle events instead
    /// of scraped terminal text — no more 1.2s lag or stale-line stickiness.
    private func handleHookEvent(_ event: AgentHookEvent) {
        let key = surfaceKey(event.worktreeID, event.surfaceID)
        switch event.event {
        case .sessionStart: claudePresent.insert(key)
        case .sessionEnd:   claudePresent.remove(key)
        default: break
        }
        guard let newState = agentState(for: event.event) else {
            recomputeRollupsAndRefreshUI(); return    // e.g. SessionStart: presence only
        }
        agentStates[key] = newState
        // needs-you body = the Notification's own message; done body = last assistant text
        // from the transcript (bounded read). No payload carries the assistant message directly.
        let body: String?
        switch newState {
        case .needsYou: body = event.message
        case .done:     body = event.transcriptPath.flatMap(Self.lastAssistantMessage(fromTranscriptAt:))
        default:        body = nil
        }
        maybeNotify(worktreeID: event.worktreeID, state: newState, body: body)
        recomputeRollupsAndRefreshUI()
        if let wt = store.state.worktrees.first(where: { $0.id == event.worktreeID }) {
            scheduleStatsRecompute(for: wt)
        }
        if event.worktreeID == selectedWorktree?.id { scheduleDiffRefresh() }
    }

    /// Bounded read of a transcript JSONL's tail → last assistant text (Security §4). Reads
    /// only the last ~64 KB, drops a partial leading line, and delegates parsing to CodaCore.
    private static func lastAssistantMessage(fromTranscriptAt path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let tailBytes: UInt64 = 64_000
        let start = size > tailBytes ? size - tailBytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let body = start > 0 ? String(text.drop { $0 != "\n" }.dropFirst()) : text
        return lastAssistantText(fromTranscript: body)
    }

    /// Post a macOS notification for a needs-you/done transition, gated by the two independent
    /// Settings toggles. `body` is untrusted (repo/web content the agent read) and is handed to
    /// `AgentNotifier` for delivery as a plain `UNMutableNotificationContent.body` data field
    /// only — never built into a shell/AppleScript string (Security §1).
    private func maybeNotify(worktreeID: String, state: AgentState, body: String?) {
        let allowed = (state == .needsYou && preferences.notifyOnNeedsYou)
                   || (state == .done && preferences.notifyOnDone)
        guard allowed else { return }
        let title = displayWorktree(id: worktreeID)?.title ?? "Coda"
        AgentNotifier.notify(worktreeID: worktreeID, title: title, state: state, body: body)
    }

    /// Bring a worktree to the foreground, reusing the same select+sidebar-highlight path
    /// every other programmatic "jump to worktree" call site uses (e.g. after creating a
    /// worktree or removing one), plus bringing the app/window forward since this is invoked
    /// from a notification click while Coda may not be the active app.
    private func focus(worktreeID: String) {
        guard let wt = displayWorktree(id: worktreeID) else { return }
        refreshSidebar(select: worktreeID)
        select(wt)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 didReceive response: UNNotificationResponse,
                                 withCompletionHandler completionHandler: @escaping () -> Void) {
        if let worktreeID = response.notification.request.content.userInfo["worktreeID"] as? String {
            focus(worktreeID: worktreeID)
        }
        completionHandler()
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

    /// Prompt for a new worktree's title and the local branch it forks from. Returns nil on
    /// Cancel. When branch enumeration yields nothing (e.g. an unborn repo), falls back to the
    /// title-only prompt with the base left at the repo's current HEAD.
    private func promptForNewWorktree(repo: Repository) -> (title: String, base: String)? {
        let branches = (try? store.localBranches(repoID: repo.id)) ?? []
        let currentHead = try? store.currentBranch(repoID: repo.id)

        guard !branches.isEmpty else {
            guard let title = promptForText(prompt: "Worktree title:", defaultValue: "New Worktree") else { return nil }
            return (title, currentHead ?? "HEAD")
        }

        let alert = NSAlert()
        alert.messageText = "New Worktree"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let titleLabel = NSTextField(labelWithString: "Title")
        let titleField = NSTextField(string: "New Worktree")
        let baseLabel = NSTextField(labelWithString: "Base branch")
        let basePopup = NSPopUpButton()
        for b in branches { basePopup.addItem(withTitle: b) }
        if let head = currentHead, let idx = branches.firstIndex(of: head) {
            basePopup.selectItem(at: idx)
        }

        let stack = NSStackView(views: [titleLabel, titleField, baseLabel, basePopup])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 120)
        titleField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        basePopup.widthAnchor.constraint(equalToConstant: 260).isActive = true
        alert.accessoryView = stack

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let title = titleField.stringValue.isEmpty ? "New Worktree" : titleField.stringValue
        let base = basePopup.titleOfSelectedItem ?? currentHead ?? "HEAD"
        return (title, base)
    }

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
    static let toggleDiff = NSToolbarItem.Identifier("toggleDiff")
    static let openIn = NSToolbarItem.Identifier("openIn")
}

extension AppDelegate: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // No sidebar-tracking separator: it pins the notch's flexible space to the content
        // region, so the notch drifts as the sidebar resizes. Centring it between the left
        // (toggle+add) and right (launch+open) groups keeps it put in window coordinates.
        [.toggleSidebar, .addRepository,
         .flexibleSpace, .notch, .flexibleSpace,
         .launchClaude, .toggleDiff, .openIn]
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

        case .toggleDiff:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Diff"
            item.toolTip = "Toggle Diff (⌃⌘D)"
            item.target = self
            item.action = #selector(toggleDiffAction)
            item.isBordered = true
            toggleDiffToolbarItem = item
            updateToggleDiffAppearance()   // initial state: pane starts collapsed → not-selected
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
