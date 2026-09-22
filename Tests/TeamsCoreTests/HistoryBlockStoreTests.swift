import Foundation
import Testing
@testable import TeamsCore

/// Block-compressed history store (LZMESH + blocked layout).
/// Serialized: tests pin the shared codec-availability gate.
@Suite("History block store", .serialized)
struct HistoryBlockStoreTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21-ish

    static func rec(_ i: Int, ts: Date? = nil) -> HistoryRecord {
        HistoryRecord(timestamp: ts ?? now.addingTimeInterval(TimeInterval(i)),
                  sender: "S\(i)", chat: "C\(i)", threadID: "19:t\(i)",
                  text: "hello \(i) héllo")
    }

    static func freshURL() -> URL {
        FileManager.default.temporaryDirectory
        .appendingPathComponent("hist-\(UUID().uuidString).jsonl")
    }

    /// Pin the codec gate for one test; caller restores via defer.
    static func pinCodec(_ available: Bool) -> Bool? {
        let saved = HistoryCodec.availabilityOverride
        HistoryCodec.availabilityOverride = available
        return saved
    }

    // MARK: (a) round-trip

    @Test func roundTrip() throws {
        let saved = Self.pinCodec(true)
        defer { HistoryCodec.availabilityOverride = saved }
        let url = Self.freshURL()
        let sent = (0 ..< 25).map { Self.rec($0) }
        for r in sent { HistoryBlockStore.append(r, to: url, blockCapacity: 8) }
        #expect(HistoryBlockStore.readAll(from: url) == sent)
        let data = try Data(contentsOf: url)
        #expect(HistoryBlockStore.isCompressedFile(prefix: data))
        #expect(HistoryBlockStore.scan(data)!.frames.count == 4) // 8,8,8,1
    }

    // MARK: (b) append touches only the tail

    @Test func appendTouchesOnlyTail() throws {
        let saved = Self.pinCodec(true)
        defer { HistoryCodec.availabilityOverride = saved }
        let url = Self.freshURL()
        for i in 0 ..< 10 { HistoryBlockStore.append(Self.rec(i), to: url, blockCapacity: 4) }
        var before = try Data(contentsOf: url)
        var s = HistoryBlockStore.scan(before)!
        #expect(s.frames.count == 3) // 4,4,2
        // Tail rewrite (2 -> 3 records): prefix bytes identical.
        HistoryBlockStore.append(Self.rec(10), to: url, blockCapacity: 4)
        var after = try Data(contentsOf: url)
        s = HistoryBlockStore.scan(after)!
        #expect(s.frames.count == 3)
        let tailOff = s.frames[2].offset
        #expect(after.prefix(tailOff) == before.prefix(tailOff))
        #expect(HistoryBlockStore.readAll(from: url).count == 11)
        // Fill tail (3 -> 4), then new block: WHOLE old file is the prefix.
        HistoryBlockStore.append(Self.rec(11), to: url, blockCapacity: 4)
        before = try Data(contentsOf: url)
        #expect(HistoryBlockStore.scan(before)!.frames.count == 3)
        HistoryBlockStore.append(Self.rec(12), to: url, blockCapacity: 4)
        after = try Data(contentsOf: url)
        s = HistoryBlockStore.scan(after)!
        #expect(s.frames.count == 4)
        #expect(after.prefix(before.count) == before)
        #expect(HistoryBlockStore.readAll(from: url).map(\.sender).last == "S12")
    }

    // MARK: selective read decodes only needed blocks

    @Test func selectiveRead() throws {
        let saved = Self.pinCodec(true)
        defer { HistoryCodec.availabilityOverride = saved }
        let url = Self.freshURL()
        for i in 0 ..< 10 { HistoryBlockStore.append(Self.rec(i), to: url, blockCapacity: 4) }
        let r1 = HistoryBlockStore.readRecent(limit: 2, from: url)
        #expect(r1.blocksTotal == 3)
        #expect(r1.blocksRead == 1)
        #expect(r1.records.map(\.sender) == ["S8", "S9"])
        let r2 = HistoryBlockStore.readRecent(limit: 5, from: url)
        #expect(r2.blocksRead == 2)
        #expect(r2.records.map(\.sender) == ["S5", "S6", "S7", "S8", "S9"])
        #expect(HistoryBlockStore.readRecent(limit: 0, from: url).records.isEmpty)
    }

    // MARK: (c) legacy plain reads + one-time migration

    @Test func legacyPlainReads() throws {
        let saved = Self.pinCodec(true)
        defer { HistoryCodec.availabilityOverride = saved }
        let url = Self.freshURL()
        let lines = (0 ..< 5).map { MessageHistory.encode(Self.rec($0))! }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(HistoryBlockStore.readAll(from: url).map(\.sender)
            == ["S0", "S1", "S2", "S3", "S4"])
        let r = HistoryBlockStore.readRecent(limit: 2, from: url)
        #expect(r.records.map(\.sender) == ["S3", "S4"])
        #expect(r.blocksTotal == 0) // plain: no blocks
        // First compressed append migrates once; content preserved.
        HistoryBlockStore.append(Self.rec(5), to: url, blockCapacity: 4)
        let data = try Data(contentsOf: url)
        #expect(HistoryBlockStore.isCompressedFile(prefix: data))
        #expect(HistoryBlockStore.scan(data)!.frames.count == 2) // 4,2
        #expect(HistoryBlockStore.readAll(from: url).count == 6)
    }

    // MARK: (d) version gate, both ways

    @Test func gateOffStaysPlain() throws {
        let saved = Self.pinCodec(false)
        defer { HistoryCodec.availabilityOverride = saved }
        let url = Self.freshURL()
        #expect(HistoryCodec.isAvailable == false)
        HistoryBlockStore.append(Self.rec(0), to: url)
        HistoryBlockStore.append(Self.rec(1), to: url)
        let data = try Data(contentsOf: url)
        #expect(!HistoryBlockStore.isCompressedFile(prefix: data))
        let text = String(data: data, encoding: .utf8)!
        #expect(text.split(separator: "\n").count == 2)
        #expect(HistoryBlockStore.readAll(from: url).map(\.sender) == ["S0", "S1"])
    }

    @Test func gateOnCompresses() throws {
        let saved = Self.pinCodec(true)
        defer { HistoryCodec.availabilityOverride = saved }
        let url = Self.freshURL()
        #expect(HistoryCodec.isAvailable == true)
        HistoryBlockStore.append(Self.rec(0), to: url)
        let data = try Data(contentsOf: url)
        #expect(HistoryBlockStore.isCompressedFile(prefix: data))
        #expect(HistoryBlockStore.readAll(from: url).map(\.sender) == ["S0"])
    }

    // MARK: (e) prune on the compressed store

    @Test func pruneDropsStaleBlocks() throws {
        let saved = Self.pinCodec(true)
        defer { HistoryCodec.availabilityOverride = saved }
        let day: TimeInterval = 24 * 60 * 60
        let url = Self.freshURL()
        for i in 0 ..< 4 {
            HistoryBlockStore.append(Self.rec(i, ts: Self.now - 40 * day),
                                     to: url, blockCapacity: 4)
        }
        for i in 4 ..< 12 { HistoryBlockStore.append(Self.rec(i), to: url, blockCapacity: 4) }
        let prePrune = try Data(contentsOf: url)
        #expect(HistoryBlockStore.scan(prePrune)!.frames.count == 3)
        let r = HistoryBlockStore.prune(in: url, now: Self.now)
        #expect(r == .pruned(kept: 8, droppedRecords: 4, droppedBlocks: 1))
        let kept = HistoryBlockStore.readAll(from: url)
        #expect(kept.count == 8)
        #expect(kept.allSatisfy { $0.timestamp >= Self.now - 30 * day })
        // Second prune is a no-op (no rewrite).
        #expect(HistoryBlockStore.prune(in: url, now: Self.now) == .noChange(records: 8))
    }

    @Test func pruneEnforcesCountCap() throws {
        let saved = Self.pinCodec(true)
        defer { HistoryCodec.availabilityOverride = saved }
        let url = Self.freshURL()
        for i in 0 ..< 20 { HistoryBlockStore.append(Self.rec(i), to: url, blockCapacity: 4) }
        let r = HistoryBlockStore.prune(in: url, now: Self.now, maxEntries: 10)
        #expect(r == .pruned(kept: 10, droppedRecords: 10, droppedBlocks: 2))
        #expect(HistoryBlockStore.readAll(from: url).map(\.sender)
            == (10 ..< 20).map { "S\($0)" })
    }

    @Test func prunePlainIsNotCompressed() throws {
        let saved = Self.pinCodec(true)
        defer { HistoryCodec.availabilityOverride = saved }
        let url = Self.freshURL()
        try (MessageHistory.encode(Self.rec(0))! + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(HistoryBlockStore.prune(in: url, now: Self.now) == .notCompressed)
    }
}
