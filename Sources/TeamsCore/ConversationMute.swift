import Foundation

/// Per-chat Teams mute state, read from the chat-service conversation object.
///
/// SOURCE: `properties.alerts` on the conversation resource. Live probe
/// (2026-09-22, `GET /v1/users/ME/conversations`, 99 chats): chat/meeting
/// threads carry `alerts` as the string "true"/"false" (or omit it);
/// streams, channels, teams, notes omit it. alerts="false" marks exactly
/// the chats muted in the Teams client. The single-conversation GET (the
/// existing per-chat name fetch) carries the same `properties` shape, so
/// the name fetch doubles as the mute source with zero extra requests.
/// `hidden` is unrelated (hide, not mute).
///
/// Fail-open: only an explicit false mutes. Absent, "true", or any
/// unrecognized shape notifies (current behavior).
public enum ConversationMute {
    /// True when the conversation object says alerts are off.
    public static func isMuted(_ conversation: [String: Any]) -> Bool {
        guard let props = conversation["properties"] as? [String: Any],
              let raw = props["alerts"]
        else { return false }
        if let s = raw as? String {
            return s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "false"
        }
        if let b = raw as? Bool { return !b }
        if let n = raw as? NSNumber { return n.intValue == 0 }
        return false
    }
}
