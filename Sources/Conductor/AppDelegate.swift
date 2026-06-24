import AppKit
import ConductorCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var splitVC: NSSplitViewController!
    private let sidebar = SidebarController()
    private let detail = NSViewController()      // holds the terminal surface (Task 7)
    private var store: SessionStore!

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = makeStore()
        buildWindow()
        wireSidebar()
        refreshSidebar(select: store.state.sessions.first?.id)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func makeStore() -> SessionStore {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = home.appendingPathComponent(".conductor/local.json")
        let worktreeRoot = home.appendingPathComponent(".conductor/worktrees").path
        return SessionStore(config: Config(url: configURL),
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
        sidebar.onNew = { [weak self] in self?.newSession() }
        sidebar.onArchive = { [weak self] s in self?.archive(s) }
        sidebar.onSelect = { [weak self] s in self?.select(s) }
    }

    private func refreshSidebar(select id: String?) {
        sidebar.reload(sessions: store.state.sessions, selected: id)
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

    private func newSession() {
        guard let repo = store.state.repositories.first else {
            presentMessage("Add a repo first (Add Repo…).")
            return
        }
        let title = promptForText(prompt: "Session title:", defaultValue: "New Session") ?? "New Session"
        do {
            let s = try store.createSession(repoID: repo.id, title: title)
            refreshSidebar(select: s.id)
            select(s)
        } catch { presentError(error) }
    }

    private func archive(_ s: Session) {
        do {
            try store.archiveSession(id: s.id, deleteBranch: true)
            refreshSidebar(select: store.state.sessions.first?.id)
            select(store.state.sessions.first)
        } catch { presentError(error) }
    }

    private var shownSessionID: String?

    private func select(_ s: Session?) {
        guard shownSessionID != s?.id else { return }   // idempotent: ignore redundant reselects
        shownSessionID = s?.id

        detail.children.forEach { $0.removeFromParent() }
        detail.view = NSView()
        guard let s else { return }

        let surface = TerminalSurface(workingDirectory: s.worktreePath, command: "claude")
        detail.addChild(surface)
        surface.view.frame = detail.view.bounds
        surface.view.autoresizingMask = [.width, .height]
        detail.view.addSubview(surface.view)
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
