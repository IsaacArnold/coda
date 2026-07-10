import AppKit
import CodaCore

/// The Settings window content: a toolbar-style tab view with General (editor picker) and
/// Keyboard Shortcuts panes.
final class SettingsTabController: NSTabViewController {
    init(editor: Editor,
         onChangeEditor: @escaping (Editor) -> Void,
         keybindings: Keybindings,
         onChange: @escaping (Keybindings) -> Void,
         themeNames: [String],
         activeTheme: String?,
         onApplyTheme: @escaping (String) -> Void,
         onImportTheme: @escaping (URL) -> Void,
         terminalFont: NSFont,
         onChangeFont: @escaping (TerminalFontPref) -> Void,
         uiScale: UIScale,
         onChangeUIScale: @escaping (UIScale) -> Void,
         notifyOnNeedsYou: Bool,
         onChangeNotifyOnNeedsYou: @escaping (Bool) -> Void,
         notifyOnDone: Bool,
         onChangeNotifyOnDone: @escaping (Bool) -> Void,
         showDockBadge: Bool,
         onChangeShowDockBadge: @escaping (Bool) -> Void,
         shell: ShellChoice,
         onChangeShell: @escaping (ShellChoice) -> Void,
         completionsEnabled: Bool,
         onChangeCompletionsEnabled: @escaping (Bool) -> Void,
         accentColor: String,
         onChangeAccentColor: @escaping (String) -> Void,
         appIconName: String?,
         onChangeAppIcon: @escaping (String) -> Void) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar

        let general = GeneralSettingsViewController(editor: editor, terminalFont: terminalFont, uiScale: uiScale,
                                                    notifyOnNeedsYou: notifyOnNeedsYou, notifyOnDone: notifyOnDone,
                                                    showDockBadge: showDockBadge,
                                                    shell: shell, completionsEnabled: completionsEnabled,
                                                    accentColor: accentColor, appIconName: appIconName)
        general.onChangeEditor = onChangeEditor
        general.onChangeFont = onChangeFont
        general.onChangeUIScale = onChangeUIScale
        general.onChangeNotifyOnNeedsYou = onChangeNotifyOnNeedsYou
        general.onChangeNotifyOnDone = onChangeNotifyOnDone
        general.onChangeShowDockBadge = onChangeShowDockBadge
        general.onChangeShell = onChangeShell
        general.onChangeCompletionsEnabled = onChangeCompletionsEnabled
        general.onChangeAccentColor = onChangeAccentColor
        general.onChangeAppIcon = onChangeAppIcon
        let generalItem = NSTabViewItem(viewController: general)
        generalItem.label = "General"
        generalItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")
        addTabViewItem(generalItem)

        let themes = ThemeSettingsViewController(themeNames: themeNames, active: activeTheme,
                                                 onApply: onApplyTheme, onImport: onImportTheme)
        let themesItem = NSTabViewItem(viewController: themes)
        themesItem.label = "Themes"
        themesItem.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "Themes")
        addTabViewItem(themesItem)

        let keys = KeybindingsViewController(bindings: keybindings)
        keys.onChange = onChange
        let keysItem = NSTabViewItem(viewController: keys)
        keysItem.label = "Keyboard Shortcuts"
        keysItem.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keyboard Shortcuts")
        addTabViewItem(keysItem)

        // A consistent default window size across panes (NSTabViewController sizes the window
        // to the selected pane). Tunable.
        for vc in [general, themes, keys] as [NSViewController] {
            vc.preferredContentSize = NSSize(width: 620, height: 520)
        }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Keep the window titled "Settings" regardless of the selected tab — a toolbar-style
    /// NSTabViewController otherwise sets the window title to the active tab's label.
    override var title: String? {
        get { "Settings" }
        set { }
    }
}
