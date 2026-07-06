import AppKit
import CodaCore

/// One row per changed file, lazily expanding into its diff lines only when the
/// outline actually asks for children (default-collapsed) — this is what keeps
/// `show(files:)` itself O(files) instead of O(total lines), and is what stops a
/// huge file (e.g. package-lock.json) from beach-balling the app: we never build
/// one `NSView` per line up front, only for the ~40 rows currently on screen.
private final class FileItem: NSObject {
    let file: DiffFile
    /// Flips true when the user taps "Show large diff (N lines)"; forces `rows()`
    /// to rebuild past the large-file gate.
    var largeExpanded = false
    private var cachedRows: [RowItem]?

    init(file: DiffFile) { self.file = file }

    /// Lazily-built, cached child rows. Safe to call repeatedly — only rebuilds
    /// after `invalidate()`.
    func rows() -> [RowItem] {
        if let cachedRows { return cachedRows }
        let built = buildRows()
        cachedRows = built
        return built
    }

    func invalidate() { cachedRows = nil }

    private func buildRows() -> [RowItem] {
        if file.isBinary {
            return [RowItem(kind: .binaryNote, fileItem: self)]
        }
        if isLargeDiff(file), !largeExpanded {
            let total = file.hunks.reduce(0) { $0 + $1.lines.count }
            return [RowItem(kind: .showLarge(total), fileItem: self)]
        }
        var rows: [RowItem] = []
        for hunk in file.hunks {
            rows.append(RowItem(kind: .hunkHeader(hunk.header), fileItem: self))
            for line in hunk.lines {
                rows.append(RowItem(kind: .line(line), fileItem: self))
            }
        }
        return rows
    }
}

/// A leaf row under a `FileItem`. Lightweight value-ish object (not a view) —
/// only the rows the outline actually renders get turned into cells.
private final class RowItem: NSObject {
    enum Kind {
        case hunkHeader(String)
        case line(DiffLine)
        case binaryNote
        case showLarge(Int)
    }
    let kind: Kind
    /// Weak on purpose: `FileItem.cachedRows` strongly holds these `RowItem`s, so a
    /// strong back-reference here would be a retain cycle neither side can break.
    weak var fileItem: FileItem?

    init(kind: Kind, fileItem: FileItem) {
        self.kind = kind
        self.fileItem = fileItem
    }
}

/// The "Show large diff (N lines)" button, tagged with the `FileItem` it should
/// expand — lets one reused button send the click back to the right file without
/// a per-row target closure.
private final class ShowLargeButton: NSButton {
    weak var fileItem: FileItem?
}

private final class FileRowCell: NSTableCellView {
    let glyphLabel = NSTextField(labelWithString: "")
    let pathLabel = NSTextField(labelWithString: "")
    let countsLabel = NSTextField(labelWithString: "")
}

private final class LineRowCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
}

private final class ShowLargeCell: NSTableCellView {
    let button = ShowLargeButton(title: "", target: nil, action: nil)
}

final class DiffPaneViewController: NSViewController {
    var onRefresh: (() -> Void)?

    private let scroll = NSScrollView()
    private let outline = NSOutlineView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let column = NSTableColumn(identifier: .init("diff"))

    private var fileItems: [FileItem] = []

    private let monoFont = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    private lazy var rowHeight: CGFloat =
        ceil(monoFont.ascender - monoFont.descender + monoFont.leading) + 4
    private lazy var fileRowHeight: CGFloat = rowHeight + 6

    // Vivid, GitHub-style tints — stronger than the old washed-out 0.18 alpha, and
    // built from the dynamic `systemGreen`/`systemRed`/`labelColor` semantic colors
    // so they re-derive automatically for light vs. dark appearance.
    private let additionBackground = NSColor.systemGreen.withAlphaComponent(0.28)
    private let deletionBackground = NSColor.systemRed.withAlphaComponent(0.28)

