import AppKit
import ConductorCore

/// A simple sidebar: a table of worktree titles + a toolbar with New / Archive.
final class SidebarController: NSViewController {
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var worktrees: [Worktree] = []

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
        column.title = "Worktrees"
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
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

    func reload(worktrees: [Worktree], selected: String?) {
        self.worktrees = worktrees
        table.reloadData()
        if let selected, let idx = worktrees.firstIndex(where: { $0.id == selected }) {
            table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
    }

    @objc private func addRepoAction() { onAddRepo?() }
    @objc private func settingsAction() { onRepoSettings?() }
    @objc private func newAction() { onNew?() }
    @objc private func archiveAction() {
        let row = table.selectedRow
        guard row >= 0, row < worktrees.count else { return }
        onArchive?(worktrees[row])
    }
}

extension SidebarController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { worktrees.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 6),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -6),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            c.identifier = id
            return c
        }()
        cell.textField?.stringValue = "\(worktrees[row].title)  [\(worktrees[row].branch)]"
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        onSelect?(row >= 0 && row < worktrees.count ? worktrees[row] : nil)
    }
}
