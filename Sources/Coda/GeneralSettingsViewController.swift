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
    private var uiScale: UIScale
    private let sizeStepper = NSStepper()
    private let sizeField = NSTextField()
    private let scalePopup = NSPopUpButton()

    private var notifyOnNeedsYou: Bool
    private var notifyOnDone: Bool
    private let notifyNeedsYouCheckbox = NSButton(checkboxWithTitle: "Notify when an agent needs you",
                                                  target: nil, action: nil)
    private let notifyDoneCheckbox = NSButton(checkboxWithTitle: "Notify when an agent finishes",
                                              target: nil, action: nil)

    var onChangeEditor: ((Editor) -> Void)?
    var onChangeFont: ((TerminalFontPref) -> Void)?
    var onChangeUIScale: ((UIScale) -> Void)?
    var onChangeNotifyOnNeedsYou: ((Bool) -> Void)?
    var onChangeNotifyOnDone: ((Bool) -> Void)?

    private static let otherTitle = "Other…"

    init(editor: Editor, terminalFont: NSFont, uiScale: UIScale,
         notifyOnNeedsYou: Bool, notifyOnDone: Bool) {
        self.editor = editor
        self.terminalFont = terminalFont
        self.uiScale = uiScale
        self.notifyOnNeedsYou = notifyOnNeedsYou
        self.notifyOnDone = notifyOnDone
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

        // Terminal size, decoupled from the font panel's preset list (which jumps 14→18).
        sizeStepper.minValue = 8
        sizeStepper.maxValue = 48
        sizeStepper.increment = 1
        sizeStepper.valueWraps = false
        sizeStepper.integerValue = Int(terminalFont.pointSize.rounded())
        sizeStepper.target = self
        sizeStepper.action = #selector(sizeStepperChanged)
        sizeField.stringValue = "\(Int(terminalFont.pointSize.rounded()))"
        sizeField.alignment = .right
        sizeField.target = self
        sizeField.action = #selector(sizeFieldChanged)
        sizeField.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let fontRow = NSStackView(views: [
            NSTextField(labelWithString: "Font:"), fontValueLabel, changeFontButton,
            NSTextField(labelWithString: "Size:"), sizeField, sizeStepper,
        ])
        fontRow.orientation = .horizontal
        fontRow.spacing = 8
        let fontHint = NSTextField(labelWithString: "Powerline / Nerd-Font glyphs render only if the chosen font includes them.")
        fontHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        fontHint.textColor = .secondaryLabelColor

        // Interface (chrome) size — four presets, applied live.
        let scaleTitle = NSTextField(labelWithString: "Interface size")
        scaleTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        for scale in UIScale.allCases { scalePopup.addItem(withTitle: scale.displayName) }
        scalePopup.selectItem(at: UIScale.allCases.firstIndex(of: uiScale) ?? 1)
        scalePopup.target = self
        scalePopup.action = #selector(scaleChanged)
        let scaleRow = NSStackView(views: [NSTextField(labelWithString: "Size:"), scalePopup])
        scaleRow.orientation = .horizontal
        scaleRow.spacing = 8
        let scaleHint = NSTextField(labelWithString: "Scales the sidebar, tabs, and labels. Applies immediately.")
        scaleHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        scaleHint.textColor = .secondaryLabelColor

        // Notifications — opt-in per event, independently toggleable.
        let notifyTitle = NSTextField(labelWithString: "Notifications")
        notifyTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        notifyNeedsYouCheckbox.state = notifyOnNeedsYou ? .on : .off
        notifyNeedsYouCheckbox.target = self
        notifyNeedsYouCheckbox.action = #selector(notifyNeedsYouChanged)
        notifyDoneCheckbox.state = notifyOnDone ? .on : .off
        notifyDoneCheckbox.target = self
        notifyDoneCheckbox.action = #selector(notifyDoneChanged)
        let notifyStack = NSStackView(views: [notifyNeedsYouCheckbox, notifyDoneCheckbox])
        notifyStack.orientation = .vertical
        notifyStack.alignment = .leading
        notifyStack.spacing = 6

        let stack = NSStackView(views: [
            title, row, hint,
            fontTitle, fontRow, fontHint,
            scaleTitle, scaleRow, scaleHint,
            notifyTitle, notifyStack,
        ])
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

    // The system monospaced font (`.monospacedSystemFont`, the default when the user hasn't
    // picked one) is an *abstract* font whose name is `.AppleSystemUIFontMonospaced-Regular`.
    // `NSFontManager.convert(_:)` cannot convert FROM such a font — it returns the system font
    // regardless of what the user picks in the panel, so the selection never takes. Seed the
    // panel (and the conversion) with a concrete equivalent. Menlo ships on every macOS.
    private func fontPanelBase() -> NSFont {
        guard terminalFont.fontName.hasPrefix(".") else { return terminalFont }
        return NSFont(name: "Menlo", size: terminalFont.pointSize) ?? terminalFont
    }

    @objc private func chooseFont() {
        // Anchor delivery to the responder chain: key window + first responder = self.
        view.window?.makeKeyAndOrderFront(nil)
        view.window?.makeFirstResponder(self)
        NSFontManager.shared.target = self
        NSFontManager.shared.action = #selector(changeFont(_:))
        NSFontManager.shared.setSelectedFont(fontPanelBase(), isMultiple: false)
        NSFontManager.shared.orderFrontFontPanel(self)
    }

    /// Sent by NSFontManager (via the responder chain) when the user picks a font.
    @objc func changeFont(_ sender: NSFontManager?) {
        guard let sender else { return }
        // Convert from a concrete base (see `fontPanelBase`), not the abstract system font.
        terminalFont = sender.convert(fontPanelBase())
        updateFontLabel()
        sizeStepper.integerValue = Int(terminalFont.pointSize.rounded())
        sizeField.stringValue = "\(Int(terminalFont.pointSize.rounded()))"
        onChangeFont?(TerminalFontPref(name: terminalFont.fontName, size: Double(terminalFont.pointSize)))
    }

    /// Emit the current font with a new size. Keeps the typeface; only the size changes.
    private func commitSize(_ newSize: Int) {
        let clamped = max(8, min(48, newSize))
        sizeStepper.integerValue = clamped
        sizeField.stringValue = "\(clamped)"
        if let resized = NSFont(name: terminalFont.fontName, size: CGFloat(clamped)) {
            terminalFont = resized
        }
        updateFontLabel()
        onChangeFont?(TerminalFontPref(name: terminalFont.fontName, size: Double(clamped)))
    }

    @objc private func sizeStepperChanged() { commitSize(sizeStepper.integerValue) }

    @objc private func sizeFieldChanged() {
        commitSize(Int(sizeField.stringValue) ?? Int(terminalFont.pointSize.rounded()))
    }

    @objc private func scaleChanged() {
        let idx = scalePopup.indexOfSelectedItem
        guard UIScale.allCases.indices.contains(idx) else { return }
        uiScale = UIScale.allCases[idx]
        onChangeUIScale?(uiScale)
    }

    @objc private func notifyNeedsYouChanged() {
        notifyOnNeedsYou = notifyNeedsYouCheckbox.state == .on
        onChangeNotifyOnNeedsYou?(notifyOnNeedsYou)
    }

    @objc private func notifyDoneChanged() {
        notifyOnDone = notifyDoneCheckbox.state == .on
        onChangeNotifyOnDone?(notifyOnDone)
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
