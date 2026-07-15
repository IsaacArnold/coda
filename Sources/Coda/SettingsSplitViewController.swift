// Sources/Coda/SettingsSplitViewController.swift
import AppKit
import CodaCore

/// The Settings window content: a source-list sidebar on the left and a detail pane on the
/// right that swaps view controllers as the selection changes (macOS System Settings style).
final class SettingsSplitViewController: NSSplitViewController {
    private let context: SettingsContext
    private let sidebar = SettingsSidebarViewController()
    private let detailContainer = NSViewController()
    private var currentPane: NSViewController?

    init(context: SettingsContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        // A plain container that hosts the current pane as its only child.
        detailContainer.view = NSView()
        detailContainer.view.translatesAutoresizingMaskIntoConstraints = true
        super.loadView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 240
        sidebarItem.canCollapse = false
        addSplitViewItem(sidebarItem)

        let detailItem = NSSplitViewItem(viewController: detailContainer)
        detailItem.minimumThickness = 460
        addSplitViewItem(detailItem)

        sidebar.onSelect = { [weak self] category in self?.show(category) }
        sidebar.selectFirst()
    }

    private func show(_ category: SettingsCategory) {
        currentPane?.view.removeFromSuperview()
        currentPane?.removeFromParent()

        let pane = category.makePane(context: context)
        addChild(pane)
        pane.view.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.view.addSubview(pane.view)
        NSLayoutConstraint.activate([
            pane.view.topAnchor.constraint(equalTo: detailContainer.view.topAnchor),
            pane.view.leadingAnchor.constraint(equalTo: detailContainer.view.leadingAnchor),
            pane.view.trailingAnchor.constraint(equalTo: detailContainer.view.trailingAnchor),
            pane.view.bottomAnchor.constraint(equalTo: detailContainer.view.bottomAnchor),
        ])
        currentPane = pane
    }
}

/// The Coda-layer mapping from a (pure-data) SettingsCategory to its AppKit pane VC. Kept
/// out of CodaCore so the enum stays framework-free.
extension SettingsCategory {
    func makePane(context: SettingsContext) -> NSViewController {
        switch self {
        case .general:       return GeneralPaneViewController(context: context)
        case .appearance:    return AppearancePaneViewController(context: context)
        case .terminal:      return TerminalPaneViewController(context: context)
        case .notifications: return NotificationsPaneViewController(context: context)
        case .shortcuts:
            let vc = KeybindingsViewController(bindings: context.keybindings)
            vc.onChange = context.onChangeKeybindings
            return vc
        }
    }
}
