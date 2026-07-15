import Foundation

/// The categories shown in the Settings sidebar. Pure data (no AppKit) so it can be
/// unit-tested; the mapping to each category's AppKit pane view controller lives in the
/// Coda UI layer. Sidebar order == `allCases` order.
public enum SettingsCategory: String, CaseIterable, Sendable {
    case general
    case appearance
    case terminal
    case notifications
    case shortcuts

    /// The sidebar row label.
    public var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .terminal: return "Terminal"
        case .notifications: return "Notifications"
        case .shortcuts: return "Shortcuts"
        }
    }

    /// SF Symbol name for the sidebar row icon.
    public var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .terminal: return "terminal"
        case .notifications: return "bell"
        case .shortcuts: return "keyboard"
        }
    }
}
