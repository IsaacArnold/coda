// Sources/Coda/WorktreeBar.swift
import AppKit
import CodaCore

/// The full-width identity bar above the terminal: identity-color fill + worktree
/// title + branch + agent-state dot. The iTerm colored-tab analogue. Text auto-picks
/// black/white for contrast against the fill.
final class WorktreeBar: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    private let badge = NSView()
    static let height: CGFloat = 26
    private var metrics = UIMetrics(scale: .medium)
    private var heightConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6   // rounded so the inset identity bar reads as a floating chip
        translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = heightAnchor.constraint(equalToConstant: Self.height)
        heightConstraint.isActive = true

        titleLabel.font = metrics.worktreeTitle
        branchLabel.font = metrics.worktreeBranch
        titleLabel.lineBreakMode = .byTruncatingTail
        branchLabel.lineBreakMode = .byTruncatingMiddle

        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleLabel, branchLabel, NSView(), badge])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            badge.widthAnchor.constraint(equalToConstant: 8),
            badge.heightAnchor.constraint(equalToConstant: 8),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func update(title: String?, branch: String?, colorHex: String?, agentState: AgentState) {
        guard let title else { isHidden = true; return }
        isHidden = false
        let fill = colorHex.flatMap { RGB(hex: $0) } ?? RGB(r: 0.4, g: 0.4, b: 0.4)
        layer?.backgroundColor = fill.nsColor.cgColor
        let textColor = fill.contrastingText.nsColor
        titleLabel.stringValue = title
        titleLabel.textColor = textColor
        branchLabel.stringValue = branch.map { "[\($0)]" } ?? ""
        branchLabel.textColor = textColor.withAlphaComponent(0.85)
        if let dot = agentBadgeColor(agentState) {
            badge.layer?.backgroundColor = dot.cgColor
            badge.isHidden = false
        } else {
            badge.isHidden = true
        }
    }

    /// Adopt a new interface scale: restyle the labels and resize the bar. The next
    /// `update(...)` (or the current text) re-lays out inside the new height.
    func apply(metrics: UIMetrics) {
        self.metrics = metrics
        titleLabel.font = metrics.worktreeTitle
        branchLabel.font = metrics.worktreeBranch
        heightConstraint.constant = metrics.length(Self.height)
    }
}
