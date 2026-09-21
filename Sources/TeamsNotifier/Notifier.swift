import AppKit
import Foundation
import UserNotifications

/// Native notifications. Title = "sender in chat" (or sender when the chat
/// has no better name). Body = full message text. Sound on. Click = copy
/// body to clipboard (no GUI to open).
/// Sticky banners: owner sets Alerts style in System Settings > Notifications.
public final class Notifier: NSObject, @unchecked Sendable {
    public static let shared = Notifier()

    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
    }

    public func setup() {
        center.delegate = self
    }

    public func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            Log.fault("notification auth failed: \(error)")
            return false
        }
    }

    public func post(title: String, body: String, id: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body.isEmpty ? "(no text content)" : body
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: id ?? UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(req) { err in
            if let err { Log.fault("notification post failed: \(err)") }
        }
    }

    public func postSystem(title: String, body: String) {
        post(title: title, body: body, id: "system-\(title)")
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Any click/dismiss-with-action on a message notification copies it.
        let body = response.notification.request.content.body
        guard !body.isEmpty else { return }
        await MainActor.run {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(body, forType: .string)
        }
        Log.info("notification body copied to clipboard")
    }

    // Show banners even while the app is frontmost (we never are, but be safe).
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
