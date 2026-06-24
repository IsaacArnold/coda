import AppKit
import ConductorCore

/// Sheet to edit a repository's setupScript + copyAllowlist. Choose a repo from the
/// popup, edit the fields, then Save: it parses the allowlist, validates each path
/// (no absolute or `..` paths), and calls `onSave(repoID, setupScript, allowlist)`.
final class RepoSettingsController: NSViewController {
    private let repos: [Repository]
    private let popup = NSPopUpButton()
    private let setupScroll = NSScrollView()
    private let setupTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 80))
    private let allowlistScroll = NSScrollView()
    private let allowlistTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 120))
    private let errorLabel = NSTextField(labelWithString: "")

    var onSave: ((String, String, [String]) -> Void)?

    init(repos: [Repository]) {
        self.repos = repos
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let container = NSView()

        popup.target = self
        popup.action = #selector(repoChanged)
        for r in repos { popup.addItem(withTitle: r.name) }

        configureEditor(setupScroll, setupTextView)
        configureEditor(allowlistScroll, allowlistTextView)

        let setupLabel = NSTextField(labelWithString: "Setup script (runs once in the terminal before claude):")
        let allowlistLabel = NSTextField(labelWithString: "Copy into new worktrees — one path per line (e.g. .env):")
        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelAction))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(saveAction))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [errorLabel, cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [popup, setupLabel, setupScroll, allowlistLabel, allowlistScroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 540),
            setupScroll.heightAnchor.constraint(equalToConstant: 80),
            allowlistScroll.heightAnchor.constraint(equalToConstant: 140),
            setupScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            allowlistScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        view = container
        loadFields()
    }

    private func configureEditor(_ scroll: NSScrollView, _ tv: NSTextView) {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        tv.isRichText = false
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
    }

    private var selectedRepo: Repository? {
        let i = popup.indexOfSelectedItem
        return (i >= 0 && i < repos.count) ? repos[i] : nil
    }

    private func loadFields() {
        guard let r = selectedRepo else { return }
        setupTextView.string = r.setupScript
        allowlistTextView.string = r.copyAllowlist.joined(separator: "\n")
        errorLabel.stringValue = ""
    }

    @objc private func repoChanged() { loadFields() }
    @objc private func cancelAction() { dismiss(self) }

    @objc private func saveAction() {
        guard let r = selectedRepo else { dismiss(self); return }
        let allowlist = parseAllowlist(allowlistTextView.string)
        if let bad = allowlist.first(where: { !isSafeRelativePath($0) }) {
            errorLabel.stringValue = "Invalid path \u{201c}\(bad)\u{201d} — must be relative, no \u{201c}..\u{201d}."
            return
        }
        onSave?(r.id, setupTextView.string, allowlist)
        dismiss(self)
    }
}
