import Foundation

/// One notify/skip rule: the extensible store behind ChatFilter's gates.
///
/// - `kind`: rule type id. Known ids are `skip-own`, `allow-types`,
///   `skip-edits`, `loud-chat`; anything else is a future/custom type:
///   stored, GUI-editable, round-tripped, but not enforced (first match
///   per kind wins; unknown kinds are ignored by the filter).
/// - `value`: payload. allow-types = comma-separated type heads
///   ("Text, RichText"); loud-chat = chat-name substring; skip-own and
///   skip-edits ignore it.
/// - `enabled`: per-rule on/off switch. A disabled (or absent) known
///   rule switches its gate off: own messages and edits notify, the
///   loud rule stops matching, allow-types allows every type (stored
///   in the legacy scalar as `allowAllMarker`).
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
    /// dropped with a warning by normalizeRules().
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        value = (try? c.decodeIfPresent(String.self, forKey: .value)) ?? ""
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
    }

    // MARK: kinds

    /// Skip messages sent by the owner. Value ignored.
    public static let skipOwn = "skip-own"
    /// Message-type heads that notify (value = CSV). Absent/disabled =
    /// every type notifies.
    public static let allowTypes = "allow-types"
    /// Skip MessageUpdate edits. Value ignored. (Enabled = skip, so the
    /// stock off state "notify on edit: no" migrates as enabled.)
    public static let skipEdits = "skip-edits"
    /// Chats whose name contains the value notify only on owner or
    /// channel/Everyone mention.
    public static let loudChat = "loud-chat"

    /// Known ids, in migration order. The set is open: the GUI kind field
    /// accepts anything, and unknown ids round-trip untouched.
    public static let knownKinds = [skipOwn, allowTypes, skipEdits, loudChat]

    /// notifyTypes value meaning "every type notifies". Written by the
    /// rules sync when allow-types is absent/disabled; honored by
    /// ChatFilter's type gate. Never appears in legacy files.
    public static let allowAllMarker = "*"

    /// Editor hint per kind; unknown kinds get the generic line.
    public static func hint(for kind: String) -> String {
        switch kind {
        case skipOwn: "On: skip messages you sent. Value ignored."
        case allowTypes: "Value: comma-separated types, e.g. Text, RichText. Off: all types notify."
        case skipEdits: "On: skip message edits. Off: edits notify. Value ignored."
        case loudChat: "Value: chat-name substring. Matching chats notify only on owner/channel mention."
        default: "Custom type: stored and round-tripped, not enforced yet."
        }
    }

    // MARK: validation + parsing

    /// Nil when valid, else a human-readable reason. Unknown kinds are
    /// always valid (extensible payload); known kinds needing a value
    /// must have a non-blank one.
    public func issue() -> String? {
        let k = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { return "rule has no type" }
        switch k {
        case NotifyRule.allowTypes where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return "allow-types rule needs a value (e.g. Text, RichText)"
        case NotifyRule.loudChat where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return "loud-chat rule needs a chat-name substring"
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

    /// Legacy scalars -> the four stock rules. Empty inputs mean "legacy
    /// fill" (mirrors Config.load: blank loud = BTAC, blank types =
    /// Text/RichText), so migrated rules encode the exact effective
    /// legacy behavior. Always returns all four kinds, in knownKinds
    /// order; `notifyOnEdit` maps to inverted skip-edits.
    public static func migrate(skipOwn: Bool, notifyOnEdit: Bool, types: [String], loud: String) -> [NotifyRule] {
        let effLoud = loud.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "BTAC" : loud
        let effTypes = types.isEmpty ? ["Text", "RichText"] : types
        return [
            NotifyRule(kind: NotifyRule.skipOwn, enabled: skipOwn),
            NotifyRule(kind: NotifyRule.allowTypes, value: effTypes.joined(separator: ", "), enabled: true),
            NotifyRule(kind: NotifyRule.skipEdits, enabled: !notifyOnEdit),
            NotifyRule(kind: NotifyRule.loudChat, value: effLoud, enabled: true),
        ]
    }
}
