import AppKit
import Foundation
import TeamsCore
import UserNotifications

/// Native notifications. Title = "sender in chat" (or sender when the chat
/// has no better name). Body = full message text. Sound on. Click = copy
/// body to clipboard. Message notifications carry two actions: Reply
/// (text-input, posts to the thread via TeamsAPI.sendReply) and Open chat
/// (foregrounds the per-chat conversation window for the thread).
/// Sticky banners: owner sets Alerts style in System Settings > Notifications.
public final class Notifier: NSObject, @unchecked Sendable {
    public static let shared = Notifier()

    private let center = UNUserNotificationCenter.current()

    /// Reply sender, wired by App (needs TeamsAPI). Result failure text is
    /// the loud-failure reason.
    public var onReply: (@Sendable (String, String) async -> Result<Void, Error>)?

    /// Open-chat handler, wired by App (needs TeamsAPI + chat title).
    public var onOpenChat: (@Sendable (String) async -> Void)?

    private override init() {
        super.init()
    }

    public func setup() {
        center.delegate = self
        // Reply affordance: text-input action, minimal options (no
        // .foreground/.destructive/.authenticationRequired — any of those
        // hides or degrades the button). Explicit placeholder: the SDK
        // default is empty, which leaves the expanded field unlabeled.
        let reply = UNTextInputNotificationAction(
            identifier: ReplyInfo.replyActionID,
            title: ReplyInfo.actionTitle,
            options: [],
            textInputButtonTitle: ReplyInfo.sendButtonTitle,
            textInputPlaceholder: ReplyInfo.textInputPlaceholder)
        // Open chat: foregrounds the app so the conversation window
        // appears above the owner's work (menu-bar accessory otherwise
        // stays behind).
        let open = UNNotificationAction(
            identifier: ReplyInfo.openActionID,
            title: ReplyInfo.openActionTitle,
            options: [.foreground])
        let message = UNNotificationCategory(
            identifier: ReplyInfo.categoryID, actions: [reply, open],
            intentIdentifiers: [], options: [])
        center.setNotificationCategories([message])
    }

    public func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            Log.fault("notification auth failed: \(error)")
            return false
        }
    }

    public func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Full per-setting state (alert/sound/badge + style). Authorization can
    /// read authorized while the app is switched off in Settings.
    public func settings() async -> UNNotificationSettings {
        await center.notificationSettings()
    }

    /// chatID attaches the Reply action + thread id (message notifications).
    /// Nil (system/test notifs) posts a plain notification with no action.
    public func post(title: String, body: String, id: String? = nil, chatID: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body.isEmpty ? "(no text content)" : body
        content.sound = .default
        if let chatID, !chatID.isEmpty {
            content.categoryIdentifier = ReplyInfo.categoryID
            content.userInfo = ReplyInfo.userInfo(chatID: chatID)
        }
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
        // Reply action: POST the text to the thread. Silent on success
        // (debug log), loud system notification on failure. Never copies.
        if response.actionIdentifier == ReplyInfo.replyActionID,
           let textResponse = response as? UNTextInputNotificationResponse
        {
            await handleReply(textResponse)
            return
        }
        // Open-chat action: show (or focus) the per-chat window. Never copies.
        if response.actionIdentifier == ReplyInfo.openActionID {
            let info = response.notification.request.content.userInfo
            if let chatID = ReplyInfo.chatID(from: info) {
                await onOpenChat?(chatID)
            } else {
                Log.debug("open-chat ignored (empty thread)")
            }
            return
        }
        // Any other click/dismiss-with-action copies the body (unchanged).
        let body = response.notification.request.content.body
        guard !body.isEmpty else { return }
        await MainActor.run {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(body, forType: .string)
        }
        Log.info("notification body copied to clipboard")
    }

    private func handleReply(_ response: UNTextInputNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let chatID = ReplyInfo.chatID(from: info),
              ReplyGate.canReply(chatID: chatID, text: response.userText)
        else {
            Log.debug("reply ignored (empty thread or text)")
            return
        }
        let text = response.userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let onReply else {
            Log.fault("reply dropped: no handler wired")
            return
        }
        switch await onReply(chatID, text) {
        case .success:
            Log.debug("replied to \(chatID)")
        case .failure(let err):
            postSystem(title: "TeamsNotifier: reply failed", body: "Reply failed: \(TeamsAPI.reason(for: err))")
        }
    }

    // Show banners even while the app is frontmost (we never are, but be safe).
    // .list keeps the foreground copy in Notification Center too, where the
    // Reply button sits expanded. No API forces always-visible buttons;
    // hover (banner/alert) + expanded NC is the macOS ceiling.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
