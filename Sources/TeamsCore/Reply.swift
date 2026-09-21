import Foundation

/// Inline notification replies: send path + notification plumbing.
/// Provenance (all agree on endpoint, auth, body):
/// - eisbaw/ost src/api/chat.rs send_message_with_client (POST body) +
///   src/api/client.rs chat_post (Authentication header)
/// - EionRobb/purple-teams teams_send_message (teams_messages.c) +
///   teams_post_or_get (teams_connection.c)
/// - roshank8s/teams-api send_message / send_reply
///
/// POST {chatServiceBase}/v1/users/ME/conversations/{chatID}/messages,
/// header `Authentication: skypetoken=...`, JSON body below. Same skype
/// token + same base as chat REST: no new auth, zero idle cost (one HTTPS
/// POST per reply). Channels use the same endpoint (no channel-specific
/// send in any ref; thread id from the trouter event is the conversation).
public enum ReplyPayload {
    public static let messageType = "RichText/Html"
    public static let contentType = "text"

    /// HTML-escape for embedding in RichText/Html content (ost html_escape).
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Millis-since-epoch id (purple-teams js_time; teams-api client_msg_id).
    public static func clientMessageID(now: Date = Date()) -> String {
        String(Int64(now.timeIntervalSince1970 * 1000))
    }

    /// ost 3-field body + purple-teams/teams-api clientmessageid. Newlines
    /// become <br/> so pasted multi-line replies render.
    public static func build(text: String, clientMessageID: String) -> [String: String] {
        let escaped = escape(text).replacingOccurrences(of: "\n", with: "<br/>")
        return [
            "content": "<p>\(escaped)</p>",
            "messagetype": messageType,
            "contenttype": contentType,
            "clientmessageid": clientMessageID,
        ]
    }

    public static func url(chatServiceBase: String, chatID: String) -> URL? {
        let encoded = chatID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? chatID
        return URL(string: "\(chatServiceBase)/v1/users/ME/conversations/\(encoded)/messages")
    }
}

/// Notification category/action/userInfo for the Reply button. userInfo
/// carries the thread id so the action handler knows where to POST.
public enum ReplyInfo {
    public static let categoryID = "TN_MESSAGE"
    public static let replyActionID = "TN_REPLY"
    public static let chatIDKey = "TNChatID"

    public static func userInfo(chatID: String) -> [String: String] {
        [chatIDKey: chatID]
    }

    public static func chatID(from userInfo: [AnyHashable: Any]) -> String? {
        guard let id = userInfo[chatIDKey] as? String, !id.isEmpty else { return nil }
        return id
    }
}

/// Reply gating. Mute gates INBOUND only: replies are always allowed while
/// muted (by design — no muted input), so an older still-visible banner
/// stays answerable.
public enum ReplyGate {
    public static func canReply(chatID: String, text: String) -> Bool {
        !chatID.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
