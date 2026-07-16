// Sources/Coda/GeneralPaneViewController.swift
import AppKit
import CodaCore

/// Settings → General: default editor, interface size, and the app-icon gallery. Editor and
/// app-icon logic are carried over from the former single-tab general pane.
final class GeneralPaneViewController: NSViewController {
    private let context: SettingsContext
    private var editor: Editor
    private var appIconName: String?

    private let editorPopup = NSPopUpButton()
    private let scalePopup = NSPopUpButton()
    private let appIconRow = NSStackView()
    private var appIconButtons: [NSButton] = []
    private let appIcons = AppIconCatalog.all()

    private static let otherTitle = "Other…"

    init(context: SettingsContext) {
        self.context = context
        self.editor = context.editor
        self.appIconName = context.appIconName
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        // --- Default editor ---
        editorPopup.target = self
        editorPopup.action = #selector(editorChanged)
        rebuildPopup()
        let editorRow = SettingsRow.make(title: "Default Editor",
                                         subtitle: "Used by “Open in…” and ⌘-click in the terminal.",
                                         control: editorPopup)

        // --- Interface size ---
        for scale in UIScale.allCases { scalePopup.addItem(withTitle: scale.displayName) }
        scalePopup.selectItem(at: UIScale.allCases.firstIndex(of: context.uiScale) ?? 1)
        scalePopup.target = self
        scalePopup.action = #selector(scaleChanged)
        let scaleRow = SettingsRow.make(title: "Interface Size",
                                        subtitle: "Scales the sidebar, tabs, and labels. Applies immediately.",
                                        control: scalePopup)

        let editorCard = SettingsCard(rows: [editorRow, scaleRow])

        // --- App icon gallery ---
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
        let appIconTitle = NSTextField(labelWithString: "App Icon")
        appIconTitle.font = .systemFont(ofSize: NSFont.systemFontSize)
        let appIconHint = NSTextField(labelWithString: "Changes the Dock icon. Applies immediately.")
        appIconHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        appIconHint.textColor = .secondaryLabelColor
        let appIconContent = NSStackView(views: [appIconTitle, appIconRow, appIconHint])
        appIconContent.orientation = .vertical
        appIconContent.alignment = .leading
        appIconContent.spacing = 8
        let appIconCard = SettingsCard(rows: [SettingsRow.padded(appIconContent)])

        view = SettingsPane.makeScrollView(title: "General", cards: [editorCard, appIconCard])
        updateAppIconSelection()
    }

    // MARK: Editor (carried over)

    private func rebuildPopup() {
        editorPopup.removeAllItems()
        for e in Editor.knownEditors { editorPopup.addItem(withTitle: e.name) }
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
            context.onChangeEditor(chosen)
        }
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
            selectCurrent()
            return
        }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        let custom = Editor(name: name, bundleID: bundleID, urlScheme: "")
        editor = custom
        context.onChangeEditor(custom)
        rebuildPopup()
    }

    // MARK: Interface size

    @objc private func scaleChanged() {
        let idx = scalePopup.indexOfSelectedItem
        guard UIScale.allCases.indices.contains(idx) else { return }
        context.onChangeUIScale(UIScale.allCases[idx])
    }

    // MARK: App icon (carried over)

    @objc private func appIconClicked(_ sender: NSButton) {
        guard appIcons.indices.contains(sender.tag) else { return }
        appIconName = appIcons[sender.tag].id
        updateAppIconSelection()
        context.onChangeAppIcon(appIcons[sender.tag].id)
    }

    private func updateAppIconSelection() {
        let selectedID = appIconName ?? AppIconCatalog.defaultID
        for (index, button) in appIconButtons.enumerated() {
            let isSelected = appIcons[index].id == selectedID
            button.layer?.borderWidth = isSelected ? 2 : 0
            button.layer?.borderColor = isSelected ? NSColor.controlAccentColor.cgColor : nil
        }
    }

    private static func iconThumbnail(_ image: NSImage, side: CGFloat) -> NSImage {
        let copy = image.copy() as! NSImage
        copy.size = NSSize(width: side, height: side)
        return copy
    }
}
