import Foundation

/// Owner configuration: ~/.config/teamsnotifier/config.json (override with
/// --config). CLI flags override file values. Defaults in Config.defaults.
public struct Config: Codable, Sendable {
    public struct Owner: Codable, Sendable {
        /// Display name, e.g. "Michael Rowlinson". Fallback mention signal.
        public var displayName: String
        /// Work UPN, e.g. "michael@company.com". Matched against token claims.
        public var upn: String
        /// Owner Skype MRI (8:orgid:{oid}). Preferred mention signal.
        /// Auto-learned from the AAD token on sign-in when empty.
        public var mri: String

        public init(displayName: String = "", upn: String = "", mri: String = "") {
            self.displayName = displayName
            self.upn = upn
            self.mri = mri
        }
    }

    public var owner: Owner
    /// Case-insensitive substring; matching chats only notify on owner or
    /// channel/Everyone mention. Default "BTAC".
    public var loudSubstring: String
    /// Notify on MessageUpdate edits. Default false.
    public var notifyOnEdit: Bool
    /// Skip messages sent by the owner. Default true.
    public var skipOwnMessages: Bool
    /// In noisy (mention-only) chats, @channel/@team/@everyone mentions
    /// also notify. Default true (the long-standing behavior).
    public var noisyChannelMentions: Bool
    /// When Teams omits sender/mention IDs, fall back to comparing the
    /// owner's display name (own-message + owner-mention matching).
    /// Default true (the long-standing behavior).
    public var matchByDisplayName: Bool
    /// Message types that notify (prefix match on messagetype's first
    /// segment, e.g. "Text", "RichText"). Default ["Text", "RichText"].
    public var notifyTypes: [String]
    /// Legacy persisted mute flag. The app overwrites it per message with the
    /// effective value (schedule + memory-only manual override), so the
    /// stored value no longer means anything. Kept so old configs still
    /// decode/round-trip.
    public var muted: Bool
    /// Weekly mute schedule. Fresh installs start EMPTY (never muted by
    /// schedule); configs that predate stored schedules migrate the
    /// owner's entries on first load (see didMigrateSchedule). Edited in
    /// the GUI (menu Edit schedule) and persisted to this file.
    public var muteWindows: [MuteWindow]
    /// IANA time zone the schedule runs in. Default "America/New_York".
    public var scheduleTZ: String
    /// Issues seen while decoding the schedule keys (wrong JSON types).
    /// Not encoded. Drained by normalizeSchedule() into fault-log lines.
    public var scheduleDecodeIssues: [String] = []
    /// True when this load migrated a legacy config (muteWindows key
    /// absent) to the owner schedule. Not encoded. The app logs it; load
    /// already persisted the migrated entries back to the store.
    public var didMigrateSchedule: Bool = false
    /// Notify/skip rules (the extensible store behind ChatFilter's gates).
    /// Fresh installs keep this BLANK; configs that predate the rules key
    /// migrate the legacy scalars on first load (see didMigrateRules).
    /// Edited in the GUI (menu Edit rules) and persisted to this file.
    /// Whenever the key is present, the legacy scalars below are synced
    /// FROM these rules on decode (first match per kind wins; unknown
    /// kinds preserved but not enforced).
    public var notifyRules: [NotifyRule]
    /// Issues seen while decoding the rules key. Not encoded. Drained by
    /// normalizeRules() into fault-log lines.
    public var rulesDecodeIssues: [String] = []
    /// True when this load migrated legacy scalars to notifyRules (key
    /// absent). Not encoded. The app logs it; load already persisted the
    /// migrated rules back to the store.
    public var didMigrateRules: Bool = false
    /// True when the decoded JSON carried the notifyRules key (even an
    /// empty list: stored-empty is a deliberate "notify everything").
    /// Not encoded. Fresh Config() values report false.
    public var rulesStored: Bool = false

    public init(
        owner: Owner = Owner(),
        loudSubstring: String = "BTAC",
        notifyOnEdit: Bool = false,
        skipOwnMessages: Bool = true,
        noisyChannelMentions: Bool = true,
        matchByDisplayName: Bool = true,
        notifyTypes: [String] = ["Text", "RichText"],
        muted: Bool = false,
        muteWindows: [MuteWindow] = [],
        scheduleTZ: String = MuteSchedule.defaultTimeZoneID,
        notifyRules: [NotifyRule] = []
    ) {
        self.owner = owner
        self.loudSubstring = loudSubstring
        self.notifyOnEdit = notifyOnEdit
        self.skipOwnMessages = skipOwnMessages
        self.noisyChannelMentions = noisyChannelMentions
        self.matchByDisplayName = matchByDisplayName
        self.notifyTypes = notifyTypes
        self.muted = muted
        self.muteWindows = muteWindows
        self.scheduleTZ = scheduleTZ
        self.notifyRules = notifyRules
    }

    enum CodingKeys: String, CodingKey {
        case owner, loudSubstring, notifyOnEdit, skipOwnMessages, notifyTypes, muted
        case noisyChannelMentions, matchByDisplayName
        case muteWindows, scheduleTZ
        case notifyRules
    }

