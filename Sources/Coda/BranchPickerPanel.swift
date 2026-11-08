import AppKit
import CodaCore

final class BranchPickerPanel: NSPanel, NSTextFieldDelegate {
    var onCheckout: ((Branch) -> Void)?
    /// The user asked to bring back the changes stashed when they last left the current branch.
    var onRestoreStash: (() -> Void)?

    private let effectView = NSVisualEffectView()
    private let searchField = NSTextField()
    private let restoreBar = NSView()
    private let restoreLabel = NSTextField(labelWithString: "")
    private let restoreButton = NSButton()
    private let scrollView = NSScrollView()
    private let tableView = HoverTableView()
    private let emptyLabel = NSTextField(labelWithString: "No branches")

    private var allBranches: [Branch] = []
    private var filteredBranches: [Branch] = []
    /// Branches with changes Coda stashed when the user switched away from them.
    private var stashedBranches: Set<String> = []
    private var restoreBarHeight: NSLayoutConstraint?
    private var keyMonitor: Any?

    static let panelWidth: CGFloat = 300
    static let maxPanelHeight: CGFloat = 400
    static let rowHeight: CGFloat = 24
    static let sectionHeaderHeight: CGFloat = 20
    static let searchFieldHeight: CGFloat = 28
    static let restoreBarHeight: CGFloat = 34
    static let cornerRadius: CGFloat = 8

    override var canBecomeKey: Bool { true }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing bufferingType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: [.nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        level = .floating
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        hidesOnDeactivate = true

        let content = NSView(frame: contentRect)
        contentView = content

        effectView.material = .menu
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = Self.cornerRadius
        effectView.layer?.masksToBounds = true
        effectView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(effectView)

        setupSearchField(in: content)
        setupRestoreBar(in: content)
        setupTableView(in: content)
        setupEmptyLabel(in: content)
        layoutSubviews(in: content)
    }

    // MARK: - Setup

    private func setupSearchField(in container: NSView) {
        searchField.placeholderString = "Filter branches..."
        searchField.isBordered = false
        searchField.focusRingType = .none
        searchField.drawsBackground = false
        searchField.font = .systemFont(ofSize: NSFont.systemFontSize)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        container.addSubview(searchField)
    }

    private func setupTableView(in container: NSView) {
        let column = NSTableColumn(identifier: .init("branch"))
        column.title = ""
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.target = self
        tableView.action = #selector(tableClicked)
        tableView.delegate = self
        tableView.dataSource = self

        tableView.onHoverChanged = { [weak self] row in
            self?.updateHover(row: row)
        }

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
    }

