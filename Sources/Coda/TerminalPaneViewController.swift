// Sources/Coda/TerminalPaneViewController.swift
import AppKit
import CodaCore

/// Settings → Terminal: font & size, shell, and command completions. Font/shell logic is
/// carried over verbatim from the former general pane; the completions
/// control is now an NSSwitch. Edits report via the context.
final class TerminalPaneViewController: NSViewController {
    private let context: SettingsContext
    private var terminalFont: NSFont
    private var shell: ShellChoice

    private let fontValueLabel = NSTextField(labelWithString: "")
    private let sizeStepper = NSStepper()
    private let sizeField = NSTextField()
    private let shellPopup = NSPopUpButton()
    private let completionsSwitch = NSSwitch()

    init(context: SettingsContext) {
        self.context = context
        self.terminalFont = context.terminalFont
        self.shell = context.shell
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    override func loadView() {
        // --- Font & size row ---
        updateFontLabel()
        let changeFontButton = NSButton(title: "Change…", target: self, action: #selector(chooseFont))

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

        let fontControls = NSStackView(views: [
            fontValueLabel, changeFontButton,
            NSTextField(labelWithString: "Size:"), sizeField, sizeStepper,
        ])
        fontControls.orientation = .horizontal
        fontControls.spacing = 8
        let fontRow = SettingsRow.make(title: "Font",
                                       subtitle: "Powerline / Nerd-Font glyphs render only if the chosen font includes them.",
                                       control: fontControls)

        // --- Shell row ---
        for choice in ShellChoice.allCases { shellPopup.addItem(withTitle: choice.displayName) }
        shellPopup.selectItem(at: ShellChoice.allCases.firstIndex(of: shell) ?? 0)
        shellPopup.target = self
        shellPopup.action = #selector(shellChanged)
        let shellRow = SettingsRow.make(title: "Shell",
                                        subtitle: "Automatic uses your login shell. Applies to new terminals.",
                                        control: shellPopup)

        // --- Command completions row ---
        completionsSwitch.state = context.completionsEnabled ? .on : .off
        completionsSwitch.target = self
        completionsSwitch.action = #selector(completionsChanged)
        let completionsRow = SettingsRow.make(title: "Command Completions",
                                              subtitle: "Adds an opt-in zsh integration to Coda terminals. Applies to newly-opened terminals.",
                                              control: completionsSwitch)

        let card = SettingsCard(rows: [fontRow, shellRow, completionsRow])
        view = SettingsPane.makeScrollView(title: "Terminal", cards: [card])
    }

    // MARK: Font (carried over from the former general pane)

    private func updateFontLabel() {
        let name = terminalFont.displayName ?? terminalFont.fontName
        fontValueLabel.stringValue = "\(name) \(Int(terminalFont.pointSize))"
    }

    /// The system monospaced font is abstract; NSFontManager.convert cannot convert from it.
    /// Seed with a concrete equivalent (Menlo ships on every macOS).
    private func fontPanelBase() -> NSFont {
        guard terminalFont.fontName.hasPrefix(".") else { return terminalFont }
        return NSFont(name: "Menlo", size: terminalFont.pointSize) ?? terminalFont
    }

    @objc private func chooseFont() {
        view.window?.makeKeyAndOrderFront(nil)
        view.window?.makeFirstResponder(self)
        NSFontManager.shared.target = self
        NSFontManager.shared.action = #selector(changeFont(_:))
        NSFontManager.shared.setSelectedFont(fontPanelBase(), isMultiple: false)
        NSFontManager.shared.orderFrontFontPanel(self)
    }

    @objc func changeFont(_ sender: NSFontManager?) {
        guard let sender else { return }
        terminalFont = sender.convert(fontPanelBase())
        updateFontLabel()
        sizeStepper.integerValue = Int(terminalFont.pointSize.rounded())
        sizeField.stringValue = "\(Int(terminalFont.pointSize.rounded()))"
        context.onChangeFont(TerminalFontPref(name: terminalFont.fontName, size: Double(terminalFont.pointSize)))
    }

    private func commitSize(_ newSize: Int) {
        let clamped = max(8, min(48, newSize))
        sizeStepper.integerValue = clamped
        sizeField.stringValue = "\(clamped)"
        if let resized = NSFont(name: terminalFont.fontName, size: CGFloat(clamped)) {
            terminalFont = resized
        }
        updateFontLabel()
        context.onChangeFont(TerminalFontPref(name: terminalFont.fontName, size: Double(clamped)))
    }

    @objc private func sizeStepperChanged() { commitSize(sizeStepper.integerValue) }
    @objc private func sizeFieldChanged() {
        commitSize(Int(sizeField.stringValue) ?? Int(terminalFont.pointSize.rounded()))
    }

    // MARK: Shell / completions

    @objc private func shellChanged() {
        let idx = shellPopup.indexOfSelectedItem
        guard ShellChoice.allCases.indices.contains(idx) else { return }
        shell = ShellChoice.allCases[idx]
        context.onChangeShell(shell)
    }

    @objc private func completionsChanged() {
        context.onChangeCompletionsEnabled(completionsSwitch.state == .on)
    }
}
