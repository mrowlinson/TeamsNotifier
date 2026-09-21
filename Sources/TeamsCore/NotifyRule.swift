import Foundation

/// One notify/skip rule: the extensible store behind ChatFilter's gates.
///
/// - `kind`: rule type id. Known ids are plain-language phrases (see
///   `knownKinds`); anything else is a future/custom type: stored,
///   GUI-editable, round-tripped, but not enforced (first match per kind
///   wins; unknown kinds are ignored by the filter). The four pre-rename
///   ids (`skip-own`, `allow-types`, `skip-edits`, `loud-chat`) still
///   decode: they map to their replacements on load (see `legacyKinds`).
/// - `value`: payload. only-these-message-types = comma-separated type
///   heads ("Text, RichText"); noisy-chats-mention-only = chat-name text;
///   the rest ignore it.
/// - `enabled`: per-rule on/off switch. A disabled (or absent) known
///   rule switches its gate off: own messages and edits notify, the
///   noisy rule stops matching, message-types allows every type (stored
///   in the legacy scalar as `allowAllMarker`), noisy channel mentions
///   stop notifying, name matching goes IDs-only.
///
/// Config migrates legacy scalars to these rules on first load of a
/// pre-rules file (existing installs keep their exact effective
/// behavior) and syncs the scalars back from the stored rules whenever
/// the rules key is present. Fresh installs keep a BLANK list.
public struct NotifyRule: Codable, Sendable, Equatable {
    public var kind: String
    public var value: String
    public var enabled: Bool

    public init(kind: String, value: String = "", enabled: Bool = true) {
        self.kind = kind
        self.value = value
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case kind, value, enabled
    }

