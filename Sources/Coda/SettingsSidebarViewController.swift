// Sources/Coda/SettingsSidebarViewController.swift
import AppKit
import CodaCore

/// The Settings source-list sidebar: one row per SettingsCategory (SF Symbol + label).
/// Reports the chosen category via onSelect.
final class SettingsSidebarViewController: NSViewController {
    private let categories = SettingsCategory.allCases
    private let tableView = NSTableView()
    var onSelect: ((SettingsCategory) -> Void)?

    /// Suppresses the selection-changed callback during programmatic selection, so
    /// selectFirst() reports exactly once (selectRowIndexes fires the delegate synchronously).
    private var suppressSelectionCallback = false

    override func loadView() {
        let column = NSTableColumn(identifier: .init("category"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .sourceList
        tableView.backgroundColor = .clear
        tableView.rowHeight = 30
        tableView.rowSizeStyle = .medium

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        view = scroll
    }

    /// Select the first category and notify. Call once after the view loads.
    func selectFirst() {
        suppressSelectionCallback = true
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        suppressSelectionCallback = false
        onSelect?(categories[0])
    }
}

extension SettingsSidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { categories.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let category = categories[row]
        let id = NSUserInterfaceItemIdentifier("categoryCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let c = NSTableCellView()
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(image); c.addSubview(tf)
            c.imageView = image; c.textField = tf
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                image.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 18),
                tf.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            c.identifier = id
            return c
        }()
        cell.imageView?.image = NSImage(systemSymbolName: category.symbolName,
                                        accessibilityDescription: category.title)
        cell.textField?.stringValue = category.title
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback else { return }
        let row = tableView.selectedRow
        guard categories.indices.contains(row) else { return }
        onSelect?(categories[row])
    }
}
