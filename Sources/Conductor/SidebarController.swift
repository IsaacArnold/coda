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

/// A source-list sidebar: repositories as header rows with their worktrees nested
/// underneath, plus a toolbar with Add Repo / Settings / New Worktree / Archive.
final class SidebarController: NSViewController {
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private var repoNodes: [RepoNode] = []

    var onNew: (() -> Void)?
    var onAddRepo: (() -> Void)?
    var onSelect: ((Worktree?) -> Void)?
    var onArchive: ((Worktree) -> Void)?
    var onRepoSettings: (() -> Void)?

    override func loadView() {
        let container = NSView()

        let addRepo = NSButton(title: "Add Repo…", target: self, action: #selector(addRepoAction))
        let settings = NSButton(title: "Settings…", target: self, action: #selector(settingsAction))
        let new = NSButton(title: "New Worktree", target: self, action: #selector(newAction))
        let archive = NSButton(title: "Archive", target: self, action: #selector(archiveAction))
        let bar = NSStackView(views: [addRepo, settings, new, archive])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        bar.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("title"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 14
        outline.dataSource = self
        outline.delegate = self
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(bar)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
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

    @objc private func addRepoAction() { onAddRepo?() }
    @objc private func settingsAction() { onRepoSettings?() }
    @objc private func newAction() { onNew?() }
    @objc private func archiveAction() {
        if let wt = outline.item(atRow: outline.selectedRow) as? WorktreeNode {
            onArchive?(wt.worktree)
        }
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
            let cell = makeCell(identifier: "repo", symbol: "folder")
            cell.textField?.stringValue = repo.repository.name
            cell.textField?.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            return cell
        }
        if let wt = item as? WorktreeNode {
            let cell = makeCell(identifier: "worktree", symbol: "arrow.triangle.branch")
            cell.textField?.stringValue = "\(wt.worktree.title)  [\(wt.worktree.branch)]"
            cell.textField?.font = .systemFont(ofSize: NSFont.systemFontSize)
            return cell
        }
        return nil
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        switch outline.item(atRow: outline.selectedRow) {
        case let wt as WorktreeNode: onSelect?(wt.worktree)
        default: onSelect?(nil)   // a repo row (or nothing) clears the detail surface
        }
    }

    private func makeCell(identifier: String, symbol: String) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier(identifier)
        if let reused = outline.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            return reused
        }
        let cell = NSTableCellView()
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image.contentTintColor = .secondaryLabelColor
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(tf)
        cell.imageView = image
        cell.textField = tf
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            tf.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.identifier = id
        return cell
    }
}
