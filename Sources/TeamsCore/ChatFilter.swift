/// Notify/skip decision. Pure; every branch covered by tests.
///
/// - Muted: everything skipped (reason "muted"). System/sign-in-needed
///   notifications bypass this filter entirely (posted directly).
/// - Own messages: skipped (when skipOwnMessages).
/// - Non-text types (Control/Typing, ThreadActivity, ...): skipped unless
///   listed in notifyTypes.
/// - Edits (MessageUpdate): skipped unless notifyOnEdit.
/// - Chats whose display name contains loudSubstring (case-insensitive):
///   notify ONLY on owner mention (MRI preferred, display-name fallback) or
///   channel/Everyone mention.
/// - All other chats: notify.
public enum ChatFilter {
    public enum Decision: Sendable, Equatable {
        case notify(reason: String)
        case skip(reason: String)
    }

    /// Skip reason used for the mute gate. App logs "muted, suppressed"
    /// on this reason (spec string).
    public static let mutedReason = "muted"

    public static func decide(
        message: EventMessage.Message,
        isEdit: Bool,
        chatDisplayName: String,
        ownerMRI: String?,
        config: Config
    ) -> Decision {
        // Mute gate first: suppresses all message notifications.
        if config.muted {
            return .skip(reason: mutedReason)
        }
        // Own message?
        if config.skipOwnMessages, isOwnMessage(message, ownerMRI: ownerMRI, ownerDisplayName: config.owner.displayName) {
            return .skip(reason: "own-message")
        }
        // Type gate on first messagetype segment (Text, RichText, Control, ...).
        let head = message.messageType.split(separator: "/").first.map(String.init) ?? message.messageType
        if !config.notifyTypes.contains(where: { $0.caseInsensitiveCompare(head) == .orderedSame }) {
            return .skip(reason: "type:\(head)")
        }
        // Edits.
        if isEdit, !config.notifyOnEdit {
            return .skip(reason: "edit")
        }
        // Loud chat rule.
        if isLoudChat(chatDisplayName, substring: config.loudSubstring) {
            if Mentions.mentionsOwner(message.mentions, ownerMRI: ownerMRI, ownerDisplayName: config.owner.displayName) {
                return .notify(reason: "loud-owner-mention")
            }
            if Mentions.mentionsChannelOrEveryone(message.mentions) {
                return .notify(reason: "loud-channel-mention")
            }
            return .skip(reason: "loud-no-mention")
        }
        return .notify(reason: "chat-message")
    }

    static func isOwnMessage(_ m: EventMessage.Message, ownerMRI: String?, ownerDisplayName: String) -> Bool {
        if let ownerMRI, !ownerMRI.isEmpty, let sender = m.senderMRI, !sender.isEmpty {
            return sender.caseInsensitiveCompare(ownerMRI) == .orderedSame
        }
        // MRI unknown: fall back to sender display-name match. Empty names
        // never match (avoid muting everything when unconfigured).
        let a = m.senderName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let b = ownerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !a.isEmpty && a == b
    }

    static func isLoudChat(_ name: String, substring: String) -> Bool {
        guard !substring.isEmpty else { return false }
        return name.range(of: substring, options: .caseInsensitive) != nil
    }
}
