import Foundation
import TeamsCore

/// Chat REST over the skype-token authed chat service (ost chat.rs /
/// client.rs path): single base from regionGtms.chatService, header
/// `Authentication: skypetoken=...`.
public actor TeamsAPI {
    public enum APIError: Error, Sendable {
        case http(Int, String)
        case network(String)
    }

    /// Human reason for the loud "Reply failed: <reason>" notification.
    public static func reason(for error: Error) -> String {
        if let e = error as? APIError {
            switch e {
            case .http(let code, let body):
                return body.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(body)"
            case .network(let msg):
                return msg
            }
        }
        return String(describing: error)
    }

    private let auth: AuthManager
    private let session: URLSession
    private var nameCache: [String: String] = [:]

    public init(auth: AuthManager) {
        self.auth = auth
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: cfg)
    }

    /// Display name for a chat. Cache-first; REST fallback; thread id as
    /// last resort (never throws: loud internal APIs must fail loud but a
    /// missing name must not drop the notification).
    public func chatDisplayName(chatID: String, threadTopic: String?) async -> String {
        if let t = threadTopic, !t.isEmpty { return t }
        if let cached = nameCache[chatID] { return cached }
        do {
            let name = try await fetchConversationName(chatID: chatID)
            nameCache[chatID] = name
            return name
        } catch {
            Log.fault("chat name resolve failed for \(chatID): \(error)")
            return chatID
        }
    }

    public func primeCache(chatID: String, name: String) {
        nameCache[chatID] = name
    }

    /// Inline reply: POST one message to a thread (ReplyPayload provenance).
    /// Same skype token + base as chat REST (no new auth). Any 2xx = sent
    /// (refs see 201 Created). 401 refreshes the skype token once + retries,
    /// mirroring fetchConversationName.
    public func sendReply(chatID: String, text: String) async throws {
        let payload = ReplyPayload.build(text: text, clientMessageID: ReplyPayload.clientMessageID())
        let body = try JSONSerialization.data(withJSONObject: payload)
        let creds = try await auth.ensureSkypeCredentials()
        do {
            try await postMessage(base: creds.chatServiceBase, chatID: chatID, skypeToken: creds.skypeToken, body: body)
        } catch APIError.http(401, _) {
            Log.info("reply 401, refreshing skype token once")
            let fresh = try await auth.refreshSkypeCredentials()
            try await postMessage(base: fresh.chatServiceBase, chatID: chatID, skypeToken: fresh.skypeToken, body: body)
        }
    }

    private func postMessage(base: String, chatID: String, skypeToken: String, body: Data) async throws {
        guard let url = ReplyPayload.url(chatServiceBase: base, chatID: chatID) else {
            throw APIError.network("bad reply URL for \(chatID)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("skypetoken=\(skypeToken)", forHTTPHeaderField: "Authentication")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("redirectAs404", forHTTPHeaderField: "BehaviorOverride")
        req.httpBody = body
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.network("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
        }
    }

    private func fetchConversationName(chatID: String) async throws -> String {
        let creds = try await auth.ensureSkypeCredentials()
        let encoded = chatID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? chatID
        let url = URL(string: "\(creds.chatServiceBase)/v1/users/ME/conversations/\(encoded)")!
        do {
            return try await getName(url: url, skypeToken: creds.skypeToken, chatID: chatID)
        } catch APIError.http(401, _) {
            Log.info("chat REST 401, refreshing skype token once")
            let fresh = try await auth.refreshSkypeCredentials()
            return try await getName(url: url, skypeToken: fresh.skypeToken, chatID: chatID)
        }
    }

    private func getName(url: URL, skypeToken: String, chatID: String) async throws -> String {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("skypetoken=\(skypeToken)", forHTTPHeaderField: "Authentication")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.network("no HTTP response") }
        guard http.statusCode == 200 else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.network("non-JSON conversation response")
        }
        // Topic shapes: top-level "topic" or threadProperties.topic.
        if let t = obj["topic"] as? String, !t.isEmpty { return t }
        if let props = obj["threadProperties"] as? [String: Any],
           let t = props["topic"] as? String, !t.isEmpty { return t }
        // 1:1 chats: first member display name that is not empty.
        if let members = obj["members"] as? [[String: Any]] {
            for m in members {
                if let n = (m["displayName"] as? String) ?? (m["displayname"] as? String), !n.isEmpty {
                    return n
                }
            }
        }
        Log.debug("conversation \(chatID) has no topic/members, using id")
        return chatID
    }
}