    /// Tolerant decode: configs written before `muted`/`muteWindows` existed
    /// (or missing any key) still load, missing keys fall back to defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.default
        owner = (try? c.decodeIfPresent(Owner.self, forKey: .owner)) ?? d.owner
        loudSubstring = (try? c.decodeIfPresent(String.self, forKey: .loudSubstring)) ?? d.loudSubstring
        notifyOnEdit = (try? c.decodeIfPresent(Bool.self, forKey: .notifyOnEdit)) ?? d.notifyOnEdit
        skipOwnMessages = (try? c.decodeIfPresent(Bool.self, forKey: .skipOwnMessages)) ?? d.skipOwnMessages
        noisyChannelMentions = (try? c.decodeIfPresent(Bool.self, forKey: .noisyChannelMentions)) ?? d.noisyChannelMentions
        matchByDisplayName = (try? c.decodeIfPresent(Bool.self, forKey: .matchByDisplayName)) ?? d.matchByDisplayName
        notifyTypes = (try? c.decodeIfPresent([String].self, forKey: .notifyTypes)) ?? d.notifyTypes
        muted = (try? c.decodeIfPresent(Bool.self, forKey: .muted)) ?? d.muted
        // Schedule keys: present-but-undecodable falls back to the owner
        // schedule AND records a fault-log line (a silent try? would hide
        // owner typos). Absent key = legacy config from an existing
        // install: migrate the owner entries (quietly). Fresh installs
        // never decode at all (missing file returns Config.default).
        scheduleDecodeIssues = []
        if c.contains(.muteWindows) {
            do {
                muteWindows = try c.decodeIfPresent([MuteWindow].self, forKey: .muteWindows) ?? []
            } catch {
                muteWindows = MuteWindow.ownerSchedule
                scheduleDecodeIssues.append("bad muteWindows (undecodable JSON, want [{days,start,end}]), using owner schedule")
            }
            didMigrateSchedule = false
        } else {
            muteWindows = MuteWindow.ownerSchedule
            didMigrateSchedule = true
        }
        if c.contains(.scheduleTZ) {
            do {
                scheduleTZ = try c.decodeIfPresent(String.self, forKey: .scheduleTZ) ?? d.scheduleTZ
            } catch {
                scheduleTZ = d.scheduleTZ
                scheduleDecodeIssues.append("bad scheduleTZ (undecodable JSON, want IANA string), using defaults")
            }
        } else {
            scheduleTZ = d.scheduleTZ
        }
        // Rules key: present-but-undecodable re-migrates from the legacy
        // scalars (a silent try? would hide owner typos). Absent key =
        // legacy config from an existing install: migrate the effective
        // legacy values (NotifyRule.migrate applies the legacy fills).
        // Fresh installs never decode at all (missing file returns blank
        // Config.default). Either way the scalars end up synced from the
        // rules, so ChatFilter (which reads the scalars) sees one source.
        rulesDecodeIssues = []
        if c.contains(.notifyRules) {
            do {
                notifyRules = try c.decodeIfPresent([NotifyRule].self, forKey: .notifyRules) ?? []
            } catch {
                notifyRules = NotifyRule.migrate(
                    skipOwn: skipOwnMessages, notifyOnEdit: notifyOnEdit,
                    types: notifyTypes, loud: loudSubstring)
                rulesDecodeIssues.append("bad notifyRules (undecodable JSON, want [{kind,value,enabled}]), re-migrated from legacy settings")
            }
            rulesStored = true
            didMigrateRules = false
        } else {
            notifyRules = NotifyRule.migrate(
                skipOwn: skipOwnMessages, notifyOnEdit: notifyOnEdit,
                types: notifyTypes, loud: loudSubstring)
            rulesStored = false
            didMigrateRules = true
        }
        applyRules()
    }

    /// Sync the legacy filter scalars FROM the stored rules. Total: every
    /// known kind resolves here (first match wins), so after this call
    /// the scalars reflect exactly what the list says. Absent/disabled
    /// rules switch their gate off (message-types then allows every
    /// type via the "*" marker) — EXCEPT noisy-chats-channel-mentions
    /// and my-name-as-backup, whose ABSENT default is ON (the hardcoded
    /// pre-rules behavior): only a present disabled rule turns them off.
    /// Unknown kinds are preserved untouched.
    public mutating func applyRules() {
        // Canonical matching: in-memory legacy ids (never from decode,
        // which maps them) still resolve to their replacement's gate.
        func first(_ kind: String) -> NotifyRule? {
            notifyRules.first(where: { NotifyRule.canonicalKind($0.kind) == kind })
        }
        if let r = first(NotifyRule.skipMyMessages) {
            skipOwnMessages = r.enabled
        } else {
            skipOwnMessages = false
        }
        if let r = first(NotifyRule.skipEdited) {
            notifyOnEdit = !r.enabled
        } else {
            notifyOnEdit = true
        }
        if let r = first(NotifyRule.noisyChats),
           r.enabled, !r.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            loudSubstring = r.value
        } else {
            loudSubstring = ""
        }
        if let r = first(NotifyRule.messageTypes), r.enabled {
            let types = NotifyRule.parseTypes(r.value)
            notifyTypes = types.isEmpty ? [NotifyRule.allowAllMarker] : types
        } else {
            notifyTypes = [NotifyRule.allowAllMarker]
        }
        // Absent = ON (hardcoded pre-rules behavior): pre-rename rule
        // lists carry neither kind, and must not silently lose them.
        // Deleting the rule in the GUI likewise reverts to ON; only a
        // present disabled rule switches the gate off (explicit wins).
        if let r = first(NotifyRule.noisyChannel) {
            noisyChannelMentions = r.enabled
        } else {
            noisyChannelMentions = true
        }
        if let r = first(NotifyRule.nameBackup) {
            matchByDisplayName = r.enabled
        } else {
            matchByDisplayName = true
        }
    }

    /// Replace invalid schedule pieces with defaults. Returns fault-log lines
    /// for every substitution (the app logs them; TeamsCore has no logger).
    /// Empty windows list is valid (scheduled mute disabled). Decode issues
    /// are drained (reported once); an unknown scheduleTZ keeps warning
    /// since the value is kept and the app falls back at resolve time.
    @discardableResult
    public mutating func normalizeSchedule() -> [String] {
        var warnings = scheduleDecodeIssues
        scheduleDecodeIssues = []
        for w in muteWindows {
            if let issue = w.issue() {
                warnings.append("bad muteWindows (\(issue)), using owner schedule")
                muteWindows = MuteWindow.ownerSchedule
                break
            }
        }
        if TimeZone(identifier: scheduleTZ) == nil {
            warnings.append("unknown scheduleTZ \"\(scheduleTZ)\", using system time zone")
        }
        return warnings
    }

    /// Drop unusable rules (no kind; known kind with a blank value where
    /// one is required). Returns fault-log lines. Unknown kinds are kept
    /// (extensible payload). Decode issues drain once. No re-sync needed:
    /// applyRules() already treats blank values as gate-off, so dropping
    /// changes nothing effective.
    @discardableResult
    public mutating func normalizeRules() -> [String] {
        var warnings = rulesDecodeIssues
        rulesDecodeIssues = []
        var kept: [NotifyRule] = []
        kept.reserveCapacity(notifyRules.count)
        for r in notifyRules {
            if let problem = r.issue() {
                warnings.append("bad notifyRules (\(problem), rule \(r.kind.isEmpty ? "(no type)" : r.kind), dropped)")
            } else {
                kept.append(r)
            }
        }
        notifyRules = kept
        return warnings
    }

    public static var `default`: Config {
        Config(owner: Owner(displayName: "Michael Rowlinson"))
    }

    public static var defaultPath: String {
        NSString(string: "~/.config/teamsnotifier/config.json").expandingTildeInPath
    }

    /// Load from path; missing file yields a FRESH config with an empty
    /// schedule (zero seeded entries) and BLANK rules, UNLESS
    /// `existingInstall` is true (the app passes Keychain sign-in
    /// presence: an owner who never created a config file but is signed
    /// in is an existing install, not a fresh one). Missing-file +
    /// existing install migrates the owner schedule + stock owner rules
    /// and persists them (same didMigrate* + save pattern as legacy
    /// files). An existing file whose JSON lacks the schedule/rules keys
    /// migrates them AND persists them back to the store (best-effort: a
    /// failed write keeps the file as it was while the in-memory values
    /// are still migrated).
    public static func load(from path: String, existingInstall: Bool = false) throws -> Config {
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if existingInstall {
                var migrated = Config.default
                migrated.muteWindows = MuteWindow.ownerSchedule
                migrated.didMigrateSchedule = true
                migrated.notifyRules = NotifyRule.migrate(
                    skipOwn: migrated.skipOwnMessages, notifyOnEdit: migrated.notifyOnEdit,
                    types: migrated.notifyTypes, loud: migrated.loudSubstring)
                migrated.rulesStored = false
                migrated.didMigrateRules = true
                migrated.applyRules()
                try? migrated.save(to: path)
                return migrated
            }
            var fresh = Config.default
            fresh.muteWindows = []
            fresh.notifyRules = []
            // Blank rules = notify everything (same sync the decode
            // path runs): without this the legacy-fill scalars from
            // Config.default would filter while the GUI shows blank.
            fresh.applyRules()
            return fresh
        }
        let data = try Data(contentsOf: url)
        var cfg = try JSONDecoder().decode(Config.self, from: data)
        if cfg.owner.displayName.isEmpty { cfg.owner.displayName = Config.default.owner.displayName }
        // Legacy fills only when the rules key is absent: with stored
        // rules the scalars already reflect the list (a blank loud there
        // is a deliberate gate-off, not a gap to re-seed).
        if !cfg.rulesStored {
            if cfg.loudSubstring.isEmpty { cfg.loudSubstring = "BTAC" }
            if cfg.notifyTypes.isEmpty { cfg.notifyTypes = ["Text", "RichText"] }
        }
        if cfg.didMigrateSchedule || cfg.didMigrateRules {
            try? cfg.save(to: path)
        }
        return cfg
    }

    public func save(to path: String) throws {
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }
}
