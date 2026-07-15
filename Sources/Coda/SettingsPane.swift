// Sources/Coda/SettingsPane.swift
import AppKit

/// Builds the standard scaffold for a settings detail pane: a vertical scroll view with a
/// large title header above a stack of cards. Cards stretch to the pane width; content
/// scrolls when it exceeds the pane height. Insets/spacing are tunable.
enum SettingsPane {
    static let horizontalInset: CGFloat = 24

    static func makeScrollView(title: String, cards: [NSView]) -> NSScrollView {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 22, weight: .bold)

        let stack = NSStackView(views: [header] + cards)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 24, left: horizontalInset, bottom: 24, right: horizontalInset)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = FlippedView()
        content.addSubview(stack)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.documentView = content
        content.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            // Pin the stack to the document view.
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            // Document view width tracks the clip view so cards fill the pane (no h-scroll).
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
        ])
        // Cards fill the width between the stack's horizontal insets.
        for card in cards {
            card.widthAnchor.constraint(equalTo: content.widthAnchor,
                                        constant: -2 * horizontalInset).isActive = true
        }
        return scroll
    }
}
