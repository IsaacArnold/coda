// Sources/Coda/SettingsCard.swift
import AppKit

/// A top-left-origin view so a scroll view's document scrolls down from the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A rounded grouped container that stacks rows full-width with a hairline separator
/// between each — the macOS System Settings "grouped box". Fill/corner are tunable.
final class SettingsCard: NSView {
    init(rows: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        // Subtle translucent fill so the themed window background shows through.
        applyFillColor()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        var arranged: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 { arranged.append(Self.separator()) }
            arranged.append(row)
        }
        for view in arranged {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// A CALayer background color does not track appearance changes on its own,
    /// so re-resolve the card fill whenever the effective appearance flips.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFillColor()
    }

    /// A subtle translucent overlay that reads on both dark and light backings.
    private func applyFillColor() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let fill = isDark ? NSColor.white.withAlphaComponent(0.05)
                          : NSColor.black.withAlphaComponent(0.04)
        layer?.backgroundColor = fill.cgColor
    }

    /// A 1pt hairline the full width of the card.
    private static func separator() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }
}

/// Row builders for the content inside a SettingsCard.
enum SettingsRow {
    /// A standard row, System Settings style: the title is pinned to the leading edge and
    /// its control to the trailing edge of the same line, and any description wraps as a
    /// full-width grey footnote beneath — so long descriptions get the whole card width
    /// instead of a cramped side column.
    static func make(title: String, subtitle: String? = nil, control: NSView) -> NSView {
        let hInset: CGFloat = 14, vPad: CGFloat = 10, gap: CGFloat = 12

        let row = NSView()
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        // The control keeps its natural width; the title yields if space is tight.
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        row.addSubview(titleLabel)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: hInset),
            titleLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: vPad),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -hInset),
            control.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            control.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: gap),
        ])

        if let subtitle {
            let sub = NSTextField(wrappingLabelWithString: subtitle)
            sub.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            sub.textColor = .secondaryLabelColor
            sub.isSelectable = false
            sub.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(sub)
            NSLayoutConstraint.activate([
                sub.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: hInset),
                sub.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -hInset),
                sub.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
                sub.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -vPad),
            ])
        } else {
            titleLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -vPad).isActive = true
        }
        return row
    }

    /// Wrap arbitrary content (a gallery, a table, a swatch row) with card padding so it
    /// can be dropped into a SettingsCard as a single row.
    static func padded(_ content: NSView,
                       insets: NSEdgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)) -> NSView {
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -insets.right),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets.bottom),
        ])
        return container
    }
}
