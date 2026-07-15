// Sources/Coda/SettingsContext.swift
import AppKit
import CodaCore

/// All values + change callbacks the Settings panes need, bundled so panes and the split
/// controller take a single parameter instead of 20+. AppDelegate builds one of these; each
/// pane reads only the fields it uses. This replaces SettingsTabController's giant init.
struct SettingsContext {
    // General
    let editor: Editor
    let onChangeEditor: (Editor) -> Void
    let uiScale: UIScale
    let onChangeUIScale: (UIScale) -> Void
    let appIconName: String?
    let onChangeAppIcon: (String) -> Void

    // Appearance
    let themeNames: [String]
    let activeThemeName: String?
    let onApplyTheme: (String) -> Void
    let onImportTheme: (URL) -> Void
    let accentValue: String            // serialized IdentityColorValue
    let accentTheme: TerminalTheme     // paints the hue swatches
    let onChangeAccentColor: (String) -> Void

    // Terminal
    let terminalFont: NSFont
    let onChangeFont: (TerminalFontPref) -> Void
    let shell: ShellChoice
    let onChangeShell: (ShellChoice) -> Void
    let completionsEnabled: Bool
    let onChangeCompletionsEnabled: (Bool) -> Void

    // Notifications
    let notifyOnNeedsYou: Bool
    let onChangeNotifyOnNeedsYou: (Bool) -> Void
    let notifyOnDone: Bool
    let onChangeNotifyOnDone: (Bool) -> Void
    let showDockBadge: Bool
    let onChangeShowDockBadge: (Bool) -> Void

    // Shortcuts
    let keybindings: Keybindings
    let onChangeKeybindings: (Keybindings) -> Void
}
