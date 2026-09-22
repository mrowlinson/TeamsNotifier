import Foundation

/// One chat conversation message: REST history row or live trouter event.
/// Text is plain (HTML stripped, entities decoded).
public struct ChatMessage: Sendable, Equatable {
    public let id: String
    public let sender: String
    public let text: String
    public let date: Date?
    public let rawTime: String?

    public init(id: String, sender: String, text: String, date: Date? = nil, rawTime: String? = nil) {
        self.id = id
        self.sender = sender
        self.text = text
        self.date = date
        self.rawTime = rawTime
    }
}

/// REST history codec + transcript formatting for per-chat windows.
/// Endpoint per ost chat.rs read_messages_data: GET
/// {base}/v1/users/ME/conversations/{chatID}/messages?pageSize=N,
/// header `Authentication: skypetoken=...`. Response `messages` is
/// newest-first; parse returns oldest-first (chronological).
public enum ChatWindowHistory {
    public static let defaultPageSize = 50

    public static func url(chatServiceBase: String, chatID: String, pageSize: Int = defaultPageSize) -> URL? {
        let encoded = chatID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? chatID
        return URL(string: "\(chatServiceBase)/v1/users/ME/conversations/\(encoded)/messages?pageSize=\(pageSize)")
    }

    /// Text-bearing types only (ost rule: skip ThreadActivity/* etc).
    public static func isTextMessage(type messageType: String) -> Bool {
        messageType.contains("Text") || messageType.contains("RichText")
    }

    /// Decode a GET messages response body. Corrupt body -> [] (caller
    /// reports the fetch, never a parse crash).
    public static func parseMessagesResponse(_ data: Data) -> [ChatMessage] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["messages"] as? [[String: Any]]
        else { return [] }
        // Newest-first on the wire; chronological for display.
        return rows.compactMap(parseMessageRow).reversed()
    }

    /// One REST message row -> ChatMessage. Nil for non-text types and
    /// empty-text rows. Accepts both lowerCamel (REST) spellings.
    public static func parseMessageRow(_ r: [String: Any]) -> ChatMessage? {
        let type_ = (r["messagetype"] as? String) ?? (r["messageType"] as? String) ?? ""
        guard isTextMessage(type: type_) else { return nil }
        let content = (r["content"] as? String) ?? ""
        let text = HTML.stripPreservingBreaks(content).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let sender = (r["imdisplayname"] as? String) ?? (r["imDisplayName"] as? String) ?? ""
        let id = (r["id"] as? String)
            ?? (r["clientmessageid"] as? String) ?? (r["clientMessageId"] as? String) ?? ""
        let rawTime = (r["originalarrivaltime"] as? String) ?? (r["originalArrivalTime"] as? String)
            ?? (r["composetime"] as? String) ?? (r["composeTime"] as? String)
        let date = rawTime.flatMap(parseDate)
        return ChatMessage(id: id, sender: sender, text: text, date: date, rawTime: rawTime)
    }

    /// Teams ISO timestamps ("2026-09-21T12:34:56.789Z", with or without
    /// fractional seconds). Nil when unparseable (line shows untimed).
    public static func parseDate(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// One transcript line: "[HH:mm] sender: text" (time omitted when
    /// unknown, sender falls back to "?" when empty).
    public static func formatLine(_ m: ChatMessage, timeZone: TimeZone = .current) -> String {
        let sender = m.sender.isEmpty ? "?" : m.sender
        guard let date = m.date else { return "\(sender): \(m.text)" }
        let f = DateFormatter()
        f.timeZone = timeZone
        f.dateFormat = "HH:mm"
        return "[\(f.string(from: date))] \(sender): \(m.text)"
    }

    /// Full window transcript, one blank line between messages.
    public static func transcript(_ messages: [ChatMessage], timeZone: TimeZone = .current) -> String {
        messages.map { formatLine($0, timeZone: timeZone) }.joined(separator: "\n\n")
    }
}

/// Per-chat open-window content state (pure, testable). The AppKit
/// controller owns one of these per window; live trouter events funnel
/// through appendLive/applyEdit.
public struct ChatWindowState: Sendable, Equatable {
    public let chatID: String
    public private(set) var messages: [ChatMessage]
    public private(set) var isOpen: Bool

    public init(chatID: String, messages: [ChatMessage] = []) {
        self.chatID = chatID
        self.messages = messages
        self.isOpen = true
    }

    /// Replace contents with fetched history. Dedupes repeated ids
    /// (server pages can overlap); empty ids are undedupable, kept all.
    public mutating func loadHistory(_ fetched: [ChatMessage]) {
        var seen: Set<String> = []
        messages = fetched.filter { m in
            guard !m.id.isEmpty else { return true }
            return seen.insert(m.id).inserted
        }
    }

    /// Append a live message. False when the id is already present (echo
    /// of our own send, trouter redelivery) — no duplicate row.
    @discardableResult
    public mutating func appendLive(_ m: ChatMessage) -> Bool {
        if !m.id.isEmpty, messages.contains(where: { $0.id == m.id }) { return false }
        messages.append(m)
        return true
    }

    /// Apply an edit in place (same row, new text). False when the id is
    /// unknown (outside the fetched window) — ignored, not appended.
    @discardableResult
    public mutating func applyEdit(_ m: ChatMessage) -> Bool {
        guard !m.id.isEmpty,
              let i = messages.firstIndex(where: { $0.id == m.id })
        else { return false }
        messages[i] = m
        return true
    }

    public mutating func close() { isOpen = false }

    /// Reopen keeps the loaded messages (fresh history refetch is the
    /// controller's call; the model never drops what it holds).
    public mutating func reopen() { isOpen = true }
}

/// One-window-per-chat bookkeeping (pure). The controller holds the real
/// map; these are the rules: open focuses when present, close drops.
public struct ChatWindowRegistry: Sendable, Equatable {
    public private(set) var openChats: Set<String> = []

    public init() {}

    public enum OpenResult: Sendable, Equatable {
        case opened
        case focused
    }

    @discardableResult
    public mutating func open(chatID: String) -> OpenResult {
        if openChats.contains(chatID) { return .focused }
        openChats.insert(chatID)
        return .opened
    }

    public mutating func close(chatID: String) {
        openChats.remove(chatID)
    }

    public func isOpen(chatID: String) -> Bool {
        openChats.contains(chatID)
    }
}

/// Window send path: gate + payload. Nil when the send must not go out
/// (empty thread, blank text); otherwise the ReplyPayload POST body with
/// the text trimmed (same endpoint/auth as inline notification replies).
public enum ChatWindowSend {
    public static func payload(chatID: String, text: String, clientMessageID: String) -> [String: String]? {
        guard ReplyGate.canReply(chatID: chatID, text: text) else { return nil }
        return ReplyPayload.build(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            clientMessageID: clientMessageID)
    }
}
