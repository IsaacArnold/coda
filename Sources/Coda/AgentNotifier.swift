import AppKit
import UserNotifications
import CodaCore

/// Posts opt-in macOS notifications when an agent needs input or finishes a turn.
///
/// Security §1: the notification body is UNTRUSTED (it reflects repo files and web content
/// the agent read). It is passed to `UNMutableNotificationContent.body` ONLY, as plain data —
/// never interpolated into an `osascript`/shell/AppleScript string. `UNUserNotificationCenter`
/// is the sole delivery mechanism here.
enum AgentNotifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// title = worktree display name, body = the agent's last message (plain text data field).
    static func notify(worktreeID: String, title: String, state: AgentState, body: String?) {
        // No app bundle (e.g. `swift run`/`swift test`) → `UNUserNotificationCenter.current()`
        // throws NSInternalInconsistencyException. Skip delivery rather than crash a dev run.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body ?? (state == .needsYou ? "Needs your input" : "Finished")
        content.sound = .default
        content.userInfo = ["worktreeID": worktreeID]   // for click-to-focus
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
