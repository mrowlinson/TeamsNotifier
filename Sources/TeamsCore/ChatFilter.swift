/// Notify/skip decision. Pure; every branch covered by tests.
///
/// - Muted: everything skipped (reason "muted"). System/sign-in-needed
///   notifications bypass this filter entirely (posted directly).
///   The app sets `config.muted` per message to the effective value
///   (schedule + memory-only manual override) before calling decide.
/// - Keyword block: a block word in the message plain text forces SKIP
///   (reason "keyword-block"), through any filter notify. Checked first
///   after mute, so it beats the keyword allow below.
/// - Keyword allow: an allow word in the message plain text forces
///   NOTIFY (reason "keyword-allow"), through any filter skip (own,
///   type, edit, noisy). Both keyword gates yield to mute.
/// - Keyword match: case-insensitive SUBSTRING against
///   `message.plainText` (HTML stripped, entities decoded), any chat,
///   any message type carrying text. Opposing hits: BLOCK wins.
/// - Own messages: skipped (when skipOwnMessages). Sender match is MRI
///   preferred with a display-name backup (when matchByDisplayName).
/// - Non-text types (Control/Typing, ThreadActivity, ...): skipped unless
///   listed in notifyTypes. A "*" entry (written when the
///   only-these-message-types rule is absent/disabled) allows every type.
/// - Edits (MessageUpdate): skipped unless notifyOnEdit.
/// - Noisy chats (display name contains loudSubstring, case-insensitive):
///   notify ONLY on owner mention (MRI preferred, display-name backup
///   when matchByDisplayName) or — when noisyChannelMentions —
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
        // Keyword gates: block beats allow; both beat every other gate.
        let text = message.plainText
        if containsKeyword(text, config.blockKeywords) {
            return .skip(reason: "keyword-block")
        }
        if containsKeyword(text, config.allowKeywords) {
            return .notify(reason: "keyword-allow")
        }
        // Own message?
        if config.skipOwnMessages, isOwnMessage(message, ownerMRI: ownerMRI, ownerDisplayName: config.owner.displayName, matchByName: config.matchByDisplayName) {
            return .skip(reason: "own-message")
        }
        // Type gate on first messagetype segment (Text, RichText, Control, ...).
        let head = message.messageType.split(separator: "/").first.map(String.init) ?? message.messageType
        if !config.notifyTypes.contains(NotifyRule.allowAllMarker),
           !config.notifyTypes.contains(where: { $0.caseInsensitiveCompare(head) == .orderedSame })
        {
            return .skip(reason: "type:\(head)")
        }
        // Edits.
        if isEdit, !config.notifyOnEdit {
            return .skip(reason: "edit")
        }
        // Noisy-chat rule.
        if isLoudChat(chatDisplayName, substring: config.loudSubstring) {
            if Mentions.mentionsOwner(message.mentions, ownerMRI: ownerMRI, ownerDisplayName: config.owner.displayName, matchByName: config.matchByDisplayName) {
                return .notify(reason: "loud-owner-mention")
            }
            if config.noisyChannelMentions, Mentions.mentionsChannelOrEveryone(message.mentions) {
                return .notify(reason: "loud-channel-mention")
            }
            return .skip(reason: "loud-no-mention")
        }
        return .notify(reason: "chat-message")
    }

    static func isOwnMessage(_ m: EventMessage.Message, ownerMRI: String?, ownerDisplayName: String, matchByName: Bool = true) -> Bool {
        if let ownerMRI, !ownerMRI.isEmpty, let sender = m.senderMRI, !sender.isEmpty {
            return sender.caseInsensitiveCompare(ownerMRI) == .orderedSame
        }
        // MRI unknown: fall back to sender display-name match (unless the
        // name-backup gate is off: IDs only). Empty names never match
        // (avoid muting everything when unconfigured).
        guard matchByName else { return false }
        let a = m.senderName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let b = ownerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !a.isEmpty && a == b
    }

    static func isLoudChat(_ name: String, substring: String) -> Bool {
        guard !substring.isEmpty else { return false }
        return name.range(of: substring, options: .caseInsensitive) != nil
    }

    /// Any keyword found as a case-insensitive substring of the text?
    /// Empty lists never hit; blank keywords are skipped (parse drops
    /// them, but in-memory configs may carry them).
    static func containsKeyword(_ text: String, _ keywords: [String]) -> Bool {
        guard !keywords.isEmpty, !text.isEmpty else { return false }
        return keywords.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && text.range(of: $0, options: .caseInsensitive) != nil
        }
    }
}
