import Compression
import Foundation

/// Trouter `/messaging` payload decode + EventMessage parse.
/// Wire shapes per purple-teams teams_trouter.c / teams_messages.c and
/// agent-messenger trouter.ts.
public enum EventMessage {
    // MARK: Body decode

    public enum DecodeError: Error, Sendable {
        case invalidJSON
        case gunzipFailed
    }

    /// Decode a 3::: request body: optional gzip+base64 transport encoding,
    /// then optional nested `cp` (gzip+base64) or `gp` (base64) payloads.
    public static func decodeBody(headers: [String: String], body: String) throws -> [String: Any] {
        var raw = body
        if headers["X-Microsoft-Skype-Content-Encoding"] == "gzip" {
            guard let data = Data(base64Encoded: body),
                  let s = gunzipToString(data)
            else { throw DecodeError.gunzipFailed }
            raw = s
        }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw DecodeError.invalidJSON }
        if let cp = obj["cp"] as? String {
            guard let data = Data(base64Encoded: cp),
                  let s = gunzipToString(data),
                  let inner = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: inner) as? [String: Any]
            else { throw DecodeError.gunzipFailed }
            return o
        }
        if let gp = obj["gp"] as? String {
            guard let data = Data(base64Encoded: gp),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw DecodeError.invalidJSON }
            return o
        }
        return obj
    }

    /// gzip (RFC 1952) to string: strip 10-byte header + 8-byte trailer,
    /// raw-deflate-decode the middle via Compression.framework.
    public static func gunzipToString(_ data: Data) -> String? {
        guard let raw = gunzip(data) else { return nil }
        return String(data: raw, encoding: .utf8)
    }

    public static func gunzip(_ data: Data) -> Data? {
        guard data.count > 18 else { return nil }
        let body = data.dropFirst(10).dropLast(8)
        return inflateRaw(Array(body))
    }

    static func inflateRaw(_ bytes: [UInt8]) -> Data? {
        let dstSize = max(bytes.count * 4, 4096)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstSize)
        defer { dst.deallocate() }
        let decoded = bytes.withUnsafeBufferPointer { src in
            compression_decode_buffer(dst, dstSize, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
        }
        guard decoded > 0 else { return nil }
        return Data(bytes: dst, count: decoded)
    }

    // MARK: Event parse

    public struct Message: @unchecked Sendable {
        public let chatID: String
        public let messageID: String
        public let senderMRI: String?
        public let senderName: String
        /// Raw body (text or HTML depending on messagetype).
        public let content: String
        public let messageType: String
        public let threadTopic: String?
        public let mentions: [Mention]
        /// Decoded `properties` object (may be empty).
        public let properties: [String: Any]
        public let composeTime: String?

        public var plainText: String { HTML.stripPreservingBreaks(content) }
    }

    /// Parse a decoded messaging body. Nil when not a chat message event.
    /// Accepts resourceType NewMessage (notify) and MessageUpdate (edits;
    /// caller decides; parser flags via `isEdit`).
    public static func parse(_ obj: [String: Any]) -> (message: Message, isEdit: Bool)? {
        guard (obj["type"] as? String) == "EventMessage",
              let resourceType = obj["resourceType"] as? String,
              resourceType == "NewMessage" || resourceType == "MessageUpdate",
              let r = obj["resource"] as? [String: Any]
        else { return nil }
        return parseResource(r, isEdit: resourceType == "MessageUpdate")
    }

    /// Parse a message `resource` object (shared by realtime events and REST
    /// message rows, which carry the same field names).
    public static func parseResource(_ r: [String: Any], isEdit: Bool = false) -> (message: Message, isEdit: Bool)? {
        guard let messageType = (r["messagetype"] as? String) ?? (r["messageType"] as? String),
              let conversationLink = (r["conversationLink"] as? String) ?? (r["conversationlink"] as? String),
              let chatID = chatID(fromConversationLink: conversationLink)
        else { return nil }

        let from = (r["from"] as? String) ?? ""
        let content = (r["content"] as? String) ?? ""
        let senderName = (r["imdisplayname"] as? String) ?? (r["imDisplayName"] as? String)
            ?? (r["fromDisplayNameInToken"] as? String) ?? ""
        let messageID = (r["id"] as? String)
            ?? (r["clientmessageid"] as? String) ?? (r["clientMessageId"] as? String) ?? ""
        let properties = Mentions.jsonRecord(r["properties"]) ?? [:]
        let mentions = Mentions.parse(properties: properties.isEmpty ? r["properties"] : properties, content: content)
        let msg = Message(
            chatID: chatID,
            messageID: messageID,
            senderMRI: mri(fromContactLink: from),
            senderName: senderName,
            content: content,
            messageType: messageType,
            threadTopic: (r["threadtopic"] as? String) ?? (r["threadTopic"] as? String),
            mentions: mentions,
            properties: properties,
            composeTime: (r["composetime"] as? String) ?? (r["composeTime"] as? String)
        )
        return (msg, isEdit)
    }

    // MARK: ID extraction

    /// conversationLink contains `/conversations/{chatID}[?...]`.
    public static func chatID(fromConversationLink link: String) -> String? {
        guard let range = link.range(of: "conversations/") else { return nil }
        var id = String(link[range.upperBound...])
        // Stop at the next path/query/fragment separator (agent-messenger:
        // conversations/([^/]+)), plus ';' reply-chain suffix collapse.
        if let end = id.firstIndex(where: { "/?#;".contains($0) }) { id = String(id[..<end]) }
        id = id.removingPercentEncoding ?? id
        return id.isEmpty ? nil : id
    }

    /// `from` is a contact link ending in .../contacts/{mri}, or a bare MRI.
    public static func mri(fromContactLink link: String) -> String? {
        if link.isEmpty { return nil }
        if let range = link.range(of: "/contacts/", options: .backwards) {
            let mri = String(link[range.upperBound...]).removingPercentEncoding ?? String(link[range.upperBound...])
            return mri.isEmpty ? nil : mri
        }
        if link.contains(":") { return link } // already bare MRI (8:orgid:... etc)
        return nil
    }
}
