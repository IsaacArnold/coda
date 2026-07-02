import AppKit
import CodaCore

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

/// Supacode's sidebar branch glyph — the GitHub-Octicons `git-branch` mark
/// (bundled from supacode's asset catalog), as a tintable template image.
/// Falls back to the SF Symbol on the unlikely chance the asset is missing.
func branchGlyphImage(diameter: CGFloat = 16) -> NSImage {
    let image: NSImage
    if let url = Bundle.codaAssets.url(forResource: "git-branch", withExtension: "svg", subdirectory: "Resources"),
       let asset = NSImage(contentsOf: url) {
        image = asset
    } else {
        image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "branch")
            ?? NSImage()
    }
    image.size = NSSize(width: diameter, height: diameter)
    image.isTemplate = true   // so contentTintColor (identity color) paints it
    return image
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

/// A worktree row, two-line à la Supacode: branch glyph + (title over a
/// `branch` subtitle) + a trailing agent-state badge dot.
/// The dot is a layer-drawn circle (not an SF symbol) so it always renders.
private final class WorktreeCellView: NSTableCellView {
    let badge = NSView()
    /// The `.footnote`-sized secondary subtitle (the branch name) under the title.
    let subtitleLabel = NSTextField(labelWithString: "")

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
    private var metrics = UIMetrics(scale: .medium)

    /// Selection drives the detail surface; the primary actions (add, new, launch,
    /// archive, settings) now live in the native menu bar and toolbar.
    var onSelect: ((Worktree?) -> Void)?

    /// Right-clicking a repo (or one of its worktrees) offers per-repo actions, keyed by
    /// the repo's id: open its settings sheet, or add a worktree to it.
    var onRepoSettings: ((String) -> Void)?
    var onNewWorktree: ((String) -> Void)?

    /// Right-click a worktree → pick a palette color for its identity bar/accent.
    var onSetWorktreeColor: ((String, String) -> Void)?
    /// Right-click a worktree → "Remove Color" — clear the override, back to the default look.
    var onRemoveWorktreeColor: ((String) -> Void)?

    /// Right-click a repo header → "Rename…" — set/clear the display-name override.
    var onRenameRepo: ((String) -> Void)?
    /// Right-click a repo header → "Set Color" swatch — apply a hex identity color.
    var onSetRepoColor: ((String, String) -> Void)?
    /// Right-click a repo header → "Remove Color" — clear the repo color.
    var onRemoveRepoColor: ((String) -> Void)?
    /// Right-click a repo header → "Remove Repository…" — forget the repo (no disk changes).
    var onRemoveRepo: ((String) -> Void)?

    /// An optional per-worktree identity-color override (active surface's effective color),
    /// keyed by worktree id; falls back to the worktree's own color when absent.
    private var identityOverrides: [String: NSColor] = [:]
    func setIdentityOverride(_ color: NSColor?, forWorktree id: String) {
        let changed = identityOverrides[id] != color
        if let color { identityOverrides[id] = color } else { identityOverrides[id] = nil }
        if changed { outline.reloadData() }
    }

    /// Adopt a new interface scale and restyle live. Row heights and cell fonts are
    /// recomputed on `reloadData()`; `noteHeightOfRows` forces the outline to re-measure.
    func apply(metrics: UIMetrics) {
        self.metrics = metrics
        outline.reloadData()
        let all = IndexSet(integersIn: 0..<outline.numberOfRows)
        outline.noteHeightOfRows(withIndexesChanged: all)
    }

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
        scroll.scrollerStyle = .overlay
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

    /// The worktree id of the right-clicked row, or nil if a repo header was clicked.
    private func clickedWorktreeID() -> String? {
        let row = outline.clickedRow
        guard row >= 0, let wt = outline.item(atRow: row) as? WorktreeNode else { return nil }
        return wt.worktree.id
    }

    /// The worktree the right-clicked row represents, or nil if a repo header was clicked.
    private func clickedWorktree() -> Worktree? {
        let row = outline.clickedRow
        guard row >= 0, let wt = outline.item(atRow: row) as? WorktreeNode else { return nil }
        return wt.worktree
    }

    @objc private func contextRemoveRepo(_ sender: NSMenuItem) {
        (sender.representedObject as? String).map { onRemoveRepo?($0) }
    }

    @objc private func contextSetColor(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let id = info["id"], let hex = info["hex"] else { return }
        onSetWorktreeColor?(id, hex)
    }

    @objc private func contextRemoveColor(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onRemoveWorktreeColor?(id)
    }

    @objc private func contextRepoSettings(_ sender: NSMenuItem) {
        (sender.representedObject as? String).map { onRepoSettings?($0) }
    }

    @objc private func contextNewWorktree(_ sender: NSMenuItem) {
        (sender.representedObject as? String).map { onNewWorktree?($0) }
    }

    @objc private func contextRenameRepo(_ sender: NSMenuItem) {
        (sender.representedObject as? String).map { onRenameRepo?($0) }
    }

