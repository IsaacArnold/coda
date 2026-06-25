import AppKit
import ConductorCore

/// Reference-type nodes so the outline view has stable item identity across reloads.
private final class RepoNode: NSObject {
    let repository: Repository
    let children: [WorktreeNode]
    init(repository: Repository, children: [WorktreeNode]) {
        self.repository = repository
        self.children = children
    }
}

private final class WorktreeNode: NSObject {
    let worktree: Worktree
    init(_ worktree: Worktree) { self.worktree = worktree }
}

/// Maps an agent state to its badge tint (nil → no badge). Shared by the sidebar
/// rows and the toolbar notch.
func agentBadgeColor(_ state: AgentState) -> NSColor? {
    switch state {
    case .idle: return nil
    case .working: return .systemYellow
    case .needsYou: return .systemRed
    case .done: return .systemGreen
    }
}

/// A worktree row: branch glyph + title + a trailing agent-state badge dot.
/// The dot is a layer-drawn circle (not an SF symbol) so it always renders.
private final class WorktreeCellView: NSTableCellView {
    let badge = NSView()

    func applyBadge(_ state: AgentState) {
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        if let color = agentBadgeColor(state) {
            badge.layer?.backgroundColor = color.cgColor
            badge.isHidden = false
        } else {
            badge.isHidden = true
        }
    }

    /// Tint the branch glyph with the worktree's identity color (chrome-only signal),
    /// falling back to the chrome glyph tint when the worktree has no color.
    func applyIdentityColor(_ identity: NSColor?, glyphTint: NSColor?) {
        imageView?.contentTintColor = identity ?? glyphTint ?? .secondaryLabelColor
    }
}

/// A source-list sidebar: repositories as header rows with their worktrees nested
/// underneath, plus a toolbar with Add Repo / Settings / New Worktree / Archive.
final class SidebarController: NSViewController {
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private var repoNodes: [RepoNode] = []
    private var agentStates: [String: AgentState] = [:]
    private var chrome: ChromeTheme?

    /// Selection drives the detail surface; the primary actions (add, new, launch,
    /// archive, settings) now live in the native menu bar and toolbar.
    var onSelect: ((Worktree?) -> Void)?

    /// Right-clicking a repo (or one of its worktrees) offers per-repo actions, keyed by
    /// the repo's id: open its settings sheet, or add a worktree to it.
    var onRepoSettings: ((String) -> Void)?
    var onNewWorktree: ((String) -> Void)?

    private let rowMenu = NSMenu()

