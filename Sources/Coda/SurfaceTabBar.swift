// Sources/Coda/SurfaceTabBar.swift
import AppKit
import CodaCore

/// One tab's display state, computed by AppDelegate from Core's Surface + live title + badge.
struct SurfaceTabItem {
    let id: String
    let label: String
    let state: AgentState
    let isActive: Bool
    /// The tab's effective identity color (per-tab override → worktree color), or nil.
    let tint: NSColor?
}

/// The per-worktree surface tab bar: a horizontal row of tab buttons (badge dot + label +
/// close ×) and a trailing "+" to open a new tab. Sits between the identity bar and the
/// terminal. Rebuilt wholesale on `update(items:)`; it holds no model state of its own.
final class SurfaceTabBar: NSView {
    static let height: CGFloat = 28

    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onNew: (() -> Void)?
    /// Right-click on a tab → (surfaceID, anchorView) so the caller can pop a context menu.
    var onContext: ((String, NSView) -> Void)?

    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func update(items: [SurfaceTabItem]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items { stack.addArrangedSubview(makeTab(item)) }
        let plus = NSButton(title: "+", target: self, action: #selector(newTapped))
        plus.bezelStyle = .texturedRounded
        plus.setButtonType(.momentaryPushIn)
        stack.addArrangedSubview(plus)
    }

    @objc private func newTapped() { onNew?() }

    private func makeTab(_ item: SurfaceTabItem) -> NSView {
        let tab = TabButtonView(id: item.id)
        tab.translatesAutoresizingMaskIntoConstraints = false
        tab.wantsLayer = true
        tab.layer?.cornerRadius = 5
        tab.layer?.backgroundColor = (item.isActive
            ? NSColor.selectedControlColor.withAlphaComponent(0.35)
            : NSColor.clear).cgColor
        tab.onClick = { [weak self] in self?.onSelect?(item.id) }
        tab.onContext = { [weak self] view in self?.onContext?(item.id, view) }

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        if let c = agentBadgeColor(item.state) {
            dot.layer?.backgroundColor = c.cgColor
            dot.isHidden = false
        } else {
            dot.isHidden = true
        }

        let label = NSTextField(labelWithString: item.label)
        label.font = .systemFont(ofSize: 11, weight: item.isActive ? .semibold : .regular)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = item.tint ?? .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let close = NSButton(title: "", target: tab, action: #selector(TabButtonView.closeTapped))
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        close.imageScaling = .scaleProportionallyDown
        close.isBordered = false
        close.translatesAutoresizingMaskIntoConstraints = false
        tab.onClose = { [weak self] in self?.onClose?(item.id) }

        let row = NSStackView(views: [dot, label, close])
        row.orientation = .horizontal
        row.spacing = 5
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 6)
        row.translatesAutoresizingMaskIntoConstraints = false
        tab.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: tab.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: tab.trailingAnchor),
            row.topAnchor.constraint(equalTo: tab.topAnchor),
            row.bottomAnchor.constraint(equalTo: tab.bottomAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            close.widthAnchor.constraint(equalToConstant: 14),
            close.heightAnchor.constraint(equalToConstant: 14),
            tab.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            tab.heightAnchor.constraint(equalToConstant: 22),
        ])
        return tab
    }
}

/// A clickable tab background that reports left-click (select), the close button, and
/// right-click (context menu) back to the bar.
private final class TabButtonView: NSView {
    let id: String
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    var onContext: ((NSView) -> Void)?
    init(id: String) { self.id = id; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onContext?(self) }
    @objc func closeTapped() { onClose?() }
}