    @objc private func contextSetRepoColor(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let id = info["id"], let hex = info["hex"] else { return }
        onSetRepoColor?(id, hex)
    }

    @objc private func contextRemoveRepoColor(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onRemoveRepoColor?(id)
    }

    func reload(sections: [RepositorySection], selectedWorktreeID: String?,
                selectedRepoID: String? = nil) {
        repoNodes = sections.map { section in
            RepoNode(repository: section.repository,
                     children: section.worktrees.map(WorktreeNode.init))
        }
        outline.reloadData()
        for node in repoNodes { outline.expandItem(node) }

        // Prefer a worktree selection; fall back to highlighting a repo header
        // (e.g. a freshly added repo that has no worktrees yet).
        let selectedItem: Any? = worktreeNode(id: selectedWorktreeID)
            ?? repoNode(id: selectedRepoID)
        if let selectedItem {
            let row = outline.row(forItem: selectedItem)
            if row >= 0 {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outline.scrollRowToVisible(row)
            }
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

    private func worktreeNode(id: String?) -> WorktreeNode? {
        guard let id else { return nil }
        for repo in repoNodes {
            if let match = repo.children.first(where: { $0.worktree.id == id }) { return match }
        }
        return nil
    }

    private func repoNode(id: String?) -> RepoNode? {
        guard let id else { return nil }
        return repoNodes.first(where: { $0.repository.id == id })
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

        // Repo-header right-click (not a worktree row): rename + color the repository.
        if clickedWorktreeID() == nil {
            menu.addItem(.separator())
            let rename = NSMenuItem(title: "Rename…",
                                    action: #selector(contextRenameRepo(_:)), keyEquivalent: "")
            rename.target = self
            rename.representedObject = repoID
            menu.addItem(rename)

            menu.addItem(ColorMenu.makeSetColorItem(
                targetID: repoID, target: self,
                setColor: #selector(contextSetRepoColor(_:)),
                removeColor: #selector(contextRemoveRepoColor(_:))))

            menu.addItem(.separator())
            let remove = NSMenuItem(title: "Remove Repository…",
                                    action: #selector(contextRemoveRepo(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = repoID
            menu.addItem(remove)
        }

        if let worktreeID = clickedWorktreeID(), clickedWorktree()?.isMain == false {
            menu.addItem(.separator())
            menu.addItem(ColorMenu.makeSetColorItem(
                targetID: worktreeID, target: self,
                setColor: #selector(contextSetColor(_:)),
                removeColor: #selector(contextRemoveColor(_:))))
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

    /// Worktree rows are two-line (title + subtitle); repo headers stay single-line.
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is WorktreeNode ? metrics.length(38) : metrics.length(24)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let repo = item as? RepoNode {
            // Repo rows are plain section headers, à la Supacode; tinted by the repo's color.
            let cell = makeCell(identifier: "repo", symbol: nil)
            cell.textField?.stringValue = repo.repository.sidebarDisplayName
            cell.textField?.font = metrics.sectionHeader
            let repoColor = repo.repository.color.flatMap { NSColor(hex: $0) }
            cell.textField?.textColor = repoColor
                ?? (chrome?.color(.secondaryText).nsColor) ?? .secondaryLabelColor
            return cell
        }
        if let wt = item as? WorktreeNode {
            let cell = makeWorktreeCell()
            cell.textField?.stringValue = wt.worktree.title
            // Subtitle is just the branch — the repo name is already the section header above.
            cell.subtitleLabel.stringValue = wt.worktree.branch
            cell.textField?.font = metrics.body
            cell.subtitleLabel.font = metrics.footnote
            cell.applyBadge(agentStates[wt.worktree.id] ?? .idle)
            let identity = identityOverrides[wt.worktree.id]
                ?? wt.worktree.color.flatMap { NSColor(hex: $0) }
            cell.applyIdentityColor(identity, glyphTint: chrome?.color(.glyphTint).nsColor)
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
        icon.image = branchGlyphImage()
        icon.contentTintColor = .secondaryLabelColor
        // Title: system body (13pt) — matches Supacode's `.font(.body)` worktree name.
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.font = .systemFont(ofSize: NSFont.systemFontSize)
        tf.lineBreakMode = .byTruncatingTail
        // Subtitle: secondary `.footnote` (10pt) — the branch name.
        let sub = cell.subtitleLabel
        sub.translatesAutoresizingMaskIntoConstraints = false
        sub.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        let badge = cell.badge
        badge.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon); cell.addSubview(tf); cell.addSubview(sub); cell.addSubview(badge)
        cell.imageView = icon; cell.textField = tf
        // Stack title over subtitle; the glyph + badge center across both lines.
        let textTop = tf.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            textTop,
            tf.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            tf.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -6),
            sub.topAnchor.constraint(equalTo: tf.bottomAnchor, constant: 1),
            sub.leadingAnchor.constraint(equalTo: tf.leadingAnchor),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -6),
            sub.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4),
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