    override func loadView() {
        let column = NSTableColumn(identifier: .init("title"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 14
        outline.dataSource = self
        outline.delegate = self
        rowMenu.delegate = self
        outline.menu = rowMenu
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        view = scroll
    }

    /// The repo the right-clicked row belongs to (a repo header, or a worktree's parent repo).
    private func clickedRepoID() -> String? {
        let row = outline.clickedRow
        guard row >= 0 else { return nil }
        switch outline.item(atRow: row) {
        case let repo as RepoNode: return repo.repository.id
        case let wt as WorktreeNode: return wt.worktree.repoID
        default: return nil
        }
    }

    @objc private func contextRepoSettings(_ sender: NSMenuItem) {
        (sender.representedObject as? String).map { onRepoSettings?($0) }
    }

    @objc private func contextNewWorktree(_ sender: NSMenuItem) {
        (sender.representedObject as? String).map { onNewWorktree?($0) }
    }

    func reload(sections: [RepositorySection], selectedWorktreeID: String?) {
        repoNodes = sections.map { section in
            RepoNode(repository: section.repository,
                     children: section.worktrees.map(WorktreeNode.init))
        }
        outline.reloadData()
        for node in repoNodes { outline.expandItem(node) }

        if let selectedWorktreeID,
           let node = worktreeNode(id: selectedWorktreeID) {
            let row = outline.row(forItem: node)
            if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        }
    }

    /// Repaint chrome-derived colors (header/glyph tints). Triggers a reload so cells
    /// pick up the new tints. Identity-color swatches come from each worktree's own color.
    func applyChrome(_ chrome: ChromeTheme) {
        self.chrome = chrome
        outline.reloadData()
    }

    /// The repository a new worktree should be added to: the selected worktree's
    /// repo, or a directly selected repo, falling back to the first repository.
    func currentRepoID() -> String? {
        switch outline.item(atRow: outline.selectedRow) {
        case let wt as WorktreeNode: return wt.worktree.repoID
        case let repo as RepoNode: return repo.repository.id
        default: return repoNodes.first?.repository.id
        }
    }

    private func worktreeNode(id: String) -> WorktreeNode? {
        for repo in repoNodes {
            if let match = repo.children.first(where: { $0.worktree.id == id }) { return match }
        }
        return nil
    }

}

extension SidebarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let repoID = clickedRepoID() else { return }
        let settings = NSMenuItem(title: "Repository Settings…",
                                  action: #selector(contextRepoSettings(_:)), keyEquivalent: "")
        settings.target = self
        settings.representedObject = repoID
        menu.addItem(settings)
        let newWorktree = NSMenuItem(title: "New Worktree",
                                     action: #selector(contextNewWorktree(_:)), keyEquivalent: "")
        newWorktree.target = self
        newWorktree.representedObject = repoID
        menu.addItem(newWorktree)
    }
}

extension SidebarController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil: return repoNodes.count
        case let repo as RepoNode: return repo.children.count
        default: return 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let repo = item as? RepoNode { return repo.children[index] }
        return repoNodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? RepoNode).map { !$0.children.isEmpty } ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let repo = item as? RepoNode {
            // Repo rows are plain secondary-gray section headers (no icon), à la Supacode.
            let cell = makeCell(identifier: "repo", symbol: nil)
            cell.textField?.stringValue = repo.repository.name
            cell.textField?.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            cell.textField?.textColor = (chrome?.color(.secondaryText).nsColor) ?? .secondaryLabelColor
            return cell
        }
        if let wt = item as? WorktreeNode {
            let cell = makeWorktreeCell()
            cell.textField?.stringValue = "\(wt.worktree.title)  [\(wt.worktree.branch)]"
            cell.applyBadge(agentStates[wt.worktree.id] ?? .idle)
            cell.applyIdentityColor(wt.worktree.color.flatMap { NSColor(hex: $0) },
                                    glyphTint: chrome?.color(.glyphTint).nsColor)
            return cell
        }
        return nil
    }

    /// Live agent-state badges, keyed by worktree id. Redraws only when changed,
    /// so the 1s poll doesn't churn the outline (or fight selection) every tick.
    func updateAgentStates(_ states: [String: AgentState]) {
        guard states != agentStates else { return }
        agentStates = states
        outline.reloadData()
    }

    /// Supacode's git-branch glyph; falls back to the older symbol on pre-macOS 15.
    private static let branchSymbol = "arrow.trianglehead.branch"

    func outlineViewSelectionDidChange(_ notification: Notification) {
        switch outline.item(atRow: outline.selectedRow) {
        case let wt as WorktreeNode: onSelect?(wt.worktree)
        default: onSelect?(nil)   // a repo row (or nothing) clears the detail surface
        }
    }

    private func makeWorktreeCell() -> WorktreeCellView {
        let id = NSUserInterfaceItemIdentifier("worktree")
        if let reused = outline.makeView(withIdentifier: id, owner: self) as? WorktreeCellView {
            return reused
        }
        let cell = WorktreeCellView()
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: Self.branchSymbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.font = .systemFont(ofSize: NSFont.systemFontSize)
        tf.lineBreakMode = .byTruncatingTail
        let badge = cell.badge
        badge.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon); cell.addSubview(tf); cell.addSubview(badge)
        cell.imageView = icon; cell.textField = tf
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            tf.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            tf.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -6),
            badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 8),
            badge.heightAnchor.constraint(equalToConstant: 8),
        ])
        cell.identifier = id
        return cell
    }

    /// Build (or reuse) a cell. `symbol == nil` yields a text-only row (section
    /// header); otherwise an SF Symbol icon precedes the label.
    private func makeCell(identifier: String, symbol: String?) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier(identifier)
        if let reused = outline.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            return reused
        }
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf

        if let symbol {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
            image.contentTintColor = .secondaryLabelColor
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.identifier = id
        return cell
    }
}
