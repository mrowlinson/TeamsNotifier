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
    /// Mute switch (menu toggle, persisted). Suppresses message
    /// notifications only — system/sign-in-needed notifications still show.
    /// Default false.
    public var muted: Bool

    public init(
        owner: Owner = Owner(),
        loudSubstring: String = "BTAC",
        notifyOnEdit: Bool = false,
        skipOwnMessages: Bool = true,
        notifyTypes: [String] = ["Text", "RichText"],
        muted: Bool = false
    ) {
        self.owner = owner
        self.loudSubstring = loudSubstring
        self.notifyOnEdit = notifyOnEdit
        self.skipOwnMessages = skipOwnMessages
        self.notifyTypes = notifyTypes
        self.muted = muted
    }

    enum CodingKeys: String, CodingKey {
        case owner, loudSubstring, notifyOnEdit, skipOwnMessages, notifyTypes, muted
    }

    /// Tolerant decode: configs written before `muted` existed (or missing
    /// any key) still load, missing keys fall back to defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.default
        owner = (try? c.decodeIfPresent(Owner.self, forKey: .owner)) ?? d.owner
        loudSubstring = (try? c.decodeIfPresent(String.self, forKey: .loudSubstring)) ?? d.loudSubstring
        notifyOnEdit = (try? c.decodeIfPresent(Bool.self, forKey: .notifyOnEdit)) ?? d.notifyOnEdit
        skipOwnMessages = (try? c.decodeIfPresent(Bool.self, forKey: .skipOwnMessages)) ?? d.skipOwnMessages
        notifyTypes = (try? c.decodeIfPresent([String].self, forKey: .notifyTypes)) ?? d.notifyTypes
        muted = (try? c.decodeIfPresent(Bool.self, forKey: .muted)) ?? d.muted
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
