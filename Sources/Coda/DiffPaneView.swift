import AppKit
import CodaCore

final class DiffPaneViewController: NSViewController {
    var onRefresh: (() -> Void)?

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let root = NSView()

        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshTapped))
        refresh.bezelStyle = .texturedRounded
        refresh.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll.documentView = stack
        scroll.hasVerticalScroller = true
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
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
    }

    @objc private func refreshTapped() { onRefresh?() }

    func showEmpty(message: String) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        emptyLabel.stringValue = message
        emptyLabel.isHidden = false
        scroll.isHidden = true
    }

    func show(files: [DiffFile]) {
        emptyLabel.isHidden = true
        scroll.isHidden = false
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if files.isEmpty { showEmpty(message: "No changes"); return }
        for file in files { stack.addArrangedSubview(FileSectionView(file: file)) }
    }
}

/// One collapsible file section: header (glyph + path + +/-), body of unified lines.
private final class FileSectionView: NSView {
    private var expanded = false
    private let file: DiffFile
    private let body = NSStackView()
    private let disclosure = NSTextField(labelWithString: "▸")

    init(file: DiffFile) {
        self.file = file
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        disclosure.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        disclosure.textColor = .secondaryLabelColor

        let glyph = NSTextField(labelWithString: Self.glyph(file.kind))
        let path = NSTextField(labelWithString: file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
        path.lineBreakMode = .byTruncatingMiddle
        path.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let counts = NSTextField(labelWithString: "+\(file.insertions) −\(file.deletions)")
        counts.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        counts.textColor = .secondaryLabelColor

        let header = NSStackView(views: [disclosure, glyph, path, NSView(), counts])
        header.orientation = .horizontal
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false

        let headerButton = HeaderButton()
        headerButton.onClick = { [weak self] in self?.toggle() }
        headerButton.translatesAutoresizingMaskIntoConstraints = false
        headerButton.addSubview(header)

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 0
        body.translatesAutoresizingMaskIntoConstraints = false

        let outer = NSStackView(views: [headerButton, body])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 2
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.leadingAnchor.constraint(equalTo: headerButton.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: headerButton.trailingAnchor),
            header.topAnchor.constraint(equalTo: headerButton.topAnchor, constant: 2),
            header.bottomAnchor.constraint(equalTo: headerButton.bottomAnchor, constant: -2),
        ])
        renderBody()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func toggle() { expanded.toggle(); renderBody() }

    private func renderBody() {
        disclosure.stringValue = expanded ? "▾" : "▸"
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard expanded else { return }
        if file.isBinary { body.addArrangedSubview(Self.note("Binary file changed")); return }
        if isLargeDiff(file) {
            let btn = NSButton(title: "Show large diff (\(file.insertions + file.deletions) lines)",
                               target: self, action: #selector(showLarge))
            btn.bezelStyle = .inline
            body.addArrangedSubview(btn)
            return
        }
        addLines()
    }

    @objc private func showLarge() {
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        addLines()
    }

    private func addLines() {
        for hunk in file.hunks {
            body.addArrangedSubview(Self.note(hunk.header))
            for line in hunk.lines { body.addArrangedSubview(Self.lineView(line)) }
        }
    }

    private static func glyph(_ k: DiffChangeKind) -> String {
        switch k { case .added: return "A"; case .modified: return "M"
                   case .deleted: return "D"; case .renamed: return "R" }
    }
    private static func note(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        t.textColor = .tertiaryLabelColor
        return t
    }
    private static func lineView(_ line: DiffLine) -> NSView {
        let prefix = line.kind == .addition ? "+" : line.kind == .deletion ? "-" : " "
        let t = NSTextField(labelWithString: prefix + line.text)
        t.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        t.lineBreakMode = .byCharWrapping
        t.wantsLayer = true
        switch line.kind {
        case .addition: t.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.18).cgColor
        case .deletion: t.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.18).cgColor
        case .context:  break
        }
        return t
    }
}

private final class HeaderButton: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}
