import Foundation
import UserNotifications

/// Thin wrapper around UNUserNotificationCenter that degrades quietly.
///
/// Notifications are best-effort: an ad-hoc signed app can be refused authorization, and
/// that must never take the recording down with it. The menu bar icon is the indicator
/// that always works.
enum Notifier {
    private static var authorized = false

    static func requestAuthorization() async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        do {
            authorized = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            authorized = false
        }
    }

    static func post(title: String, body: String) {
        guard authorized, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
