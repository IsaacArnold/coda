// Sources/Coda/AppearancePaneViewController.swift
import AppKit
import CodaCore

/// Settings → Appearance: the installed-theme list (with Import/Apply) and the sidebar
/// accent-colour swatches. Theme logic is carried over from ThemeSettingsViewController;
/// accent logic from the former GeneralSettingsViewController.
final class AppearancePaneViewController: NSViewController {
    private let context: SettingsContext
    private var themeNames: [String]
    private var activeTheme: String?
    private var accentValue: String
    private let accentTheme: TerminalTheme

    private let tableView = NSTableView()
    private let accentSwatchRow = NSStackView()
    private var accentButtons: [NSButton] = []

    init(context: SettingsContext) {
        self.context = context
        self.themeNames = context.themeNames
        self.activeTheme = context.activeThemeName
        self.accentValue = context.accentValue
        self.accentTheme = context.accentTheme
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        // --- Theme card ---
        let column = NSTableColumn(identifier: .init("theme"))
        column.title = "Theme"
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(applySelectedTheme)
        tableView.target = self
        tableView.backgroundColor = .clear

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 200).isActive = true

        let applyButton = NSButton(title: "Apply", target: self, action: #selector(applySelectedTheme))
        let importButton = NSButton(title: "Import .itermcolors…", target: self, action: #selector(importTheme))
        let buttons = NSStackView(views: [importButton, NSView(), applyButton])
        buttons.orientation = .horizontal

        let themeContent = NSStackView(views: [scroll, buttons])
        themeContent.orientation = .vertical
        themeContent.alignment = .leading
        themeContent.spacing = 10
        // Let the scroll view stretch to the card width.
        scroll.widthAnchor.constraint(equalTo: themeContent.widthAnchor).isActive = true
        buttons.widthAnchor.constraint(equalTo: themeContent.widthAnchor).isActive = true
        let themeCard = SettingsCard(rows: [SettingsRow.padded(themeContent)])

        // --- Accent card ---
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

        let accentTitle = NSTextField(labelWithString: "Accent Colour")
        accentTitle.font = .systemFont(ofSize: NSFont.systemFontSize)
        let accentHint = NSTextField(labelWithString: "Colour of the selected worktree/branch in the sidebar. Follows the theme.")
        accentHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        accentHint.textColor = .secondaryLabelColor
        let accentContent = NSStackView(views: [accentTitle, accentSwatchRow, accentHint])
        accentContent.orientation = .vertical
        accentContent.alignment = .leading
        accentContent.spacing = 8
        let accentCard = SettingsCard(rows: [SettingsRow.padded(accentContent)])

        view = SettingsPane.makeScrollView(title: "Appearance", cards: [themeCard, accentCard])
        selectActiveThemeRow()
        updateAccentSelection()
    }

    // MARK: Theme (carried over from ThemeSettingsViewController)

    private func selectActiveThemeRow() {
        if let activeTheme, let idx = themeNames.firstIndex(of: activeTheme) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
    }

    @objc private func applySelectedTheme() {
        let row = tableView.selectedRow
        guard row >= 0, row < themeNames.count else { return }
        activeTheme = themeNames[row]
        context.onApplyTheme(themeNames[row])
    }

    @objc private func importTheme() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["itermcolors"]
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        context.onImportTheme(url)
        let name = url.deletingPathExtension().lastPathComponent
        if !themeNames.contains(name) { themeNames.append(name); themeNames.sort() }
        tableView.reloadData()
        if let idx = themeNames.firstIndex(of: name) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
    }

    // MARK: Accent (carried over from GeneralSettingsViewController)

    @objc private func accentSwatchClicked(_ sender: NSButton) {
        let hues = IdentityHue.allCases
        guard hues.indices.contains(sender.tag) else { return }
        accentValue = IdentityColorValue.hue(hues[sender.tag]).serialized
        updateAccentSelection()
        context.onChangeAccentColor(accentValue)
    }

    @objc private func accentCustomClicked() {
        let current = IdentityColorValue.migrating(from: accentValue)?.resolved(accentTheme).nsColor
        PinColorPanel.shared.begin(initial: current) { [weak self] rgb in
            guard let self else { return }
            self.accentValue = IdentityColorValue.pinned(rgb).serialized
            self.updateAccentSelection()
            self.context.onChangeAccentColor(self.accentValue)
        }
    }

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

    private static func circleImage(_ color: NSColor, diameter: CGFloat) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }
}

extension AppearancePaneViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { themeNames.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("themeCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let c = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf); c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            c.identifier = id
            return c
        }()
        cell.textField?.stringValue = themeNames[row]
        return cell
    }
}
