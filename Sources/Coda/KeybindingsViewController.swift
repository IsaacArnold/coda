// Sources/Coda/KeybindingsViewController.swift
import AppKit
import CodaCore

/// The Keyboard Shortcuts settings pane: commands grouped by category, each with a chord
/// button (opens a recorder popover), an enable checkbox, and a conflict warning. Edits
/// mutate an in-memory Keybindings and report via onChange (the app persists + rebuilds).
final class KeybindingsViewController: NSViewController {
    private var bindings: Keybindings
    var onChange: ((Keybindings) -> Void)?

    private let stack = NSStackView()
    private var rows: [ShortcutCommand: RowViews] = [:]
    private var recorderPopover: NSPopover?

    private struct RowViews {
        let chordButton: NSButton
        let enableCheckbox: NSButton
        let warning: NSImageView
    }

    init(bindings: Keybindings) {
        self.bindings = bindings
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        for category in ShortcutCategory.allCases.sorted(by: { $0.order < $1.order }) {
            let commands = ShortcutCommand.allCases.filter { $0.category == category }
            guard !commands.isEmpty else { continue }
            let header = NSTextField(labelWithString: category.displayName)
            header.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            header.textColor = .secondaryLabelColor
            stack.addArrangedSubview(header)
            for command in commands { stack.addArrangedSubview(makeRow(command)) }
        }

        let reset = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
        reset.bezelStyle = .rounded
        stack.addArrangedSubview(reset)

        // The full command list is taller than the settings window, so host it in a vertical
        // scroll view. A flipped document view keeps (0,0) at the top-left so it scrolls
        // top-to-bottom and opens scrolled to the first row.
        let content = FlippedView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 460),
        ])

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        ])
        view = scroll
        refresh()
    }

    /// A top-left-origin view so the scroll view's document scrolls down from the top.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private func makeRow(_ command: ShortcutCommand) -> NSView {
        let name = NSTextField(labelWithString: command.displayName)
        name.widthAnchor.constraint(equalToConstant: 160).isActive = true

        let chordButton = NSButton(title: "", target: self, action: #selector(recordChord(_:)))
        chordButton.bezelStyle = .rounded
        chordButton.tag = ShortcutCommand.allCases.firstIndex(of: command)!
        chordButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true

        let warning = NSImageView()
        warning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Conflict")
        warning.contentTintColor = .systemYellow
        warning.isHidden = true

        let enable = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleEnabled(_:)))
        enable.tag = chordButton.tag

        let row = NSStackView(views: [name, chordButton, warning, enable])
        row.orientation = .horizontal
        row.spacing = 8
        rows[command] = RowViews(chordButton: chordButton, enableCheckbox: enable, warning: warning)

        // Per-row reset via context menu.
        let menu = NSMenu()
        let resetItem = NSMenuItem(title: "Reset to Default", action: #selector(resetOne(_:)), keyEquivalent: "")
        resetItem.target = self
        resetItem.tag = chordButton.tag
        menu.addItem(resetItem)
        row.menu = menu
        return row
    }

    private func command(for tag: Int) -> ShortcutCommand { ShortcutCommand.allCases[tag] }

    /// Refresh every row's chord title, enabled state, and conflict warning.
    private func refresh() {
        let conflicts = keybindingConflicts(bindings)
        for (command, views) in rows {
            let enabled = bindings.isEnabled(command)
            views.chordButton.title = bindings.chord(for: command).display
            views.chordButton.isEnabled = enabled
            // Bold when overridden from the default.
            views.chordButton.font = bindings.overrides[command.rawValue] != nil
                ? .boldSystemFont(ofSize: NSFont.systemFontSize)
                : .systemFont(ofSize: NSFont.systemFontSize)
            views.enableCheckbox.state = enabled ? .on : .off
            if let conflict = conflicts[command] {
                views.warning.isHidden = false
                views.warning.toolTip = Self.message(for: conflict)
            } else {
                views.warning.isHidden = true
            }
        }
    }

    private static func message(for conflict: ShortcutConflict) -> String {
        switch conflict.reason {
        case .command(let other): return "Conflicts with \"\(other.displayName)\"."
        case .reserved(let label): return "Conflicts with \"\(label)\" (system/terminal)."
        }
    }

    private func commit() { onChange?(bindings); refresh() }

    @objc private func toggleEnabled(_ sender: NSButton) {
        bindings.setEnabled(sender.state == .on, for: command(for: sender.tag))
        commit()
    }

    @objc private func resetOne(_ sender: NSMenuItem) {
        bindings.reset(command(for: sender.tag))
        commit()
    }

    @objc private func restoreDefaults() {
        bindings.resetAll()
        commit()
    }

    @objc private func recordChord(_ sender: NSButton) {
        let command = command(for: sender.tag)
        let recorder = HotkeyRecorderView(frame: NSRect(x: 0, y: 0, width: 220, height: 64))
        let label = NSTextField(labelWithString: "Press a shortcut…  (Esc to cancel)")
        label.frame = NSRect(x: 12, y: 22, width: 196, height: 20)
        recorder.addSubview(label)

        let popover = NSPopover()
        let vc = NSViewController()
        vc.view = recorder
        popover.contentViewController = vc
        popover.behavior = .transient
        recorderPopover = popover

        recorder.onCancel = { [weak self] in self?.recorderPopover?.close() }
        recorder.onRecorded = { [weak self] chord in
            guard let self else { return }
            self.bindings.setChord(chord, for: command)
            self.recorderPopover?.close()
            self.commit()   // conflicts shown via warning; binding committed regardless
        }

        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }
}
