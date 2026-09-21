import Foundation
import Testing
@testable import TeamsCore

@Suite("Message history")
struct MessageHistoryTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21-ish

    static func rec(_ ts: Date, _ i: Int = 0) -> HistoryRecord {
        HistoryRecord(timestamp: ts, sender: "S\(i)", chat: "C\(i)", threadID: "19:t\(i)", text: "hello \(i)")
    }

    // MARK: codec

    @Test func caps() {
        #expect(MessageHistory.maxEntries == 10_000)
        #expect(MessageHistory.retentionDays == 30)
        #expect(MessageHistory.retentionSeconds == 30 * 24 * 60 * 60)
    }

    @Test func roundTrip() {
        let r = HistoryRecord(
            timestamp: Self.now, sender: "Alice", chat: "Team Chat",
            threadID: "19:abc@thread", text: "héllo\nline2 \"quoted\" \\ slash")
        let line = MessageHistory.encode(r)
        #expect(line != nil)
        #expect(!(line!.contains("\n")))
        #expect(MessageHistory.decode(line: line!) == r)
    }

    @Test func jsonKeys() {
        let line = MessageHistory.encode(Self.rec(Self.now))!
        let obj = try! JSONSerialization.jsonObject(with: line.data(using: .utf8)!) as! [String: Any]
        #expect(Set(obj.keys) == ["timestamp", "sender", "chat", "threadID", "text"])
        #expect((obj["timestamp"] as! String).contains("2026-"))
    }

    @Test func decodeRejectsBadLines() {
        #expect(MessageHistory.decode(line: "") == nil)
        #expect(MessageHistory.decode(line: "   ") == nil)
        #expect(MessageHistory.decode(line: "not json") == nil)
        #expect(MessageHistory.decode(line: "{\"sender\":\"x\"}") == nil) // missing keys
    }

    @Test func parseSkipsBadLines() {
        let good1 = MessageHistory.encode(Self.rec(Self.now, 1))!
        let good2 = MessageHistory.encode(Self.rec(Self.now, 2))!
        let text = good1 + "\n" + "garbage{" + "\n\n" + good2 + "\n"
        let out = MessageHistory.parse(text)
        #expect(out.count == 2)
        #expect(out[0].sender == "S1")
        #expect(out[1].sender == "S2")
    }

    // MARK: age retention (30 days, inclusive boundary)

    @Test func keepsRecentDropsOld() {
        let day: TimeInterval = 24 * 60 * 60
        let recs = [
            Self.rec(Self.now.addingTimeInterval(-31 * day), 1),
            Self.rec(Self.now.addingTimeInterval(-29 * day), 2),
            Self.rec(Self.now, 3),
        ]
        let out = MessageHistory.prune(recs, now: Self.now)
        #expect(out.map(\.sender) == ["S2", "S3"])
    }

    @Test func ageBoundaryInclusive() {
        let cutoff = Self.now.addingTimeInterval(-MessageHistory.retentionSeconds)
        let recs = [
            Self.rec(cutoff.addingTimeInterval(-1), 1), // 1s too old: dropped
            Self.rec(cutoff, 2), // exactly 30d: kept
            Self.rec(cutoff.addingTimeInterval(1), 3),
        ]
        let out = MessageHistory.prune(recs, now: Self.now)
        #expect(out.map(\.sender) == ["S2", "S3"])
    }

    @Test func emptyInput() {
        #expect(MessageHistory.prune([], now: Self.now).isEmpty)
    }

    // MARK: count cap (10k, newest kept)

    @Test func exactlyAtCapKeepsAll() {
        let recs = (0 ..< MessageHistory.maxEntries).map { Self.rec(Self.now, $0) }
        #expect(MessageHistory.prune(recs, now: Self.now).count == MessageHistory.maxEntries)
    }

    @Test func overCapDropsOldest() {
        let n = MessageHistory.maxEntries
        let recs = (0 ..< n + 100).map {
            Self.rec(Self.now.addingTimeInterval(TimeInterval($0)), $0)
        }
        let out = MessageHistory.prune(recs, now: Self.now)
        #expect(out.count == n)
        #expect(out.first!.sender == "S100") // oldest 100 dropped
        #expect(out.last!.sender == "S\(n + 99)")
    }

    @Test func orderPreserved() {
        let recs = (0 ..< 5).map { Self.rec(Self.now.addingTimeInterval(TimeInterval($0)), $0) }
        let out = MessageHistory.prune(recs, now: Self.now)
        #expect(out.map(\.sender) == ["S0", "S1", "S2", "S3", "S4"])
    }

    // MARK: combined

    @Test func ageThenCap() {
        let day: TimeInterval = 24 * 60 * 60
        // 3 fresh + 2 old, cap 2 -> old dropped by age, then oldest fresh by cap.
        let recs = [
            Self.rec(Self.now.addingTimeInterval(-40 * day), 0),
            Self.rec(Self.now, 1),
            Self.rec(Self.now, 2),
            Self.rec(Self.now, 3),
            Self.rec(Self.now.addingTimeInterval(-40 * day), 4),
        ]
        let out = MessageHistory.prune(recs, now: Self.now, maxEntries: 2)
        #expect(out.map(\.sender) == ["S2", "S3"])
    }

    @Test func customParamsHonored() {
        let recs = (0 ..< 5).map { Self.rec(Self.now, $0) }
        #expect(MessageHistory.prune(recs, now: Self.now, maxEntries: 3).count == 3)
        // Zero retention keeps only records at/after now.
        #expect(MessageHistory.prune(recs, now: Self.now, retentionSeconds: 0).count == 5)
        let old = [Self.rec(Self.now.addingTimeInterval(-1), 0)]
        #expect(MessageHistory.prune(old, now: Self.now, retentionSeconds: 0).isEmpty)
    }
}
