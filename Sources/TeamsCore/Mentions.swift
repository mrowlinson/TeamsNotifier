import Foundation

/// Teams mention parsing. Protocol shape per agent-messenger trouter.ts
/// (PR #281) and purple-teams teams_messages.c:
///
/// Authoritative: `properties.mentions` array (object or JSON string), entries
/// like {"itemid":"0","mri":"8:orgid:oid","mentionType":"person",
/// "displayName":"Alice"}. Fallback: positional `<span
/// itemtype=".../Mention" itemid="N">Name</span>` markup in content, which
/// carries no MRI.
public struct Mention: Sendable, Equatable {
    /// Positional index matching the content span's itemid.
    public let id: String
    public let mri: String?
    public let mentionType: String?
    public let displayName: String

    public init(id: String, mri: String?, mentionType: String? = nil, displayName: String) {
        self.id = id
        self.mri = mri
        self.mentionType = mentionType
        self.displayName = displayName
    }
}

public enum Mentions {
    // MARK: Parse

    /// Never throws: bad data yields an empty list.
    public static func parse(properties: Any?, content: String) -> [Mention] {
        let fromProps = parseFromProperties(properties)
        if !fromProps.isEmpty { return fromProps }
        return parseFromContent(content)
    }

    /// `properties` may be a dict or a JSON string of one; `mentions` may be
    /// an array or a JSON string of one (both shapes observed on the wire).
    public static func parseFromProperties(_ properties: Any?) -> [Mention] {
        guard let record = jsonRecord(properties),
              let raw = jsonArray(record["mentions"])
        else { return [] }
        var out: [Mention] = []
        for entry in raw {
            guard let item = entry as? [String: Any] else { continue }
            let id: String?
            if let s = item["itemid"] as? String { id = s } else if let n = item["itemid"] as? Int { id = String(n) } else if let n = item["itemid"] as? Double { id = String(Int(n)) } else { id = nil }
            guard let id else { continue }
            out.append(Mention(
                id: id,
                mri: item["mri"] as? String,
                mentionType: (item["mentionType"] as? String) ?? (item["type"] as? String),
                displayName: (item["displayName"] as? String) ?? ""
            ))
        }
        return out
    }

    /// Content-span fallback. Matches `<span ... itemtype="...Mention..."
    /// ... itemid="N">Name</span>` regardless of attribute order.
    public static func parseFromContent(_ content: String) -> [Mention] {
        var out: [Mention] = []
        let pattern = #"<span\b[^>]*itemtype=["'][^"']*Mention[^"']*["'][^>]*>(.*?)</span>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = content as NSString
        for m in re.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            let whole = ns.substring(with: m.range(at: 0))
            guard let idRe = try? NSRegularExpression(pattern: #"itemid=["']([^"']*)["']"#, options: .caseInsensitive),
                  let idM = idRe.firstMatch(in: whole, range: NSRange(location: 0, length: (whole as NSString).length))
            else { continue }
            let id = (whole as NSString).substring(with: idM.range(at: 1))
            let inner = ns.substring(with: m.range(at: 1))
            out.append(Mention(id: id, mri: nil, displayName: HTML.strip(inner)))
        }
        return out
    }

    // MARK: Classify

    /// Owner mention? MRI match preferred (config carries owner MRI, learned
    /// from the AAD token's oid claim). Display-name match is the backup
    /// when protocol data lacks an MRI (content-span fallback path),
    /// unless `matchByName` is false (IDs only).
    public static func mentionsOwner(_ mentions: [Mention], ownerMRI: String?, ownerDisplayName: String, matchByName: Bool = true) -> Bool {
        let wantName = ownerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for m in mentions {
            if let ownerMRI, !ownerMRI.isEmpty, let mri = m.mri, !mri.isEmpty {
                if mri.caseInsensitiveCompare(ownerMRI) == .orderedSame { return true }
                continue // MRI present but different: not owner; do not name-match.
            }
            if matchByName, !wantName.isEmpty, m.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wantName {
                return true
            }
        }
        return false
    }

    /// Channel-wide mention? Matches mentionType tag values Teams uses for
    /// @channel/@team blasts, plus display-name spellings as fallback.
    /// Protocol data varies here; both signals are checked explicitly.
    public static func mentionsChannelOrEveryone(_ mentions: [Mention]) -> Bool {
        for m in mentions {
            if let t = m.mentionType?.lowercased(),
               t == "channel" || t == "everyone" || t == "team" || t == "channelmessage"
            { return true }
            let n = m.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if n == "channel" || n == "everyone" || n == "team" { return true }
        }
        return false
    }

    // MARK: JSON helpers

    static func jsonRecord(_ value: Any?) -> [String: Any]? {
        if let s = value as? String {
            guard let d = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { return nil }
            return o
        }
        return value as? [String: Any]
    }

    static func jsonArray(_ value: Any?) -> [Any]? {
        if let s = value as? String {
            guard let d = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [Any]
            else { return nil }
            return o
        }
        return value as? [Any]
    }
}
