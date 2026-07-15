// Sources/Coda/NotificationsPaneViewController.swift
import AppKit
import CodaCore

/// Settings → Notifications. Three independent opt-in toggles, each with a grey subtitle.
/// Edits report via the context's callbacks; AppDelegate persists.
final class NotificationsPaneViewController: NSViewController {
    private let context: SettingsContext
    private let needsYouSwitch = NSSwitch()
    private let doneSwitch = NSSwitch()
    private let dockBadgeSwitch = NSSwitch()

    init(context: SettingsContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        needsYouSwitch.state = context.notifyOnNeedsYou ? .on : .off
        needsYouSwitch.target = self
        needsYouSwitch.action = #selector(needsYouChanged)

        doneSwitch.state = context.notifyOnDone ? .on : .off
        doneSwitch.target = self
        doneSwitch.action = #selector(doneChanged)

        dockBadgeSwitch.state = context.showDockBadge ? .on : .off
        dockBadgeSwitch.target = self
        dockBadgeSwitch.action = #selector(dockBadgeChanged)

        let card = SettingsCard(rows: [
            SettingsRow.make(title: "Notify when an agent needs you",
                             subtitle: "Alerts you when an agent is waiting for your input.",
                             control: needsYouSwitch),
            SettingsRow.make(title: "Notify when an agent finishes",
                             subtitle: "Alerts you when an agent completes its turn.",
                             control: doneSwitch),
            SettingsRow.make(title: "Show a Dock badge when agents need you",
                             subtitle: "Shows a count on the Dock icon for agents awaiting you.",
                             control: dockBadgeSwitch),
        ])
        view = SettingsPane.makeScrollView(title: "Notifications", cards: [card])
    }

    @objc private func needsYouChanged() {
        context.onChangeNotifyOnNeedsYou(needsYouSwitch.state == .on)
    }
    @objc private func doneChanged() {
        context.onChangeNotifyOnDone(doneSwitch.state == .on)
    }
    @objc private func dockBadgeChanged() {
        context.onChangeShowDockBadge(dockBadgeSwitch.state == .on)
    }
}