    override func loadView() {
        let root = NSView()

        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshTapped))
        refresh.bezelStyle = .texturedRounded
        refresh.translatesAutoresizingMaskIntoConstraints = false

        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 14
        outline.selectionHighlightStyle = .none
        outline.usesAlternatingRowBackgroundColors = false
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.usesAutomaticRowHeights = true
        outline.dataSource = self
        outline.delegate = self
        outline.translatesAutoresizingMaskIntoConstraints = false

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        root.addSubview(refresh)
        root.addSubview(scroll)
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            refresh.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            refresh.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: refresh.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
    }

    @objc private func refreshTapped() { onRefresh?() }

    func showEmpty(message: String) {
        fileItems = []
        outline.reloadData()
        emptyLabel.stringValue = message
        emptyLabel.isHidden = false
        scroll.isHidden = true
    }

    func show(files: [DiffFile]) {
        guard !files.isEmpty else { showEmpty(message: "No changes"); return }
        fileItems = files.map(FileItem.init)
        emptyLabel.isHidden = true
        scroll.isHidden = false
        outline.reloadData()
    }

    @objc private func expandLargeFile(_ sender: NSButton) {
        guard let button = sender as? ShowLargeButton, let fileItem = button.fileItem else { return }
        fileItem.largeExpanded = true
        fileItem.invalidate()
        outline.reloadItem(fileItem, reloadChildren: true)
    }

    private func glyph(for kind: DiffChangeKind) -> String {
        switch kind {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        }
    }

    private func color(for kind: DiffChangeKind) -> NSColor {
        switch kind {
        case .added: return .systemGreen
        case .modified: return .systemYellow
        case .deleted: return .systemRed
        case .renamed: return .systemBlue
        }
    }

    /// Gutter char + text as one attributed string: the gutter is boldly colored
    /// (dynamic `systemGreen`/`systemRed`, so it re-derives for light/dark), the
    /// rest of the line uses `labelColor`/`secondaryLabelColor` so it stays legible
    /// against the tinted row background in both appearances.
    private func attributedLine(_ line: DiffLine) -> NSAttributedString {
        let gutter: String
        let gutterColor: NSColor
        let textColor: NSColor
        switch line.kind {
        case .addition: gutter = "+"; gutterColor = .systemGreen; textColor = .labelColor
        case .deletion: gutter = "-"; gutterColor = .systemRed;   textColor = .labelColor
        case .context:  gutter = " "; gutterColor = .secondaryLabelColor; textColor = .secondaryLabelColor
        }
        let result = NSMutableAttributedString(
            string: gutter,
            attributes: [.font: monoFont, .foregroundColor: gutterColor])
        result.append(NSAttributedString(
            string: line.text,
            attributes: [.font: monoFont, .foregroundColor: textColor]))
        return result
    }

    // MARK: - Cell factories (reused by identifier, à la SidebarController)

    private func makeFileCell() -> FileRowCell {
        let id = NSUserInterfaceItemIdentifier("fileRow")
        if let reused = outline.makeView(withIdentifier: id, owner: self) as? FileRowCell { return reused }
        let cell = FileRowCell()

        let glyph = cell.glyphLabel
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        glyph.alignment = .center

        let path = cell.pathLabel
        path.translatesAutoresizingMaskIntoConstraints = false
        path.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        path.lineBreakMode = .byTruncatingMiddle

        let counts = cell.countsLabel
        counts.translatesAutoresizingMaskIntoConstraints = false
        counts.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

        cell.addSubview(glyph)
        cell.addSubview(path)
        cell.addSubview(counts)
        cell.textField = path

        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            glyph.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 14),
            path.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 6),
            path.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            path.trailingAnchor.constraint(lessThanOrEqualTo: counts.leadingAnchor, constant: -8),
            counts.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            counts.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            // File rows stay single-line; a fixed height gives automatic-row-height
            // layout an unambiguous answer without needing top/bottom content pins.
            cell.heightAnchor.constraint(equalToConstant: fileRowHeight),
        ])
        cell.identifier = id
        return cell
    }

    private func makeLineCell() -> LineRowCell {
        let id = NSUserInterfaceItemIdentifier("lineRow")
        if let reused = outline.makeView(withIdentifier: id, owner: self) as? LineRowCell { return reused }
        let cell = LineRowCell()
        cell.wantsLayer = true

        let label = cell.label
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = monoFont
        // Wrap long diff lines to the pane width instead of clipping/scrolling —
        // char wrapping reads better than word wrapping for code (long identifiers,
        // no spaces to break on). The cell self-sizes from these constraints because
        // `outline.usesAutomaticRowHeights = true` (see loadView).
        label.lineBreakMode = .byCharWrapping
        label.maximumNumberOfLines = 0
        label.usesSingleLineMode = false
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        cell.addSubview(label)
        cell.textField = label

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            // A real (non-`lessThanOrEqualTo`) trailing constraint gives the label a
            // defined width so it knows where to wrap, and pinning top+bottom (rather
            // than centerY) lets the cell's height grow with the wrapped text.
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -2),
        ])
        cell.identifier = id
        return cell
    }

    private func makeShowLargeCell() -> ShowLargeCell {
        let id = NSUserInterfaceItemIdentifier("showLargeRow")
        if let reused = outline.makeView(withIdentifier: id, owner: self) as? ShowLargeCell { return reused }
        let cell = ShowLargeCell()
        let button = cell.button
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .inline
        button.target = self
        button.action = #selector(expandLargeFile(_:))
        cell.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            button.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            // Same rationale as the file cell: single-line content, fixed height so
            // automatic row heights don't need to guess.
            cell.heightAnchor.constraint(equalToConstant: fileRowHeight),
        ])
        cell.identifier = id
        return cell
    }
}

