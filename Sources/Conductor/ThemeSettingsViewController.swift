// Sources/Conductor/ThemeSettingsViewController.swift
import AppKit
import ConductorCore

/// Settings → Themes: a list of installed `.itermcolors`, an Import button, and
/// click-to-apply. Applying repaints terminals + chrome live (handled by AppDelegate).
final class ThemeSettingsViewController: NSViewController {
    private var themeNames: [String]
    private var active: String?
    private let onApply: (String) -> Void
    private let onImport: (URL) -> Void

    private let tableView = NSTableView()
    private let scroll = NSScrollView()

    init(themeNames: [String], active: String?,
         onApply: @escaping (String) -> Void, onImport: @escaping (URL) -> Void) {
        self.themeNames = themeNames
        self.active = active
        self.onApply = onApply
        self.onImport = onImport
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))

        let column = NSTableColumn(identifier: .init("theme"))
        column.title = "Theme"
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(applySelected)
        tableView.target = self
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let applyButton = NSButton(title: "Apply", target: self, action: #selector(applySelected))
        let importButton = NSButton(title: "Import .itermcolors…", target: self, action: #selector(importTheme))
        let buttons = NSStackView(views: [importButton, NSView(), applyButton])
        buttons.orientation = .horizontal
        buttons.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scroll)
        container.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            buttons.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])
        view = container
        selectActiveRow()
    }

    private func selectActiveRow() {
        if let active, let idx = themeNames.firstIndex(of: active) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
    }

    @objc private func applySelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < themeNames.count else { return }
        active = themeNames[row]
        onApply(themeNames[row])
    }

    @objc private func importTheme() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["itermcolors"]
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onImport(url)
        // The store copied it in; refresh the list and select it.
        let name = url.deletingPathExtension().lastPathComponent
        if !themeNames.contains(name) { themeNames.append(name); themeNames.sort() }
        tableView.reloadData()
        if let idx = themeNames.firstIndex(of: name) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
    }
}

extension ThemeSettingsViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { themeNames.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("themeCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let c = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf); c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            c.identifier = id
            return c
        }()
        cell.textField?.stringValue = themeNames[row]
        return cell
    }
}
