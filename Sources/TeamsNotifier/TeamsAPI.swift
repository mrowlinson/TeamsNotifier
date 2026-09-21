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
