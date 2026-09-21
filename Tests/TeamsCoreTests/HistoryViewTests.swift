import Foundation
import Testing
@testable import TeamsCore

@Suite("History view helpers")
struct HistoryViewTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    static func rec(_ i: Int, sender: String? = nil, chat: String? = nil, text: String? = nil, at: Date? = nil) -> HistoryRecord {
        HistoryRecord(
            timestamp: at ?? t0.addingTimeInterval(TimeInterval(i * 60)),
            sender: sender ?? "Sender\(i)", chat: chat ?? "Chat\(i)",
            threadID: "19:t\(i)", text: text ?? "message \(i)")
    }

    // MARK: sort (newest first)

    @Test func sortNewestFirst() {
        let recs = [Self.rec(0), Self.rec(2), Self.rec(1)]
        #expect(HistoryView.sortedNewestFirst(recs).map(\.sender) == ["Sender2", "Sender1", "Sender0"])
    }

    @Test func sortStableOnEqualTimestamps() {
        let recs = [Self.rec(0, at: Self.t0), Self.rec(1, at: Self.t0)]
        #expect(HistoryView.sortedNewestFirst(recs).map(\.sender) == ["Sender0", "Sender1"])
    }

    // MARK: cap

    @Test func capLimit() {
        #expect(HistoryView.maxRows == 2_000)
        let recs = (0 ..< 2_500).map { Self.rec($0) }
        let (rows, truncated) = HistoryView.capped(HistoryView.sortedNewestFirst(recs))
        #expect(rows.count == 2_000)
        #expect(truncated)
        #expect(rows.first!.sender == "Sender2499") // newest kept
    }

    @Test func capUnderLimitNotTruncated() {
        let recs = [Self.rec(0)]
        let (rows, truncated) = HistoryView.capped(recs)
        #expect(rows.count == 1)
        #expect(!truncated)
    }

    // MARK: filter

    @Test func filterBlankQueryReturnsAll() {
        let recs = [Self.rec(0), Self.rec(1)]
        #expect(HistoryView.filter(recs, query: "").count == 2)
        #expect(HistoryView.filter(recs, query: "   ").count == 2)
    }

    @Test func filterMatchesSenderChatText() {
        let recs = [
            Self.rec(0, sender: "Alice", chat: "General", text: "hello"),
            Self.rec(1, sender: "Bob", chat: "Random", text: "world"),
        ]
        #expect(HistoryView.filter(recs, query: "ali").map(\.sender) == ["Alice"])
        #expect(HistoryView.filter(recs, query: "rand").map(\.sender) == ["Bob"])
        #expect(HistoryView.filter(recs, query: "WORLD").map(\.sender) == ["Bob"])
    }

    @Test func filterCaseInsensitiveSubstring() {
        let recs = [Self.rec(0, sender: "Café Owner", text: "deploy FRIDAY notes")]
        #expect(HistoryView.filter(recs, query: "café").count == 1)
        #expect(HistoryView.filter(recs, query: "day no").count == 1)
        #expect(HistoryView.filter(recs, query: "zzz").isEmpty)
    }

    // MARK: row formatting

    @Test func snippetCollapsesAndTruncates() {
        #expect(HistoryView.snippet("a\nb\t c") == "a b c")
        #expect(HistoryView.snippet("  ") == "")
        let long = String(repeating: "x", count: 200)
        let s = HistoryView.snippet(long)
        #expect(s.count == HistoryView.snippetLimit + 1)
        #expect(s.hasSuffix("…"))
        #expect(HistoryView.snippet("short") == "short")
    }

    @Test func formatTimeShape() {
        #expect(HistoryView.formatTime(Self.t0, timeZone: Self.utc) == "2026-09-21 14:13")
    }

    @Test func statusLine() {
        #expect(HistoryView.statusLine(shown: 0, total: 0, truncated: false) == "No notifications yet.")
        #expect(HistoryView.statusLine(shown: 1, total: 5, truncated: false) == "1 notification.")
        #expect(HistoryView.statusLine(shown: 3, total: 5, truncated: false) == "3 notifications.")
        #expect(HistoryView.statusLine(shown: 2000, total: 5000, truncated: true) == "Showing newest 2000 of 5000.")
    }
}
