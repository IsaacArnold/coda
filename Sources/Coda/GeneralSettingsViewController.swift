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

    private let shellPopup = NSPopUpButton()
    private var shell: ShellChoice

    private var notifyOnNeedsYou: Bool
    private var notifyOnDone: Bool
    private let notifyNeedsYouCheckbox = NSButton(checkboxWithTitle: "Notify when an agent needs you",
                                                  target: nil, action: nil)
    private let notifyDoneCheckbox = NSButton(checkboxWithTitle: "Notify when an agent finishes",
                                              target: nil, action: nil)

    private var showDockBadge: Bool
    private let showDockBadgeCheckbox = NSButton(checkboxWithTitle: "Show a Dock badge when agents need you",
                                                 target: nil, action: nil)

    private var completionsEnabled: Bool
    private let completionsCheckbox = NSButton(checkboxWithTitle: "Show command completions in the terminal",
                                               target: nil, action: nil)

    private var accentValue: String            // serialized IdentityColorValue
    private let accentTheme: TerminalTheme      // paints the hue swatches
    private let accentSwatchRow = NSStackView()
    private var accentButtons: [NSButton] = []

    private var appIconName: String?
    private let appIconRow = NSStackView()
    private var appIconButtons: [NSButton] = []
    private let appIcons = AppIconCatalog.all()

    var onChangeEditor: ((Editor) -> Void)?
    var onChangeFont: ((TerminalFontPref) -> Void)?
    var onChangeUIScale: ((UIScale) -> Void)?
    var onChangeNotifyOnNeedsYou: ((Bool) -> Void)?
    var onChangeNotifyOnDone: ((Bool) -> Void)?
    var onChangeShowDockBadge: ((Bool) -> Void)?
    var onChangeShell: ((ShellChoice) -> Void)?
    var onChangeCompletionsEnabled: ((Bool) -> Void)?
    var onChangeAccentColor: ((String) -> Void)?
    var onChangeAppIcon: ((String) -> Void)?

    private static let otherTitle = "Other…"

    init(editor: Editor, terminalFont: NSFont, uiScale: UIScale,
         notifyOnNeedsYou: Bool, notifyOnDone: Bool, showDockBadge: Bool, shell: ShellChoice,
         completionsEnabled: Bool, accentValue: String, accentTheme: TerminalTheme,
         appIconName: String?) {
        self.editor = editor
        self.terminalFont = terminalFont
        self.uiScale = uiScale
        self.notifyOnNeedsYou = notifyOnNeedsYou
        self.notifyOnDone = notifyOnDone
        self.showDockBadge = showDockBadge
        self.shell = shell
        self.completionsEnabled = completionsEnabled
        self.accentValue = accentValue
        self.accentTheme = accentTheme
        self.appIconName = appIconName
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
        showDockBadgeCheckbox.state = showDockBadge ? .on : .off
        showDockBadgeCheckbox.target = self
        showDockBadgeCheckbox.action = #selector(showDockBadgeChanged)
        let notifyStack = NSStackView(views: [notifyNeedsYouCheckbox, notifyDoneCheckbox, showDockBadgeCheckbox])
        notifyStack.orientation = .vertical
        notifyStack.alignment = .leading
        notifyStack.spacing = 6

        // Shell — which shell new terminals launch. Applies to new terminals only.
        let shellTitle = NSTextField(labelWithString: "Shell")
        shellTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        for choice in ShellChoice.allCases { shellPopup.addItem(withTitle: choice.displayName) }
        shellPopup.selectItem(at: ShellChoice.allCases.firstIndex(of: shell) ?? 0)
        shellPopup.target = self
        shellPopup.action = #selector(shellChanged)
        let shellRow = NSStackView(views: [NSTextField(labelWithString: "Shell:"), shellPopup])
        shellRow.orientation = .horizontal
        shellRow.spacing = 8
        let shellHint = NSTextField(labelWithString: "Automatic uses your login shell. Applies to new terminals.")
        shellHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        shellHint.textColor = .secondaryLabelColor

        // Command completions — opt-in zsh shell integration (Task 5/6). Applies to new
        // terminals only; the ZDOTDIR wrapper is fixed at spawn.
        let completionsTitle = NSTextField(labelWithString: "Command Completions")
        completionsTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        completionsCheckbox.state = completionsEnabled ? .on : .off
        completionsCheckbox.target = self
        completionsCheckbox.action = #selector(completionsEnabledChanged)
        let completionsHint = NSTextField(labelWithString: "Adds an opt-in zsh integration to Coda terminals. Applies to newly-opened terminals.")
        completionsHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        completionsHint.textColor = .secondaryLabelColor

        // Accent colour — the sidebar's focused-worktree highlight. The active
        // theme's hue swatches (they follow the theme), plus a Custom… pin.
        let accentTitle = NSTextField(labelWithString: "Accent Colour")
        accentTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        accentSwatchRow.orientation = .horizontal
        accentSwatchRow.spacing = 8
        accentButtons = IdentityHue.allCases.enumerated().map { index, hue in
            let button = NSButton()
            button.title = ""
            button.isBordered = false
            button.image = Self.circleImage(accentTheme.color(for: hue).nsColor, diameter: 20)
            button.imageScaling = .scaleNone
            button.target = self
            button.action = #selector(accentSwatchClicked(_:))
            button.tag = index
            button.wantsLayer = true
            button.layer?.cornerRadius = 13
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
            accentSwatchRow.addArrangedSubview(button)
            return button
        }
        let customButton = NSButton(title: "Custom…", target: self, action: #selector(accentCustomClicked))
        customButton.bezelStyle = .rounded
        accentSwatchRow.addArrangedSubview(customButton)
        let accentHint = NSTextField(labelWithString: "Colour of the selected worktree/branch in the sidebar. Follows the theme.")
        accentHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        accentHint.textColor = .secondaryLabelColor

        // App icon — a gallery of bundled icons. Selecting one changes the running Dock icon.
        let appIconTitle = NSTextField(labelWithString: "App Icon")
        appIconTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        appIconRow.orientation = .horizontal
        appIconRow.spacing = 10
        appIconButtons = appIcons.enumerated().map { index, icon in
            let button = NSButton()
            button.title = ""
            button.isBordered = false
            button.image = Self.iconThumbnail(icon.image, side: 48)
            button.imageScaling = .scaleProportionallyUpOrDown
            button.toolTip = icon.displayName
            button.target = self
            button.action = #selector(appIconClicked(_:))
            button.tag = index
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            button.widthAnchor.constraint(equalToConstant: 56).isActive = true
            button.heightAnchor.constraint(equalToConstant: 56).isActive = true
            appIconRow.addArrangedSubview(button)
            return button
        }
        let appIconHint = NSTextField(labelWithString: "Changes the Dock icon. Applies immediately.")
        appIconHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        appIconHint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            title, row, hint,
            fontTitle, fontRow, fontHint,
            scaleTitle, scaleRow, scaleHint,
            notifyTitle, notifyStack,
            shellTitle, shellRow, shellHint,
            completionsTitle, completionsCheckbox, completionsHint,
            accentTitle, accentSwatchRow, accentHint,
            appIconTitle, appIconRow, appIconHint,
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
        updateAccentSelection()
        updateAppIconSelection()
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

    @objc private func shellChanged() {
        let idx = shellPopup.indexOfSelectedItem
        guard ShellChoice.allCases.indices.contains(idx) else { return }
        shell = ShellChoice.allCases[idx]
        onChangeShell?(shell)
    }

    @objc private func notifyNeedsYouChanged() {
        notifyOnNeedsYou = notifyNeedsYouCheckbox.state == .on
        onChangeNotifyOnNeedsYou?(notifyOnNeedsYou)
    }

    @objc private func notifyDoneChanged() {
        notifyOnDone = notifyDoneCheckbox.state == .on
        onChangeNotifyOnDone?(notifyOnDone)
    }

    @objc private func showDockBadgeChanged() {
        showDockBadge = showDockBadgeCheckbox.state == .on
        onChangeShowDockBadge?(showDockBadge)
    }

    @objc private func completionsEnabledChanged() {
        completionsEnabled = completionsCheckbox.state == .on
        onChangeCompletionsEnabled?(completionsEnabled)
    }

    @objc private func accentSwatchClicked(_ sender: NSButton) {
        let hues = IdentityHue.allCases
        guard hues.indices.contains(sender.tag) else { return }
        accentValue = IdentityColorValue.hue(hues[sender.tag]).serialized
        updateAccentSelection()
        onChangeAccentColor?(accentValue)
    }

    /// "Custom…" → open the colour panel and pin each pick live.
    @objc private func accentCustomClicked() {
        let current = IdentityColorValue.migrating(from: accentValue)?.resolved(accentTheme).nsColor
        PinColorPanel.shared.begin(initial: current) { [weak self] rgb in
            guard let self else { return }
            self.accentValue = IdentityColorValue.pinned(rgb).serialized
            self.updateAccentSelection()
            self.onChangeAccentColor?(self.accentValue)
        }
    }

    /// Ring the button whose hue matches the active accent (none when pinned/custom).
    private func updateAccentSelection() {
        let selectedHue: IdentityHue?
        if case .hue(let h) = IdentityColorValue.migrating(from: accentValue) { selectedHue = h }
        else { selectedHue = nil }
        for (index, button) in accentButtons.enumerated() {
            let isSelected = IdentityHue.allCases[index] == selectedHue
            button.layer?.borderWidth = isSelected ? 2 : 0
            button.layer?.borderColor = isSelected ? NSColor.labelColor.cgColor : nil
        }
    }

    /// A filled circle image for a swatch button.
    private static func circleImage(_ color: NSColor, diameter: CGFloat) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }

    @objc private func appIconClicked(_ sender: NSButton) {
        guard appIcons.indices.contains(sender.tag) else { return }
        appIconName = appIcons[sender.tag].id
        updateAppIconSelection()
        onChangeAppIcon?(appIcons[sender.tag].id)
    }

    /// Ring the button whose icon matches the active choice (nil → the "Default" entry).
    private func updateAppIconSelection() {
        let selectedID = appIconName ?? AppIconCatalog.defaultID
        for (index, button) in appIconButtons.enumerated() {
            let isSelected = appIcons[index].id == selectedID
            button.layer?.borderWidth = isSelected ? 2 : 0
            button.layer?.borderColor = isSelected ? NSColor.controlAccentColor.cgColor : nil
        }
    }

    /// A square, correctly-sized thumbnail for a swatch button (`.icns` images are multi-rep;
    /// setting an explicit size makes AppKit pick a crisp representation).
    private static func iconThumbnail(_ image: NSImage, side: CGFloat) -> NSImage {
        let copy = image.copy() as! NSImage
        copy.size = NSSize(width: side, height: side)
        return copy
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
