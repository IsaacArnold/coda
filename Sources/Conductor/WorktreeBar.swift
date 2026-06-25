// Sources/Conductor/WorktreeBar.swift
import AppKit
import ConductorCore

/// The full-width identity bar above the terminal: identity-color fill + worktree
/// title + branch + agent-state dot. The iTerm colored-tab analogue. Text auto-picks
/// black/white for contrast against the fill.
final class WorktreeBar: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    private let badge = NSView()
    static let height: CGFloat = 26

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        branchLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
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
}
