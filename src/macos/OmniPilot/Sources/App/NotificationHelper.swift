import Foundation
import UserNotifications

/// Handles macOS notifications for OmniPilot
final class NotificationHelper: Sendable {
    static let shared = NotificationHelper()

    private init() {
        requestPermission()
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("[Notify] Notification permission granted")
            } else if let error = error {
                print("[Notify] Permission error: \(error)")
            }
        }
    }

    /// Send a notification
    func send(title: String, body: String, identifier: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(200))
        content.sound = .default

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[Notify] Send error: \(error)")
            }
        }
    }

    /// Send daily summary notification
    func sendDailySummary(_ summary: String) {
        send(
            title: "OmniPilot — Daily Summary",
            body: summary,
            identifier: "daily-summary-\(Date().timeIntervalSince1970)"
        )
    }

    /// Send memory milestone notification
    func sendMilestone(count: Int) {
        let milestones = [10, 50, 100, 500, 1000]
        if milestones.contains(count) {
            send(
                title: "OmniPilot — Milestone!",
                body: "You've stored \(count) memories. Your AI companion is getting smarter.",
                identifier: "milestone-\(count)"
            )
        }
    }
}
