import AppKit
import CodaCore

enum StashAction {
    case apply(Int)
    case pop(Int)
    case drop(Int)
}

final class BranchPickerPanel: NSPanel {
    var onCheckout: ((Branch) -> Void)?
    var onStashAction: ((StashAction) -> Void)?

    private let effectView = NSVisualEffectView()
    private let searchField = NSTextField()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let stashBar = NSView()
    private let stashDisclosure = NSButton()
    private let stashLabel = NSTextField(labelWithString: "")
    private let stashListView = NSStackView()
    private let errorLabel = NSTextField(labelWithString: "")
    private let confirmationView = NSView()
    private let confirmLabel = NSTextField(labelWithString: "")
    private let confirmButton = NSButton()
    private let cancelButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: "No branches")

    private var allBranches: [Branch] = []
    private var filteredBranches: [Branch] = []
    private var stashes: [Stash] = []
    private var stashExpanded = false

    static let panelWidth: CGFloat = 300
    static let maxPanelHeight: CGFloat = 400
    static let rowHeight: CGFloat = 24
    static let sectionHeaderHeight: CGFloat = 20
    static let searchFieldHeight: CGFloat = 28
    static let stashBarHeight: CGFloat = 32
    static let cornerRadius: CGFloat = 8

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing bufferingType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: [.nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        hidesOnDeactivate = false

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
        setupTableView(in: content)
        setupStashBar(in: content)
        setupConfirmationView(in: content)
        setupErrorLabel(in: content)
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
        searchField.target = self
        searchField.action = #selector(searchChanged)
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
        tableView.selectionHighlightStyle = .regular
        tableView.doubleAction = #selector(tableDoubleClicked)
        tableView.target = self
        tableView.delegate = self
        tableView.dataSource = self

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
    }

    private func setupStashBar(in container: NSView) {
        stashBar.translatesAutoresizingMaskIntoConstraints = false
        stashBar.isHidden = true

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        stashBar.addSubview(separator)

        stashDisclosure.bezelStyle = .disclosure
        stashDisclosure.title = ""
        stashDisclosure.state = .off
        stashDisclosure.target = self
        stashDisclosure.action = #selector(toggleStashExpansion)
        stashDisclosure.translatesAutoresizingMaskIntoConstraints = false
        stashBar.addSubview(stashDisclosure)

        stashLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stashLabel.textColor = .secondaryLabelColor
        stashLabel.translatesAutoresizingMaskIntoConstraints = false
        stashBar.addSubview(stashLabel)

        stashListView.orientation = .vertical
        stashListView.spacing = 2
        stashListView.translatesAutoresizingMaskIntoConstraints = false
        stashListView.isHidden = true
        stashBar.addSubview(stashListView)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: stashBar.topAnchor),
            separator.leadingAnchor.constraint(equalTo: stashBar.leadingAnchor, constant: 8),
            separator.trailingAnchor.constraint(equalTo: stashBar.trailingAnchor, constant: -8),
            stashDisclosure.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            stashDisclosure.leadingAnchor.constraint(equalTo: stashBar.leadingAnchor, constant: 8),
            stashLabel.centerYAnchor.constraint(equalTo: stashDisclosure.centerYAnchor),
            stashLabel.leadingAnchor.constraint(equalTo: stashDisclosure.trailingAnchor, constant: 4),
            stashListView.topAnchor.constraint(equalTo: stashDisclosure.bottomAnchor, constant: 4),
            stashListView.leadingAnchor.constraint(equalTo: stashBar.leadingAnchor, constant: 8),
            stashListView.trailingAnchor.constraint(equalTo: stashBar.trailingAnchor, constant: -8),
            stashListView.bottomAnchor.constraint(equalTo: stashBar.bottomAnchor, constant: -4),
        ])

        container.addSubview(stashBar)
    }

    private func setupConfirmationView(in container: NSView) {
        confirmationView.translatesAutoresizingMaskIntoConstraints = false
        confirmationView.isHidden = true
        confirmationView.wantsLayer = true
        confirmationView.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.9).cgColor
        confirmationView.layer?.cornerRadius = 6

        confirmLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        confirmLabel.textColor = .labelColor
        confirmLabel.lineBreakMode = .byWordWrapping
        confirmLabel.maximumNumberOfLines = 3
        confirmLabel.translatesAutoresizingMaskIntoConstraints = false
        confirmationView.addSubview(confirmLabel)

        confirmButton.title = "Stash & Switch"
        confirmButton.bezelStyle = .rounded
        confirmButton.controlSize = .small
        confirmButton.target = self
        confirmButton.action = #selector(confirmClicked)
        confirmButton.translatesAutoresizingMaskIntoConstraints = false
        confirmationView.addSubview(confirmButton)

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        confirmationView.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            confirmLabel.topAnchor.constraint(equalTo: confirmationView.topAnchor, constant: 8),
            confirmLabel.leadingAnchor.constraint(equalTo: confirmationView.leadingAnchor, constant: 12),
            confirmLabel.trailingAnchor.constraint(equalTo: confirmationView.trailingAnchor, constant: -12),
            confirmButton.topAnchor.constraint(equalTo: confirmLabel.bottomAnchor, constant: 8),
            confirmButton.trailingAnchor.constraint(equalTo: confirmationView.trailingAnchor, constant: -12),
            confirmButton.bottomAnchor.constraint(equalTo: confirmationView.bottomAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: confirmButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: confirmButton.leadingAnchor, constant: -8),
        ])

        container.addSubview(confirmationView)
    }

    private func setupErrorLabel(in container: NSView) {
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(errorLabel)
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

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            stashBar.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stashBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stashBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stashBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            errorLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            errorLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            errorLabel.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -4),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            confirmationView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            confirmationView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            confirmationView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -8),
        ])
    }

    // MARK: - Public API

    func show(relativeTo button: NSView, branches: [Branch], stashes: [Stash]) {
        self.allBranches = branches
        self.stashes = stashes
        self.stashExpanded = false
        stashDisclosure.state = .off
        stashListView.isHidden = true
        confirmationView.isHidden = true
        errorLabel.isHidden = true
        searchField.stringValue = ""
        applyFilter()
        updateStashBar()
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
    }

    func dismiss() {
        orderOut(nil)
    }

    func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.errorLabel.isHidden = true
        }
    }

    private var pendingConfirmAction: (() -> Void)?

    func showConfirmation(message: String, onConfirm: @escaping () -> Void) {
        confirmLabel.stringValue = message
        pendingConfirmAction = onConfirm
        confirmationView.isHidden = false
    }

    func updateStashes(_ stashes: [Stash]) {
        self.stashes = stashes
        updateStashBar()
        if stashExpanded { rebuildStashList() }
        updatePanelSize()
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

    private func updateStashBar() {
        stashBar.isHidden = stashes.isEmpty
        stashLabel.stringValue = stashes.count == 1 ? "1 stash" : "\(stashes.count) stashes"
    }

    private func rebuildStashList() {
        stashListView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for stash in stashes {
            let row = makeStashRow(stash)
            stashListView.addArrangedSubview(row)
        }
    }

    private func makeStashRow(_ stash: Stash) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 4

        let label = NSTextField(labelWithString: "stash@{\(stash.id)}: \(stash.message)")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let applyBtn = makeSmallButton("Apply") { [weak self] in
            self?.onStashAction?(.apply(stash.id))
        }
        let popBtn = makeSmallButton("Pop") { [weak self] in
            self?.onStashAction?(.pop(stash.id))
        }
        let dropBtn = makeSmallButton("Drop") { [weak self] in
            self?.onStashAction?(.drop(stash.id))
        }

        row.addArrangedSubview(label)
        row.addArrangedSubview(applyBtn)
        row.addArrangedSubview(popBtn)
        row.addArrangedSubview(dropBtn)
        return row
    }

    private func makeSmallButton(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = CallbackButton(title: title, action: action)
        button.controlSize = .mini
        button.bezelStyle = .recessed
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return button
    }

    private func updatePanelSize() {
        let branchCount = filteredBranches.count
        let sectionCount = (localBranches.isEmpty ? 0 : 1) + (remoteBranches.isEmpty ? 0 : 1)
        let tableHeight = CGFloat(branchCount) * Self.rowHeight
            + CGFloat(sectionCount) * Self.sectionHeaderHeight
        let stashHeight: CGFloat = stashes.isEmpty ? 0 : (stashExpanded
            ? Self.stashBarHeight + CGFloat(stashes.count) * 24 + 8
            : Self.stashBarHeight)
        let totalHeight = Self.searchFieldHeight + 12
            + min(tableHeight, Self.maxPanelHeight - Self.searchFieldHeight - 12 - stashHeight)
            + stashHeight
        let clampedHeight = min(max(totalHeight, 80), Self.maxPanelHeight)
        var frame = self.frame
        let heightDelta = clampedHeight - frame.height
        frame.origin.y -= heightDelta
        frame.size.height = clampedHeight
        frame.size.width = Self.panelWidth
        setFrame(frame, display: true)
    }

    // MARK: - Actions

    @objc private func searchChanged() { applyFilter() }

    @objc private func tableDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, let branch = branchForRow(row) else { return }
        onCheckout?(branch)
    }

    @objc private func toggleStashExpansion() {
        stashExpanded.toggle()
        stashDisclosure.state = stashExpanded ? .on : .off
        stashListView.isHidden = !stashExpanded
        if stashExpanded { rebuildStashList() }
        updatePanelSize()
    }

    @objc private func confirmClicked() {
        confirmationView.isHidden = true
        pendingConfirmAction?()
        pendingConfirmAction = nil
    }

    @objc private func cancelClicked() {
        confirmationView.isHidden = true
        pendingConfirmAction = nil
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }

    override func resignKey() {
        super.resignKey()
        dismiss()
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
        if case .sectionHeader = tableItems[row].kind { return false }
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, let branch = branchForRow(row) else { return }
        onCheckout?(branch)
    }
}

// MARK: - CallbackButton

private final class CallbackButton: NSButton {
    private var callback: (() -> Void)?

    convenience init(title: String, action: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.callback = action
        self.target = self
        self.action = #selector(clicked)
    }

    @objc private func clicked() { callback?() }
}