extension DiffPaneViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil: return fileItems.count
        case let fileItem as FileItem: return fileItem.rows().count
        default: return 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let fileItem = item as? FileItem { return fileItem.rows()[index] }
        return fileItems[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is FileItem
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let fileItem = item as? FileItem {
            let cell = makeFileCell()
            let file = fileItem.file
            cell.glyphLabel.stringValue = glyph(for: file.kind)
            cell.glyphLabel.textColor = color(for: file.kind)
            cell.pathLabel.stringValue = file.oldPath.map { "\($0) → \(file.path)" } ?? file.path

            let counts = NSMutableAttributedString(
                string: "+\(file.insertions)",
                attributes: [.font: cell.countsLabel.font as Any, .foregroundColor: NSColor.systemGreen])
            counts.append(NSAttributedString(string: " "))
            counts.append(NSAttributedString(
                string: "\u{2212}\(file.deletions)",
                attributes: [.font: cell.countsLabel.font as Any, .foregroundColor: NSColor.systemRed]))
            cell.countsLabel.attributedStringValue = counts
            return cell
        }

        guard let row = item as? RowItem else { return nil }
        switch row.kind {
        case .hunkHeader(let header):
            let cell = makeLineCell()
            cell.layer?.backgroundColor = nil
            cell.label.font = monoFont
            cell.label.textColor = .tertiaryLabelColor
            cell.label.stringValue = header
            return cell
        case .binaryNote:
            let cell = makeLineCell()
            cell.layer?.backgroundColor = nil
            cell.label.font = monoFont
            cell.label.textColor = .tertiaryLabelColor
            cell.label.stringValue = "Binary file changed"
            return cell
        case .line(let line):
            let cell = makeLineCell()
            switch line.kind {
            case .addition: cell.layer?.backgroundColor = additionBackground.cgColor
            case .deletion: cell.layer?.backgroundColor = deletionBackground.cgColor
            case .context:  cell.layer?.backgroundColor = nil
            }
            cell.label.attributedStringValue = attributedLine(line)
            return cell
        case .showLarge(let total):
            let cell = makeShowLargeCell()
            cell.button.title = "Show large diff (\(total) lines)"
            cell.button.fileItem = row.fileItem
            return cell
        }
    }
}
