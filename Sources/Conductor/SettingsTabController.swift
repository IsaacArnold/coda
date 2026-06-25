import AppKit
import ConductorCore

/// The Settings window content: a toolbar-style tab view with General (editor picker) and
/// Keyboard Shortcuts panes.
final class SettingsTabController: NSTabViewController {
    init(editor: Editor,
         onChangeEditor: @escaping (Editor) -> Void,
         keybindings: Keybindings,
         onChange: @escaping (Keybindings) -> Void) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar

        let general = GeneralSettingsViewController(editor: editor)
        general.onChangeEditor = onChangeEditor
        let generalItem = NSTabViewItem(viewController: general)
        generalItem.label = "General"
        generalItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")
        addTabViewItem(generalItem)

        let keys = KeybindingsViewController(bindings: keybindings)
        keys.onChange = onChange
        let keysItem = NSTabViewItem(viewController: keys)
        keysItem.label = "Keyboard Shortcuts"
        keysItem.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keyboard Shortcuts")
        addTabViewItem(keysItem)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}
