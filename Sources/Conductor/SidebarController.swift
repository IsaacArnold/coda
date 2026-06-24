import AppKit
import ConductorCore

/// A simple sidebar: a table of session titles + a toolbar with New / Archive.
final class SidebarController: NSViewController {
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var sessions: [Session] = []

    var onNew: (() -> Void)?
    var onAddRepo: (() -> Void)?
    var onSelect: ((Session?) -> Void)?
    var onArchive: ((Session) -> Void)?

    override func loadView() {
        let container = NSView()

        let addRepo = NSButton(title: "Add Repo…", target: self, action: #selector(addRepoAction))
        let new = NSButton(title: "New Session", target: self, action: #selector(newAction))
        let archive = NSButton(title: "Archive", target: self, action: #selector(archiveAction))
        let bar = NSStackView(views: [addRepo, new, archive])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        bar.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("title"))
        column.title = "Sessions"
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

    func reload(sessions: [Session], selected: String?) {
        self.sessions = sessions
        table.reloadData()
        if let selected, let idx = sessions.firstIndex(where: { $0.id == selected }) {
            table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
    }

    @objc private func addRepoAction() { onAddRepo?() }
    @objc private func newAction() { onNew?() }
    @objc private func archiveAction() {
        let row = table.selectedRow
        guard row >= 0, row < sessions.count else { return }
        onArchive?(sessions[row])
    }
}

extension SidebarController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { sessions.count }

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
        cell.textField?.stringValue = "\(sessions[row].title)  [\(sessions[row].branch)]"
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        onSelect?(row >= 0 && row < sessions.count ? sessions[row] : nil)
    }
}