    /// Tolerant decode: every key falls back (missing `enabled` means on,
    /// like MuteWindow). A rule with no kind decodes as kind "" and is
    /// dropped with a warning by normalizeRules(). Pre-rename kind ids
    /// map to their replacements here, so stored old configs load with
    /// identical behavior and re-save with new ids.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        kind = NotifyRule.canonicalKind(rawKind)
        value = (try? c.decodeIfPresent(String.self, forKey: .value)) ?? ""
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
    }

    // MARK: kinds

    /// Skip messages sent by the owner. Value ignored.
    public static let skipMyMessages = "skip-my-own-messages"
    /// Message-type heads that notify (value = CSV). Absent/disabled =
    /// every type notifies.
    public static let messageTypes = "only-these-message-types"
    /// Skip MessageUpdate edits. Value ignored. (Enabled = skip, so the
    /// stock off state "notify on edit: no" migrates as enabled.)
    public static let skipEdited = "skip-edited-messages"
    /// Chats whose name contains the value notify only on owner or
    /// channel/Everyone mention.
    public static let noisyChats = "noisy-chats-mention-only"
    /// In noisy chats, channel/@team/@everyone mentions also notify.
    /// Absent/disabled = only direct owner mentions notify there. Value
    /// ignored.
    public static let noisyChannel = "noisy-chats-channel-mentions"
    /// When Teams omits sender/mention IDs, fall back to comparing the
    /// owner's display name. Absent/disabled = IDs only. Value ignored.
    public static let nameBackup = "my-name-as-backup"

    /// Known ids, in migration order. The set is open: the GUI kind field
    /// accepts anything, and unknown ids round-trip untouched.
    public static let knownKinds = [skipMyMessages, messageTypes, skipEdited, noisyChats, noisyChannel, nameBackup]

    /// Pre-rename ids -> replacements. Applied on decode (and to GUI
    /// input), so old stored configs keep working unchanged.
    public static let legacyKinds = [
        "skip-own": skipMyMessages,
        "allow-types": messageTypes,
        "skip-edits": skipEdited,
        "loud-chat": noisyChats,
    ]

    /// Map a pre-rename id to its replacement; anything else passes
    /// through untouched (unknown/custom kinds included).
    public static func canonicalKind(_ kind: String) -> String {
        legacyKinds[kind] ?? kind
    }

    /// notifyTypes value meaning "every type notifies". Written by the
    /// rules sync when the message-types rule is absent/disabled; honored
    /// by ChatFilter's type gate. Never appears in legacy files.
    public static let allowAllMarker = "*"

    /// Editor hint per kind; unknown kinds get the generic line. Legacy
    /// ids resolve to their replacement's hint.
    public static func hint(for kind: String) -> String {
        switch canonicalKind(kind) {
        case skipMyMessages: "On: skip messages you sent. Value ignored."
        case messageTypes: "Value: message types that notify, e.g. Text, RichText. Off: every type notifies (typing, member notices, calls too)."
        case skipEdited: "On: skip edited messages. Off: edits notify. Value ignored."
        case noisyChats: "Value: chat-name text, e.g. BTAC. Matching chats notify only when you are mentioned."
        case noisyChannel: "On: @channel/@team/@everyone also notify in noisy chats. Off: only your direct mentions do. Value ignored."
        case nameBackup: "On: when Teams omits sender/mention IDs, match by your display name. Off: IDs only. Value ignored."
        default: "Custom type: stored and round-tripped, not enforced yet."
        }
    }

    /// Plain-language label for the value field per kind.
    public static func valueLabel(for kind: String) -> String {
        switch canonicalKind(kind) {
        case messageTypes: "Types:"
        case noisyChats: "Chat text:"
        default: "Value:"
        }
    }

    /// Example text for the value field per kind.
    public static func valuePlaceholder(for kind: String) -> String {
        switch canonicalKind(kind) {
        case messageTypes: "Text, RichText"
        case noisyChats: "BTAC"
        default: "(ignored)"
        }
    }

    /// Whether the kind reads its value (the value field disables
    /// otherwise).
    public static func usesValue(_ kind: String) -> Bool {
        switch canonicalKind(kind) {
        case messageTypes, noisyChats: true
        default: false
        }
    }

    // MARK: validation + parsing

    /// Nil when valid, else a human-readable reason. Unknown kinds are
    /// always valid (extensible payload); known kinds needing a value
    /// must have a non-blank one. Legacy ids validate as their
    /// replacement (tolerant: decode already canonicalizes).
    public func issue() -> String? {
        let k = NotifyRule.canonicalKind(kind.trimmingCharacters(in: .whitespacesAndNewlines))
        if k.isEmpty { return "rule has no type" }
        switch k {
        case NotifyRule.messageTypes where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return "only-these-message-types rule needs a value (e.g. Text, RichText)"
        case NotifyRule.noisyChats where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return "noisy-chats-mention-only rule needs chat-name text (e.g. BTAC)"
        default:
            return nil
        }
    }

    public var isValid: Bool { issue() == nil }

    /// "Text, RichText" -> ["Text", "RichText"]. Trims pieces, drops
    /// empties ("a,,b" -> ["a","b"]).
    public static func parseTypes(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    // MARK: migration

    /// Legacy scalars -> the stock rules. Empty inputs mean "legacy
    /// fill" (mirrors Config.load: blank loud = BTAC, blank types =
    /// Text/RichText), so migrated rules encode the exact effective
    /// legacy behavior. Always returns all six kinds, in knownKinds
    /// order; `notifyOnEdit` maps to inverted skip-edited-messages. The
    /// two boolean-only gates (noisy channel mentions, name backup) had
    /// no legacy scalar: they migrate enabled, matching the hardcoded
    /// behavior every install already had.
    public static func migrate(skipOwn: Bool, notifyOnEdit: Bool, types: [String], loud: String) -> [NotifyRule] {
        let effLoud = loud.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "BTAC" : loud
        let effTypes = types.isEmpty ? ["Text", "RichText"] : types
        return [
            NotifyRule(kind: NotifyRule.skipMyMessages, enabled: skipOwn),
            NotifyRule(kind: NotifyRule.messageTypes, value: effTypes.joined(separator: ", "), enabled: true),
            NotifyRule(kind: NotifyRule.skipEdited, enabled: !notifyOnEdit),
            NotifyRule(kind: NotifyRule.noisyChats, value: effLoud, enabled: true),
            NotifyRule(kind: NotifyRule.noisyChannel, enabled: true),
            NotifyRule(kind: NotifyRule.nameBackup, enabled: true),
        ]
    }
}
