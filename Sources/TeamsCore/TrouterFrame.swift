import Foundation

/// Socket.io v1 (colon-prefixed) framing over the trouter WebSocket.
/// NOT engine.io. Per purple-teams teams_trouter.c and agent-messenger
/// trouter.ts:
///
/// - `1::` server hello
/// - `3:::{...}` request frame, needs `3:::{id,status:200}` ack
/// - `5:<n>::{...}` event frame; `5:<n>+::` variant needs `6:<n>::` ack
/// - client sends `5:::{...}` ephemeral or `5:<n>+::{...}` sequenced
public enum TrouterFrame {
    // MARK: Build

    public static func authenticate(connectParams: [String: String], idToken: String) -> String {
        let msg: [String: Any] = [
            "name": "user.authenticate",
            "args": [[
                "headers": [
                    "X-Ms-Test-User": "False",
                    "Authorization": "Bearer \(idToken)",
                    "X-MS-Migration": "True",
                ],
                "connectparams": connectParams,
            ]],
        ]
        return "5:::" + json(msg)
    }

    public static func activity(sequence: Int, active: Bool = true) -> String {
        "5:\(sequence)+::{\"name\":\"user.activity\",\"args\":[{\"state\":\"\(active ? "active" : "inactive")\"}]}"
    }

    public static func ping(sequence: Int) -> String {
        "5:\(sequence)+::{\"name\":\"ping\"}"
    }

    public static func requestAck(requestID: Int) -> String {
        "3:::" + json(["id": requestID, "status": 200, "body": ""])
    }

    /// Ack for server `5:<n>+::` frames. Nil when the frame needs no ack.
    public static func eventAck(for frame: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"^5:(\d+)\+::"#),
              let m = re.firstMatch(in: frame, range: NSRange(frame.startIndex..., in: frame)),
              let r = Range(m.range(at: 1), in: frame)
        else { return nil }
        return "6:\(frame[r])::"
    }

    // MARK: Parse

    public struct Request: Sendable {
        public let id: Int
        public let url: String?
        public let headers: [String: String]
        public let body: String
    }

    /// Parse a `3:::{...}` request frame. Nil for anything else.
    public static func parseRequest(_ frame: String) -> Request? {
        guard frame.hasPrefix("3:::") else { return nil }
        let payload = String(frame.dropFirst(4))
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = intValue(obj["id"])
        else { return nil }
        let headers = (obj["headers"] as? [String: Any] ?? [:]).reduce(into: [String: String]()) {
            if let v = $1.value as? String { $0[$1.key] = v }
        }
        return Request(id: id, url: obj["url"] as? String, headers: headers, body: obj["body"] as? String ?? "")
    }

    /// Event name of a `5:...` frame, e.g. trouter.message_loss.
    public static func eventName(_ frame: String) -> String? {
        guard frame.hasPrefix("5:") else { return nil }
        guard let start = frame.firstIndex(of: "{"),
              let data = String(frame[start...]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["name"] as? String
    }

    public static func isMessageLoss(_ frame: String) -> Bool {
        eventName(frame) == "trouter.message_loss"
    }

    public static func isHello(_ frame: String) -> Bool {
        frame.hasPrefix("1::")
    }

    /// Session id from the socket.io handshake body
    /// (`{sid}:180:180:websocket,xhr-polling`).
    public static func parseSessionID(_ body: String) -> String? {
        let sid = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
        guard let sid, !sid.isEmpty else { return nil }
        return sid
    }

    // MARK: Query

    /// Query string shared by the session GET and the WS connect URL.
    public static func query(connectParams: [String: String], endpointID: String, ccid: String?) -> String {
        var items: [URLQueryItem] = [URLQueryItem(name: "v", value: "v4")]
        for (k, v) in connectParams.sorted(by: { $0.key < $1.key }) {
            items.append(URLQueryItem(name: k, value: v))
        }
        let tc = "{\"cv\":\"\(TeamsConstants.trouterTCCV)\",\"ua\":\"TeamsCDL\",\"hr\":\"\",\"v\":\"\(TeamsConstants.clientInfoVersion)\"}"
        items.append(URLQueryItem(name: "tc", value: tc))
        items.append(URLQueryItem(name: "con_num", value: "\(Int(Date().timeIntervalSince1970 * 1000))_1"))
        items.append(URLQueryItem(name: "epid", value: endpointID))
        if let ccid, !ccid.isEmpty { items.append(URLQueryItem(name: "ccid", value: ccid)) }
        items.append(URLQueryItem(name: "auth", value: "true"))
        items.append(URLQueryItem(name: "timeout", value: "40"))
        var c = URLComponents()
        c.queryItems = items
        return c.percentEncodedQuery ?? ""
    }

    // MARK: Helpers

    static func json(_ obj: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8)
        else { return "{}" }
        return s
    }

    static func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }
}
