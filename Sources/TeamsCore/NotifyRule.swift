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
///   in the legacy scalar as `allowAllMarker`). Exception: an ABSENT
///   noisy-chats-channel-mentions / my-name-as-backup rule leaves its
///   gate ON (the hardcoded pre-rules behavior); only a present
///   disabled rule turns those two off.
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
    /// Absent = ON (hardcoded pre-rules behavior; deleting the rule
    /// reverts to ON). Disabled = only direct owner mentions notify
    /// there. Value ignored.
    public static let noisyChannel = "noisy-chats-channel-mentions"
    /// When Teams omits sender/mention IDs, fall back to comparing the
    /// owner's display name. Absent = ON (hardcoded pre-rules behavior;
    /// deleting the rule reverts to ON). Disabled = IDs only. Value
    /// ignored.
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

    /// Plain-English display name per known kind; the GUI picker shows
    /// these while storing the ids underneath. Legacy ids resolve to
    /// their replacement's name; custom kinds show as-is.
    public static func displayName(for kind: String) -> String {
        switch canonicalKind(kind) {
        case skipMyMessages: "Skip my own messages"
        case messageTypes: "Only these message types"
        case skipEdited: "Skip edited messages"
        case noisyChats: "Noisy chats mention only"
        case noisyChannel: "Noisy chats channel mentions"
        case nameBackup: "My name as backup"
        default: kind
        }
    }

    /// Display names in knownKinds order (the picker's item list).
    public static var knownDisplayNames: [String] {
        knownKinds.map(displayName(for:))
    }

    /// Map picker text back to a stored id: a display name (exact, else
    /// case-insensitive) becomes its kind id; anything else passes
    /// through canonicalKind, so pasted ids (legacy included) and
    /// custom kinds keep working.
    public static func kind(fromDisplayName text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hit = knownKinds.first(where: { displayName(for: $0) == trimmed }) {
            return hit
        }
        if let hit = knownKinds.first(where: {
            displayName(for: $0).caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return hit
        }
        return canonicalKind(trimmed)
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
        case noisyChannel: "On: @channel/@team/@everyone also notify in noisy chats. Off: only your direct mentions do. Deleting this rule turns it back on. Value ignored."
        case nameBackup: "On: when Teams omits sender/mention IDs, match by your display name. Off: IDs only. Deleting this rule turns it back on. Value ignored."
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

    // MARK: editor UX (display only; zero behavior/decode effect)

    /// One Add-picker row: pick by GOAL in plain words. `does` is the
    /// full-sentence WHAT IT DOES, `example` a concrete case ("" when
    /// the kind ignores its value).
    public struct GoalOption: Sendable, Equatable {
        public var kind: String
        public var goal: String
        public var does: String
        public var example: String
    }

    /// Goal rows in knownKinds order; the GUI appends a Custom row.
    /// Each option's kind is its stored id (goal-pick maps 1:1).
    public static var goalOptions: [GoalOption] {
        knownKinds.map {
            GoalOption(kind: $0, goal: goalTitle(for: $0), does: explanation(for: $0), example: exampleText(for: $0))
        }
    }

    /// Plain-words goal title per kind (the Add picker's row title).
    public static func goalTitle(for kind: String) -> String {
        switch canonicalKind(kind) {
        case skipMyMessages: "Skip messages I sent myself"
        case messageTypes: "Only some message types notify"
        case skipEdited: "Skip edited-message notices"
        case noisyChats: "Quiet down noisy chats"
        case noisyChannel: "Let channel mentions through in noisy chats"
        case nameBackup: "Match my name when Teams omits IDs"
        default: "Custom rule of my own"
        }
    }

    /// Full-sentence WHAT IT DOES per kind (2-3 lines max in the
    /// editor). Unknown kinds get the custom fallback.
    public static func explanation(for kind: String) -> String {
        switch canonicalKind(kind) {
        case skipMyMessages: "Messages you sent never notify. Use this to silence your own echoes in busy chats."
        case messageTypes: "Only the listed message types notify; everything else stays silent."
        case skipEdited: "Edited messages stay silent. Turn it off if you want edits to notify."
        case noisyChats: "Chats whose name matches your text notify only when you are mentioned."
        case noisyChannel: "Channel, team and everyone mentions also notify in noisy chats. Turn it off for direct mentions only. Deleting this rule turns it back on."
        case nameBackup: "When Teams omits sender and mention IDs, match by your display name instead. Turn it off for IDs only. Deleting this rule turns it back on."
        default: "Custom type: stored and round-tripped, not enforced yet. A future update may implement it."
        }
    }

    /// Concrete example per kind; "" when the kind ignores its value
    /// (the GUI hides the example line then).
    public static func exampleText(for kind: String) -> String {
        switch canonicalKind(kind) {
        case messageTypes: "Types “Text, RichText” notify for plain and formatted messages only."
        case noisyChats: "Chat text “BTAC” quiets “BTAC War Room” except for your mentions."
        default: ""
        }
    }

    /// Starter value for a rule added from the goal picker. Matches
    /// the legacy fills, so picked rules are valid immediately.
    public static func defaultValue(for kind: String) -> String {
        switch canonicalKind(kind) {
        case messageTypes: "Text, RichText"
        case noisyChats: "BTAC"
        default: ""
        }
    }

    /// What this rule does, in words (the table row text). Includes
    /// the value where the kind reads one; never shows raw ids.
    public static func sentence(for rule: NotifyRule) -> String {
        let v = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return switch canonicalKind(rule.kind.trimmingCharacters(in: .whitespacesAndNewlines)) {
        case skipMyMessages: "Skip messages you sent."
        case messageTypes:
            v.isEmpty ? "Only these message types notify (needs a value)." : "Only these message types notify: \(v)."
        case skipEdited: "Skip edited messages."
        case noisyChats:
            v.isEmpty ? "Noisy chats notify only on mention (needs chat text)." : "Chats matching “\(v)” notify only on mention."
        case noisyChannel: "Channel mentions also notify in noisy chats."
        case nameBackup: "Match by your display name when IDs are missing."
        default:
            v.isEmpty ? "Custom rule “\(rule.kind)” (stored, not enforced yet)." : "Custom rule “\(rule.kind)” = “\(v)” (stored, not enforced yet)."
        }
    }

    /// Blank-state teaching text (shown when the list is empty): what
    /// rules are, that blank = notify everything, how to add one.
    public static let blankStateText = """
        Rules decide what notifies. Each rule either quiets something (skip) or narrows what gets through.
        A blank list means every message notifies.
        Click Add, pick a goal in plain words, fill in the value, then Save.
        """

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

    /// Same validity as issue(), but worded for the editor: display
    /// names instead of raw ids, plus a fix hint. GUI-only; normalize
    /// warnings keep issue().
    public func plainIssue() -> String? {
        let k = NotifyRule.canonicalKind(kind.trimmingCharacters(in: .whitespacesAndNewlines))
        if k.isEmpty { return "This rule has no type yet. Pick a Kind above, or type a custom name." }
        switch k {
        case NotifyRule.messageTypes where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return "“\(NotifyRule.displayName(for: NotifyRule.messageTypes))” needs a value, e.g. Text, RichText."
        case NotifyRule.noisyChats where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return "“\(NotifyRule.displayName(for: NotifyRule.noisyChats))” needs chat-name text, e.g. BTAC."
        default:
            return nil
        }
    }

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
