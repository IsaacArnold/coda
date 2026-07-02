import AppKit
import CodaCore

/// Content of the app-wide Settings window (⌘,). One "General" pane today: the default
/// editor used by Open-in and the terminal's ⌘-click jump (room for themes/keybinds later).
/// The picker offers a curated list of editors with known URL schemes, plus "Other…" to
/// pick any installed app (bundle-id open only — no line-jump scheme). Edits are reported
/// via `onChangeEditor`; the app persists them to `PreferencesStore`.
final class GeneralSettingsViewController: NSViewController {
    private let editorPopup = NSPopUpButton()
    private var editor: Editor

    private let fontValueLabel = NSTextField(labelWithString: "")
    private var terminalFont: NSFont

    var onChangeEditor: ((Editor) -> Void)?
    var onChangeFont: ((TerminalFontPref) -> Void)?

    private static let otherTitle = "Other…"

    init(editor: Editor, terminalFont: NSFont) {
        self.editor = editor
        self.terminalFont = terminalFont
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let container = NSView()

        let title = NSTextField(labelWithString: "Default editor")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let hint = NSTextField(labelWithString: "Used by “Open in…” and ⌘-click in the terminal.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor

        editorPopup.target = self
        editorPopup.action = #selector(editorChanged)
        rebuildPopup()

        let row = NSStackView(views: [NSTextField(labelWithString: "Editor:"), editorPopup])
        row.orientation = .horizontal
        row.spacing = 8

        let fontTitle = NSTextField(labelWithString: "Terminal font")
        fontTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        updateFontLabel()
        let changeFontButton = NSButton(title: "Change…", target: self, action: #selector(chooseFont))
        let fontRow = NSStackView(views: [NSTextField(labelWithString: "Font:"), fontValueLabel, changeFontButton])
        fontRow.orientation = .horizontal
        fontRow.spacing = 8
        let fontHint = NSTextField(labelWithString: "Powerline / Nerd-Font glyphs render only if the chosen font includes them.")
        fontHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        fontHint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, row, hint, fontTitle, fontRow, fontHint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 420),
        ])
        view = container
    }

    private func rebuildPopup() {
        editorPopup.removeAllItems()
        for e in Editor.knownEditors { editorPopup.addItem(withTitle: e.name) }
        // A custom "Other…" pick isn't in the curated list — surface it as its own entry
        // so the user can see what's currently set.
        if !Editor.knownEditors.contains(where: { $0.bundleID == editor.bundleID }) {
            editorPopup.addItem(withTitle: editor.name)
        }
        editorPopup.menu?.addItem(.separator())
        editorPopup.addItem(withTitle: Self.otherTitle)
        selectCurrent()
    }

    private func selectCurrent() {
        if let i = Editor.knownEditors.firstIndex(where: { $0.bundleID == editor.bundleID }) {
            editorPopup.selectItem(at: i)
        } else {
            editorPopup.selectItem(withTitle: editor.name)
        }
    }

    @objc private func editorChanged() {
        let title = editorPopup.titleOfSelectedItem ?? ""
        if title == Self.otherTitle {
            pickOtherApp()
        } else if let chosen = Editor.knownEditors.first(where: { $0.name == title }) {
            editor = chosen
            onChangeEditor?(chosen)
        }
        // else: the custom entry is already selected — nothing changed.
    }

    private func updateFontLabel() {
        let name = terminalFont.displayName ?? terminalFont.fontName
        fontValueLabel.stringValue = "\(name) \(Int(terminalFont.pointSize))"
    }

    // NSFontManager delivers `changeFont(_:)` via the *responder chain* (the `target`
    // property is only reliably honored on some macOS versions / configurations — e.g. a
    // third-party font manager or a differing key/main window can leave `target` ineffective,
    // silently dropping the message). So don't rely on `target` alone: make this controller
    // the settings window's first responder while the panel is up, so the message reaches us
    // through the chain regardless.
    override var acceptsFirstResponder: Bool { true }

    @objc private func chooseFont() {
        // Anchor delivery to the responder chain: key window + first responder = self.
        view.window?.makeKeyAndOrderFront(nil)
        view.window?.makeFirstResponder(self)
        NSFontManager.shared.target = self
        NSFontManager.shared.action = #selector(changeFont(_:))
        NSFontManager.shared.setSelectedFont(terminalFont, isMultiple: false)
        NSFontManager.shared.orderFrontFontPanel(self)
    }

    /// Sent by NSFontManager (via the responder chain) when the user picks a font.
    @objc func changeFont(_ sender: NSFontManager?) {
        guard let sender else { return }
        terminalFont = sender.convert(terminalFont)
        updateFontLabel()
        onChangeFont?(TerminalFontPref(name: terminalFont.fontName, size: Double(terminalFont.pointSize)))
    }

    private func pickOtherApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else {
            selectCurrent()   // cancelled — restore the popup to the active editor
            return
        }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        // No reliable URL scheme for an arbitrary app → empty scheme: opens by bundle id,
        // with no ⌘-click line-jump (graceful degradation per editorOpenURL).
        let custom = Editor(name: name, bundleID: bundleID, urlScheme: "")
        editor = custom
        onChangeEditor?(custom)
        rebuildPopup()
    }
}
