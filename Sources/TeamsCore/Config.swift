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
    /// Message types that notify (prefix match on messagetype's first
    /// segment, e.g. "Text", "RichText"). Default ["Text", "RichText"].
    public var notifyTypes: [String]
    /// Legacy persisted mute flag. The app overwrites it per message with the
    /// effective value (schedule + memory-only manual override), so the
    /// stored value no longer means anything. Kept so old configs still
    /// decode/round-trip.
    public var muted: Bool
    /// Weekly mute schedule. Default: muted Mon-Fri 00:00-07:50 +
    /// 16:40-24:00 + all day Sat/Sun (unmuted Mon-Fri 07:50-16:40).
    /// Empty list disables scheduled mute (never muted by schedule).
    public var muteWindows: [MuteWindow]
    /// IANA time zone the schedule runs in. Default "America/New_York".
    public var scheduleTZ: String
    /// Issues seen while decoding the schedule keys (wrong JSON types).
    /// Not encoded. Drained by normalizeSchedule() into fault-log lines.
    public var scheduleDecodeIssues: [String] = []

    public init(
        owner: Owner = Owner(),
        loudSubstring: String = "BTAC",
        notifyOnEdit: Bool = false,
        skipOwnMessages: Bool = true,
        notifyTypes: [String] = ["Text", "RichText"],
        muted: Bool = false,
        muteWindows: [MuteWindow] = MuteWindow.defaults,
        scheduleTZ: String = MuteSchedule.defaultTimeZoneID
    ) {
        self.owner = owner
        self.loudSubstring = loudSubstring
        self.notifyOnEdit = notifyOnEdit
        self.skipOwnMessages = skipOwnMessages
        self.notifyTypes = notifyTypes
        self.muted = muted
        self.muteWindows = muteWindows
        self.scheduleTZ = scheduleTZ
    }

    enum CodingKeys: String, CodingKey {
        case owner, loudSubstring, notifyOnEdit, skipOwnMessages, notifyTypes, muted
        case muteWindows, scheduleTZ
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
        notifyTypes = (try? c.decodeIfPresent([String].self, forKey: .notifyTypes)) ?? d.notifyTypes
        muted = (try? c.decodeIfPresent(Bool.self, forKey: .muted)) ?? d.muted
        // Schedule keys: present-but-undecodable falls back to defaults AND
        // records a fault-log line (a silent try? would hide owner typos).
        scheduleDecodeIssues = []
        if c.contains(.muteWindows) {
            do {
                muteWindows = try c.decodeIfPresent([MuteWindow].self, forKey: .muteWindows) ?? d.muteWindows
            } catch {
                muteWindows = d.muteWindows
                scheduleDecodeIssues.append("bad muteWindows (undecodable JSON, want [{days,start,end}]), using defaults")
            }
        } else {
            muteWindows = d.muteWindows
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
                warnings.append("bad muteWindows (\(issue)), using defaults")
                muteWindows = MuteWindow.defaults
                break
            }
        }
        if TimeZone(identifier: scheduleTZ) == nil {
            warnings.append("unknown scheduleTZ \"\(scheduleTZ)\", using system time zone")
        }
        return warnings
    }

    public static var `default`: Config {
        Config(owner: Owner(displayName: "Michael Rowlinson"))
    }

    public static var defaultPath: String {
        NSString(string: "~/.config/teamsnotifier/config.json").expandingTildeInPath
    }

    /// Load from path; missing file yields defaults (owner display name
    /// still required for mention fallback, warned at startup).
    public static func load(from path: String) throws -> Config {
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return .default }
        let data = try Data(contentsOf: url)
        var cfg = try JSONDecoder().decode(Config.self, from: data)
        if cfg.owner.displayName.isEmpty { cfg.owner.displayName = Config.default.owner.displayName }
        if cfg.loudSubstring.isEmpty { cfg.loudSubstring = "BTAC" }
        if cfg.notifyTypes.isEmpty { cfg.notifyTypes = ["Text", "RichText"] }
        return cfg
    }

    public func save(to path: String) throws {
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }
}
