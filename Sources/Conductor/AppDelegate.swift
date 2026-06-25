import AppKit
import ConductorCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var splitVC: NSSplitViewController!
    private let sidebar = SidebarController()
    private let detail = NSViewController()      // holds the terminal surface (Task 7)
    private var store: WorktreeStore!

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = makeStore()
        buildWindow()
        wireSidebar()
        refreshSidebar(select: store.state.worktrees.first?.id)
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
        let detailItem = NSSplitViewItem(viewController: detail)
        splitVC = NSSplitViewController()
        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(detailItem)

        window = NSWindow(contentViewController: splitVC)
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.title = "Conductor"
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func wireSidebar() {
        sidebar.onAddRepo = { [weak self] in self?.addRepo() }
        sidebar.onNew = { [weak self] in self?.newWorktree() }
        sidebar.onArchive = { [weak self] s in self?.archive(s) }
        sidebar.onSelect = { [weak self] s in self?.select(s) }
        sidebar.onRepoSettings = { [weak self] in self?.openRepoSettings() }
    }

    private func refreshSidebar(select id: String?) {
        sidebar.reload(worktrees: store.state.worktrees, selected: id)
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
        guard let repo = store.state.repositories.first else {
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

        // Tear down the current surface (remove its view AND the child VC).
        for child in detail.children {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        guard let s else { return }

        let repo = store.state.repositories.first { $0.id == s.repoID }
        let setup = pendingSetupWorktreeIDs.contains(s.id) ? (repo?.setupScript ?? "") : ""
        pendingSetupWorktreeIDs.remove(s.id)
        let surface = TerminalSurface(workingDirectory: s.worktreePath, command: "claude", setupScript: setup)
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
