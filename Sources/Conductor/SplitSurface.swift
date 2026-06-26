// Sources/Conductor/SplitSurface.swift
import AppKit
import ConductorCore

/// One surface tab's content: a tree of terminal panes rendered as nested NSSplitViews.
/// Owns a pure `PaneTree<TerminalSurface>`; the shell rebuilds the view hierarchy from it
/// after every structural change. A single-pane surface is just the one terminal view
/// (no NSSplitView) so unsplit tabs behave exactly like PR A.
final class SplitSurface: NSViewController {
    private let tree: PaneTree<TerminalSurface>
    /// Builds a fresh pane (id + TerminalSurface) for the worktree — used on every split.
    private let makePane: () -> (id: String, pane: TerminalSurface)
    private let container = NSView()

    /// Fires when the focused pane changes or its title changes (so the tab bar/chrome refresh).
    var onFocusChange: (() -> Void)?
    /// Identity color for the focused-pane border (worktree/tab color).
    var identityColor: NSColor? { didSet { updateFocusBorders() } }

    init(firstPane: TerminalSurface, firstID: String,
         makePane: @escaping () -> (id: String, pane: TerminalSurface)) {
        self.tree = PaneTree(rootID: firstID, firstPane)
        self.makePane = makePane
        super.init(nibName: nil, bundle: nil)
        wire(firstPane, id: firstID)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        container.translatesAutoresizingMaskIntoConstraints = false
        view = container
        rebuild()
    }

    var allPanes: [TerminalSurface] { tree.leaves.map { $0.leaf } }
    var focusedPane: TerminalSurface { tree.focusedLeaf ?? tree.leaves[0].leaf }

    func splitFocused(axis: SplitAxis) {
        let made = makePane()
        tree.splitFocused(axis: axis, newID: made.id, newLeaf: made.pane)
        wire(made.pane, id: made.id)
        rebuild()
        distributeDividers()
        focusActivePane()
        onFocusChange?()
    }

    /// Close the focused pane. Returns false when it was the last pane (caller closes the tab).
    @discardableResult
    func closeFocused() -> Bool {
        let target = tree.focusedLeafID
        let pane = tree.leaf(id: target)
        let remaining = tree.close(id: target)
        guard remaining else { return false }
        pane?.view.removeFromSuperview(); pane?.removeFromParent()
        rebuild()
        distributeDividers()
        focusActivePane()
        onFocusChange?()
        return true
    }

    func moveFocus(_ direction: PaneDirection) {
        let frames = tree.leaves.map { entry -> PaneRect in
            let f = entry.leaf.view.convert(entry.leaf.view.bounds, to: container)
            // NSView is bottom-left origin; flip y to top-left for Core's convention.
            let topY = container.bounds.height - f.maxY
            return PaneRect(id: entry.id, x: Double(f.minX), y: Double(topY),
                            width: Double(f.width), height: Double(f.height))
        }
        guard let next = nearestPane(from: tree.focusedLeafID, direction: direction, frames: frames) else { return }
        tree.setFocus(id: next)
        focusActivePane()
        onFocusChange?()
    }

    /// The pane whose view contains the click (for ⌘+click open-file routing).
    func paneContaining(_ event: NSEvent) -> TerminalSurface? {
        allPanes.first { $0.containsClick(event) }
    }

    // MARK: - private

    private func wire(_ pane: TerminalSurface, id: String) {
        addChild(pane)
        pane.onFocused = { [weak self] in
            guard let self else { return }
            self.tree.setFocus(id: id)
            self.updateFocusBorders()
            self.onFocusChange?()
        }
        // Title changes already call AppDelegate's onTitleChange (set when the pane is built);
        // we additionally refresh on focus change so the tab label tracks the focused pane.
    }

    private func focusActivePane() {
        view.window?.makeFirstResponder(focusedPane.view)
        updateFocusBorders()
    }

    /// Highlight the focused pane with a 1px identity-color border; clear the others.
    private func updateFocusBorders() {
        for entry in tree.leaves {
            let v = entry.leaf.view
            v.wantsLayer = true
            let focused = entry.id == tree.focusedLeafID && tree.count > 1
            v.layer?.borderWidth = focused ? 1 : 0
            v.layer?.borderColor = (focused ? identityColor : nil)?.cgColor
        }
    }

    /// Rebuild the view hierarchy from the tree.
    private func rebuild() {
        container.subviews.forEach { $0.removeFromSuperview() }
        let rootView = buildView(tree.root)
        rootView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(rootView)
        NSLayoutConstraint.activate([
            rootView.topAnchor.constraint(equalTo: container.topAnchor),
            rootView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            rootView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            rootView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        updateFocusBorders()
    }

    private func buildView(_ node: PaneTree<TerminalSurface>.Node) -> NSView {
        switch node {
        case let .leaf(_, pane):
            pane.view.translatesAutoresizingMaskIntoConstraints = true
            pane.view.autoresizingMask = [.width, .height]
            return pane.view
        case let .split(axis, a, b, _):
            let split = NSSplitView()
            split.isVertical = (axis == .horizontal)   // side-by-side ⇒ vertical dividers
            split.dividerStyle = .thin
            split.translatesAutoresizingMaskIntoConstraints = true
            split.autoresizingMask = [.width, .height]
            split.addArrangedSubview(buildView(a))
            split.addArrangedSubview(buildView(b))
            return split
        }
    }

    /// Even out every NSSplitView once real sizes exist (the spike's deferred pattern).
    private func distributeDividers() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.container.layoutSubtreeIfNeeded()
            self.splitViews(in: self.container).forEach(self.distribute)
        }
    }

    private func splitViews(in v: NSView) -> [NSSplitView] {
        var out: [NSSplitView] = []
        if let s = v as? NSSplitView { out.append(s) }
        v.subviews.forEach { out += splitViews(in: $0) }
        return out
    }

    private func distribute(_ split: NSSplitView) {
        let n = split.arrangedSubviews.count
        guard n > 1 else { return }
        let vertical = split.isVertical
        let total = vertical ? split.bounds.width : split.bounds.height
        let dividerW = split.dividerThickness
        let usable = total - dividerW * CGFloat(n - 1)
        guard usable > 0 else { return }
        let pane = usable / CGFloat(n)
        for i in 0..<(n - 1) {
            let pos = CGFloat(i + 1) * pane + CGFloat(i) * dividerW
            split.setPosition(pos, ofDividerAt: i)
        }
    }
}
