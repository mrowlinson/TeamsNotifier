import Foundation

/// Pure helpers for the history viewer window: sort, cap, filter, and
/// row formatting. File I/O lives in HistoryStore (app target); the
/// AppKit window lives in HistoryWindowController (app target).
public enum HistoryView {
    /// Max rows rendered in the window (newest first). File keeps 10k.
    public static let maxRows = 2_000
    public static let snippetLimit = 120

    /// Newest first. Stable for equal timestamps.
    public static func sortedNewestFirst(_ records: [HistoryRecord]) -> [HistoryRecord] {
        records.enumerated()
            .sorted { a, b in
                if a.element.timestamp != b.element.timestamp {
                    return a.element.timestamp > b.element.timestamp
                }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    /// Cap at `limit` rows (input must already be newest-first).
    /// Returns the rows plus whether older rows were dropped.
    public static func capped(
        _ records: [HistoryRecord], limit: Int = maxRows
    ) -> (rows: [HistoryRecord], truncated: Bool) {
        guard records.count > limit else { return (records, false) }
        return (Array(records.prefix(limit)), true)
    }

    /// Case-insensitive substring filter over sender/chat/text.
    /// Blank query returns the input unchanged.
    public static func filter(_ records: [HistoryRecord], query: String) -> [HistoryRecord] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return records }
        return records.filter {
            $0.sender.lowercased().contains(q)
                || $0.chat.lowercased().contains(q)
                || $0.text.lowercased().contains(q)
        }
    }

    /// Single-line snippet: whitespace runs collapse to one space,
    /// cut at `limit` chars with a trailing … when longer.
    public static func snippet(_ text: String, limit: Int = snippetLimit) -> String {
        let flat = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)) + "…"
    }

    /// Row time string, fixed shape `yyyy-MM-dd HH:mm` (24h).
    /// Time zone defaults to current; tests pin UTC.
    public static func formatTime(
        _ date: Date,
        timeZone: TimeZone = TimeZone.current,
        locale: Locale = Locale(identifier: "en_US_POSIX")
    ) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    /// Status line for the window footer.
    public static func statusLine(shown: Int, total: Int, truncated: Bool) -> String {
        if total == 0 { return "No notifications yet." }
        if truncated { return "Showing newest \(shown) of \(total)." }
        return shown == 1 ? "1 notification." : "\(shown) notifications."
    }
}