    private func setupRestoreBar(in container: NSView) {
        restoreBar.translatesAutoresizingMaskIntoConstraints = false
        restoreBar.isHidden = true

        let icon = NSImageView(image: Self.stashSymbol(pointSize: 12) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        restoreBar.addSubview(icon)

        restoreLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        restoreLabel.textColor = .labelColor
        restoreLabel.lineBreakMode = .byTruncatingTail
        restoreLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        restoreLabel.translatesAutoresizingMaskIntoConstraints = false
        restoreBar.addSubview(restoreLabel)

        restoreButton.title = "Restore"
        restoreButton.bezelStyle = .rounded
        restoreButton.controlSize = .small
        restoreButton.keyEquivalent = ""
        restoreButton.target = self
        restoreButton.action = #selector(restoreClicked)
        restoreButton.translatesAutoresizingMaskIntoConstraints = false
        restoreBar.addSubview(restoreButton)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        restoreBar.addSubview(separator)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: restoreBar.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: restoreBar.centerYAnchor),
            restoreLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            restoreLabel.centerYAnchor.constraint(equalTo: restoreBar.centerYAnchor),
            restoreButton.leadingAnchor.constraint(greaterThanOrEqualTo: restoreLabel.trailingAnchor, constant: 8),
            restoreButton.trailingAnchor.constraint(equalTo: restoreBar.trailingAnchor, constant: -10),
            restoreButton.centerYAnchor.constraint(equalTo: restoreBar.centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: restoreBar.leadingAnchor, constant: 8),
            separator.trailingAnchor.constraint(equalTo: restoreBar.trailingAnchor, constant: -8),
            separator.bottomAnchor.constraint(equalTo: restoreBar.bottomAnchor),
        ])

        container.addSubview(restoreBar)
    }

    /// The "changes tucked away" glyph used on stashed branch rows and the restore bar.
    static func stashSymbol(pointSize: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        return NSImage(systemSymbolName: "tray.full", accessibilityDescription: "Stashed changes")?
            .withSymbolConfiguration(config)
    }

    private func setupEmptyLabel(in container: NSView) {
        emptyLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)
    }

    private func layoutSubviews(in container: NSView) {
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: container.topAnchor),
            effectView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            effectView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            searchField.heightAnchor.constraint(equalToConstant: Self.searchFieldHeight),

            restoreBar.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            restoreBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            restoreBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: restoreBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
        let height = restoreBar.heightAnchor.constraint(equalToConstant: 0)
        height.isActive = true
        restoreBarHeight = height
    }

    // MARK: - Public API

    func show(relativeTo button: NSView, branches: [Branch], stashedBranches: Set<String>) {
        self.allBranches = branches
        self.stashedBranches = stashedBranches
        searchField.stringValue = ""
        applyFilter()
        updateRestoreBar()
        updatePanelSize()

        guard let buttonWindow = button.window,
              let screen = buttonWindow.screen else { return }
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)
        let origin = NSPoint(x: screenRect.minX, y: screenRect.minY - frame.height - 4)
        let clamped = NSPoint(
            x: min(origin.x, screen.visibleFrame.maxX - frame.width),
            y: max(origin.y, screen.visibleFrame.minY)
        )
        setFrameOrigin(clamped)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(searchField)
        installKeyMonitor()
    }

    func dismiss() {
        removeKeyMonitor()
        orderOut(nil)
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            if event.keyCode == 53 {
                self.dismiss()
                return nil
            }
            if event.keyCode == 36 {
                let row = self.tableView.hoveredRow >= 0 ? self.tableView.hoveredRow : -1
                if let branch = self.branchForRow(row) {
                    self.onCheckout?(branch)
                    return nil
                }
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    // MARK: - NSTextFieldDelegate (live search filtering)

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    override func resignKey() {
        super.resignKey()
        removeKeyMonitor()
        dismiss()
    }

    // MARK: - Internal

    private func applyFilter() {
        let query = searchField.stringValue.lowercased()
        if query.isEmpty {
            filteredBranches = allBranches
        } else {
            filteredBranches = allBranches.filter {
                $0.shortName.lowercased().contains(query)
            }
        }
        emptyLabel.isHidden = !filteredBranches.isEmpty
        tableView.reloadData()
    }

    private var localBranches: [Branch] { filteredBranches.filter { !$0.isRemote } }
    private var remoteBranches: [Branch] { filteredBranches.filter { $0.isRemote } }

    private var currentBranchName: String? {
        allBranches.first(where: { $0.isHead })?.name
    }

    private var showsRestoreBar: Bool {
        guard let current = currentBranchName else { return false }
        return stashedBranches.contains(current)
    }

    private func updateRestoreBar() {
        let show = showsRestoreBar
        restoreBar.isHidden = !show
        restoreBarHeight?.constant = show ? Self.restoreBarHeight : 0
        restoreLabel.stringValue = "You left changes on \(currentBranchName ?? "")"
    }

    private func updatePanelSize() {
        let branchCount = filteredBranches.count
        let sectionCount = (localBranches.isEmpty ? 0 : 1) + (remoteBranches.isEmpty ? 0 : 1)
        let tableHeight = CGFloat(branchCount) * Self.rowHeight
            + CGFloat(sectionCount) * Self.sectionHeaderHeight
        let barHeight: CGFloat = showsRestoreBar ? Self.restoreBarHeight : 0
        let totalHeight = Self.searchFieldHeight + 12
            + min(tableHeight, Self.maxPanelHeight - Self.searchFieldHeight - 12 - barHeight)
            + barHeight
        let clampedHeight = min(max(totalHeight, 80), Self.maxPanelHeight)
        var frame = self.frame
        let heightDelta = clampedHeight - frame.height
        frame.origin.y -= heightDelta
        frame.size.height = clampedHeight
        frame.size.width = Self.panelWidth
        setFrame(frame, display: true)
    }

    private func updateHover(row: Int) {
        for r in 0..<tableView.numberOfRows {
            guard let rowView = tableView.rowView(atRow: r, makeIfNecessary: false) else { continue }
            if r == row, branchForRow(r) != nil {
                rowView.wantsLayer = true
                rowView.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
                rowView.layer?.cornerRadius = 4
            } else {
                rowView.layer?.backgroundColor = nil
            }
        }
    }

    // MARK: - Actions

    @objc private func tableClicked() {
        let row = tableView.clickedRow
        guard row >= 0, let branch = branchForRow(row) else { return }
        onCheckout?(branch)
    }

    @objc private func restoreClicked() {
        onRestoreStash?()
    }

    // MARK: - Table helpers

    private struct TableItem {
        enum Kind { case sectionHeader(String), branch(Branch) }
        let kind: Kind
    }

    private var tableItems: [TableItem] {
        var items: [TableItem] = []
        let local = localBranches
        let remote = remoteBranches
        if !local.isEmpty {
            items.append(TableItem(kind: .sectionHeader("Local")))
            items += local.map { TableItem(kind: .branch($0)) }
        }
        if !remote.isEmpty {
            items.append(TableItem(kind: .sectionHeader("Remote")))
            items += remote.map { TableItem(kind: .branch($0)) }
        }
        return items
    }

    private func branchForRow(_ row: Int) -> Branch? {
        let items = tableItems
        guard items.indices.contains(row) else { return nil }
        if case .branch(let b) = items[row].kind { return b }
        return nil
    }
}

// MARK: - NSTableViewDataSource & NSTableViewDelegate

extension BranchPickerPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { tableItems.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let items = tableItems
        guard items.indices.contains(row) else { return nil }
        switch items[row].kind {
        case .sectionHeader(let title):
            let cell = NSTextField(labelWithString: title)
            cell.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            cell.textColor = .secondaryLabelColor
            return cell
        case .branch(let branch):
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.spacing = 6
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 8)
            let checkmark = NSTextField(labelWithString: branch.isHead ? "\u{2713}" : "")
            checkmark.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            checkmark.textColor = .controlAccentColor
            checkmark.widthAnchor.constraint(equalToConstant: 14).isActive = true
            let nameLabel = NSTextField(labelWithString: branch.shortName)
            nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
            nameLabel.textColor = .labelColor
            nameLabel.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(checkmark)
            stack.addArrangedSubview(nameLabel)
            if !branch.isRemote, stashedBranches.contains(branch.name),
               let symbol = Self.stashSymbol(pointSize: 11) {
                let spacer = NSView()
                spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
                let marker = NSImageView(image: symbol)
                marker.contentTintColor = .controlAccentColor
                marker.toolTip = "You left uncommitted changes here. Switch back to restore them."
                stack.addArrangedSubview(spacer)
                stack.addArrangedSubview(marker)
            }
            return stack
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let items = tableItems
        guard items.indices.contains(row) else { return Self.rowHeight }
        if case .sectionHeader = items[row].kind { return Self.sectionHeaderHeight }
        return Self.rowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }
}

// MARK: - HoverTableView (mouse tracking for row hover)

private final class HoverTableView: NSTableView {
    var onHoverChanged: ((Int) -> Void)?
    private(set) var hoveredRow: Int = -1
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row != hoveredRow {
            hoveredRow = row
            onHoverChanged?(row)
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredRow = -1
        onHoverChanged?(-1)
    }
}
