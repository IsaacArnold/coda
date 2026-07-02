import AppKit
import CodaCore

/// Turns a `UIScale` preset into scaled AppKit fonts and geometry lengths for the app
/// chrome (sidebar, tab bar, worktree bar). One value; chrome views hold a copy and read
/// from it when they (re)build. The terminal font is NOT routed through here — it keeps
/// its own explicit point size from `TerminalFontPref`.
struct UIMetrics {
    let scale: UIScale

    init(scale: UIScale) { self.scale = scale }

    /// Scale a base geometry length (row/bar height, inset) to the nearest whole point.
    func length(_ base: CGFloat) -> CGFloat { CGFloat(scale.scaled(Double(base))) }

    private func size(_ base: CGFloat) -> CGFloat { CGFloat(scale.scaled(Double(base))) }

    /// Sidebar repo section header.
    var sectionHeader: NSFont { .systemFont(ofSize: size(NSFont.smallSystemFontSize), weight: .semibold) }

    /// Sidebar worktree title / settings body labels.
    var body: NSFont { .systemFont(ofSize: size(NSFont.systemFontSize)) }

    /// Sidebar worktree subtitle (branch).
    var footnote: NSFont {
        .systemFont(ofSize: size(NSFont.preferredFont(forTextStyle: .footnote).pointSize))
    }

    /// Surface tab label; the active tab is semibold.
    func tabLabel(active: Bool) -> NSFont { .systemFont(ofSize: size(11), weight: active ? .semibold : .regular) }

    /// Worktree identity-bar title.
    var worktreeTitle: NSFont { .systemFont(ofSize: size(12), weight: .semibold) }

    /// Worktree identity-bar branch (monospaced).
    var worktreeBranch: NSFont { .monospacedSystemFont(ofSize: size(11), weight: .regular) }
}
