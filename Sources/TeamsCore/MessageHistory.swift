import Foundation

/// One notified message, stored as one JSON line in
/// `~/Library/Application Support/TeamsNotifier/history.jsonl`.
/// Notified only: muted / filter-suppressed messages are never recorded.
public struct HistoryRecord: Codable, Sendable, Equatable {
    public var timestamp: Date
    public var sender: String
    public var chat: String
    public var threadID: String
    public var text: String

    public init(timestamp: Date = Date(), sender: String, chat: String, threadID: String, text: String) {
        self.timestamp = timestamp
        self.sender = sender
        self.chat = chat
        self.threadID = threadID
        self.text = text
    }
}

/// Retention policy + JSONL codec. Pure; file I/O lives in HistoryStore
/// (app target). Caps: 10k entries + 30 days, oldest dropped first.
public enum MessageHistory {
    public static let maxEntries = 10_000
    public static let retentionDays = 30
    public static let retentionSeconds: TimeInterval = 30 * 24 * 60 * 60

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Encode one record as a single JSON line (no trailing newline).
    /// Nil only when the record cannot encode (never for plain strings).
    public static func encode(_ record: HistoryRecord) -> String? {
        guard let data = try? encoder.encode(record) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode one JSON line. Nil for blank or corrupt lines.
    public static func decode(line: String) -> HistoryRecord? {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let data = t.data(using: .utf8) else { return nil }
        return try? decoder.decode(HistoryRecord.self, from: data)
    }

    /// Decode file text, skipping blank/corrupt lines (they are dropped by
    /// the next prune rewrite).
    public static func parse(_ text: String) -> [HistoryRecord] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap {
            decode(line: String($0))
        }
    }

    /// Apply retention: drop records older than `retentionSeconds`, then
    /// keep the newest `maxEntries`. Order preserved (oldest first).
    /// Age boundary is inclusive: exactly `now - retention` is kept.
    public static func prune(
        _ records: [HistoryRecord],
        now: Date = Date(),
        maxEntries: Int = maxEntries,
        retentionSeconds: TimeInterval = retentionSeconds
    ) -> [HistoryRecord] {
        let cutoff = now.addingTimeInterval(-retentionSeconds)
        let fresh = records.filter { $0.timestamp >= cutoff }
        guard fresh.count > maxEntries else { return fresh }
        return Array(fresh.suffix(maxEntries))
    }
}
