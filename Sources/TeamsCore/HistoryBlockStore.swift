import Compression
import Foundation

/// One-shot LZMESH codec for the history block store.
///
/// LZMESH (0xE05, macOS 27+) is Apple's zlib replacement: faster with a
/// better ratio. Like LZBITMAP it is BUFFER-only (no random access), so
/// random access comes from the block layout in `HistoryBlockStore`,
/// not from the codec. Single codec on purpose: one code path, one
/// format, older macOS keeps the proven plain-JSONL path.
public enum HistoryCodec {
    /// Raw `compression_algorithm` value recorded in the file header.
    public static let lzmeshID: UInt32 = 0xE05

    /// Injectable VERSION GATE. Nil = real check (`macOS 27+`).
    /// Tests pin this both ways; production never sets it.
    nonisolated(unsafe) public static var availabilityOverride: Bool? = nil

    /// True when LZMESH may be used. macOS without the codec ->
    /// callers keep plain JSONL and never compress.
    public static var isAvailable: Bool {
        if let o = availabilityOverride { return o }
        if #available(macOS 27, *) { return true }
        return false
    }

    /// One-shot compress. Nil when the codec is unavailable, the input
    /// is empty, or encoding fails.
    public static func compress(_ data: Data) -> Data? {
        guard isAvailable, !data.isEmpty else { return nil }
        return data.withUnsafeBytes { src -> Data? in
            guard let base = src.baseAddress else { return nil }
            let scratchSize = compression_encode_scratch_buffer_size(COMPRESSION_LZMESH)
            let scratch = UnsafeMutableRawBufferPointer.allocate(
                byteCount: max(scratchSize, 1), alignment: 8)
            defer { scratch.deallocate() }
            // Generous one-shot destination (2x + slack): encode fails
            // rather than grow, and tiny blocks never need a retry loop.
            let dstSize = max(data.count * 2 + 256, 1024)
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstSize)
            defer { dst.deallocate() }
            let n = compression_encode_buffer(
                dst, dstSize, base.assumingMemoryBound(to: UInt8.self),
                data.count, scratch.baseAddress, COMPRESSION_LZMESH)
            guard n > 0 else { return nil }
            return Data(bytes: dst, count: n)
        }
    }

    /// One-shot decompress. The caller-stored `uncompressedSize` must
    /// match exactly (free integrity check). Nil when the codec is
    /// unavailable, the id is unknown, or decoding fails.
    public static func decompress(
        _ data: Data, uncompressedSize: Int, codecID: UInt32
    ) -> Data? {
        guard codecID == lzmeshID, isAvailable,
              !data.isEmpty, uncompressedSize > 0
        else { return nil }
        return data.withUnsafeBytes { src -> Data? in
            guard let base = src.baseAddress else { return nil }
            let scratchSize = compression_decode_scratch_buffer_size(COMPRESSION_LZMESH)
            let scratch = UnsafeMutableRawBufferPointer.allocate(
                byteCount: max(scratchSize, 1), alignment: 8)
            defer { scratch.deallocate() }
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: uncompressedSize)
            defer { dst.deallocate() }
            let n = compression_decode_buffer(
                dst, uncompressedSize, base.assumingMemoryBound(to: UInt8.self),
                data.count, scratch.baseAddress, COMPRESSION_LZMESH)
            guard n == uncompressedSize else { return nil }
            return Data(bytes: dst, count: n)
        }
    }
}

/// Blocked history file with magic header + per-block LZMESH frames.
///
/// Layout (all integers big-endian):
/// - header (12B): magic `"TNHC"` + u16 version (1) + u32 codec id +
///   u16 records-per-block capacity
/// - frames: u32 payloadLen + u32 recordCount + u64 newest-timestamp
///   (`Double.bitPattern`, exact) + u32 uncompressedLen + payload
/// - payload: `recordCount` JSON lines joined by `\n` (same codec as
///   `MessageHistory`), compressed as one buffer
///
/// Properties: frames are self-delimiting, so appends touch only the
/// tail (rewrite tail frame or append a new frame), reads decompress
/// only the blocks they need (headers scan without decoding), and
/// retention prune drops leading whole blocks by header timestamps.
/// Detection is by magic bytes, never filename. Legacy plain JSONL
/// reads on the same path (dual-read); the first compressed append
/// migrates a plain file once, atomically.
public enum HistoryBlockStore {
    public static let magic = Data([0x54, 0x4E, 0x48, 0x43]) // "TNHC"
    public static let version: UInt16 = 1
    public static let defaultBlockCapacity = 64
    public static let headerSize = 12
    public static let frameHeaderSize = 20

    /// One frame header from a header-only scan (no decompression).
    public struct Frame: Sendable {
        /// Byte offset of this frame's header in the file.
        public let offset: Int
        public let payloadLength: Int
        public let recordCount: Int
        /// Newest record timestamp as `Double.bitPattern`.
        public let newestBits: UInt64
        public let uncompressedLength: Int
        public var totalLength: Int { HistoryBlockStore.frameHeaderSize + payloadLength }
    }

    /// Header-only scan of a compressed file (no payload decoded).
    public struct Scan: Sendable {
        public let frames: [Frame]
        public let codecID: UInt32
        public let blockCapacity: Int
        /// False when magic matches but the version is unknown.
        public let supported: Bool
        /// True when trailing bytes are incomplete/corrupt.
        public let truncated: Bool
        public var totalRecords: Int { frames.reduce(0) { $0 + $1.recordCount } }
    }

    public enum AppendResult: Sendable {
        case compressed(blocks: Int)
        case plain
        case unsupported
        case failed
    }

    public enum PruneResult: Sendable, Equatable {
        case pruned(kept: Int, droppedRecords: Int, droppedBlocks: Int)
        case noChange(records: Int)
        case notCompressed
        case unsupported
        case failed
    }

    // MARK: scan

    /// True when the bytes start with the compressed-file magic.
    /// Version is NOT checked here; `scan` reports support.
    public static func isCompressedFile(prefix: Data) -> Bool {
        prefix.count >= magic.count && prefix.prefix(magic.count) == magic
    }

    /// Scan frame headers without decoding any payload.
    /// Nil = not a compressed file (plain JSONL or empty).
    public static func scan(_ data: Data) -> Scan? {
        guard isCompressedFile(prefix: data), data.count >= headerSize else { return nil }
        let ver = readU16(data, at: 4)
        let codec = readU32(data, at: 6)
        let cap = Int(readU16(data, at: 10))
        guard ver == version else {
            return Scan(frames: [], codecID: codec, blockCapacity: cap,
                        supported: false, truncated: false)
        }
        var frames: [Frame] = []
        var off = headerSize
        var truncated = false
        while off < data.count {
            guard off + frameHeaderSize <= data.count else { truncated = true; break }
            let plen = Int(readU32(data, at: off))
            let rc = Int(readU32(data, at: off + 4))
            let bits = readU64(data, at: off + 8)
            let ulen = Int(readU32(data, at: off + 16))
            guard plen > 0, rc > 0, ulen > 0,
                  off + frameHeaderSize + plen <= data.count
            else { truncated = true; break }
            frames.append(Frame(offset: off, payloadLength: plen, recordCount: rc,
                                newestBits: bits, uncompressedLength: ulen))
            off += frameHeaderSize + plen
        }
        return Scan(frames: frames, codecID: codec,
                    blockCapacity: max(cap, 1), supported: true, truncated: truncated)
    }

    // MARK: read (dual-read: compressed + legacy plain)

    /// All records, oldest first. Missing/unreadable file -> [].
    /// Plain JSONL (legacy) and compressed both read here.
    public static func readAll(from url: URL) -> [HistoryRecord] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        guard let s = scan(data) else {
            return MessageHistory.parse(String(data: data, encoding: .utf8) ?? "")
        }
        guard s.supported else { return [] }
        var out: [HistoryRecord] = []
        out.reserveCapacity(s.totalRecords)
        for f in s.frames {
            guard let recs = decodeFrame(f, in: data, codecID: s.codecID) else { break }
            out.append(contentsOf: recs)
        }
        return out
    }

    /// Newest `limit` records (oldest first) decompressing only the
    /// tail blocks that cover them. Returns the records plus how many
    /// blocks were decoded vs total (plain files report 0/0).
    public static func readRecent(
        limit: Int, from url: URL
    ) -> (records: [HistoryRecord], blocksRead: Int, blocksTotal: Int) {
        guard limit > 0 else { return ([], 0, 0) }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return ([], 0, 0) }
        guard let s = scan(data) else {
            let all = MessageHistory.parse(String(data: data, encoding: .utf8) ?? "")
            return (Array(all.suffix(limit)), 0, 0)
        }
        guard s.supported else { return ([], 0, s.frames.count) }
        // Walk tail frames until `limit` covered; decode those only.
        var need = limit
        var picked: [Frame] = []
        for f in s.frames.reversed() {
            picked.append(f)
            need -= f.recordCount
            if need <= 0 { break }
        }
        var out: [HistoryRecord] = []
        for f in picked.reversed() {
            guard let recs = decodeFrame(f, in: data, codecID: s.codecID) else { break }
            out.append(contentsOf: recs)
        }
        return (Array(out.suffix(limit)), picked.count, s.frames.count)
    }

    // MARK: append (dual-write + one-time plain migration)

    /// Append one record. Compressed file -> tail-frame rewrite or new
    /// frame (prefix bytes untouched). Plain file -> migrate to
    /// compressed once (codec available) or plain line append.
    /// Codec unavailable -> always plain. Never throws.
    @discardableResult
    public static func append(
        _ record: HistoryRecord, to url: URL,
        blockCapacity: Int = defaultBlockCapacity
    ) -> AppendResult {
        guard let line = MessageHistory.encode(record) else { return .failed }
        let cap = max(blockCapacity, 1)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch { return .failed }

        let existing = (try? Data(contentsOf: url)) ?? Data()
        // New/empty file.
        if existing.isEmpty {
            if HistoryCodec.isAvailable {
                var d = header(codecID: HistoryCodec.lzmeshID, capacity: cap)
                guard let frame = encodeFrame(lines: [line], timestampBits: newestBits([record])) else {
                    return .failed
                }
                d.append(frame)
                return writeAtomically(d, to: url) ? .compressed(blocks: 1) : .failed
            }
            return writeAtomically(Data((line + "\n").utf8), to: url) ? .plain : .failed
        }
        // Legacy plain file.
        guard let s = scan(existing) else {
            if HistoryCodec.isAvailable {
                var recs = MessageHistory.parse(String(data: existing, encoding: .utf8) ?? "")
                recs.append(record)
                return migrate(records: recs, to: url, capacity: cap)
            }
            return appendPlain(line: line, to: url) ? .plain : .failed
        }
        guard s.supported else { return .unsupported }
        // Corrupt tail -> salvage decodable frames + record, rewrite once.
        if s.truncated || s.frames.isEmpty {
            var recs: [HistoryRecord] = []
            for f in s.frames {
                guard let r = decodeFrame(f, in: existing, codecID: s.codecID) else { break }
                recs.append(contentsOf: r)
            }
            recs.append(record)
            return migrate(records: recs, to: url, capacity: s.blockCapacity)
        }
        let effCap = s.blockCapacity
        let tail = s.frames.last!
        if tail.recordCount < effCap {
            // Rewrite ONLY the tail frame in place (truncate + write).
            guard let oldLines = decodeFrameLines(tail, in: existing, codecID: s.codecID) else {
                // Tail undecodable -> preserve it, append fresh frame.
                return appendFrame(lines: [line], timestampBits: newestBits([record]),
                                   codecID: s.codecID, to: url,
                                   totalBlocks: s.frames.count + 1)
            }
            var lines = oldLines
            lines.append(line)
            let recBits = record.timestamp.timeIntervalSince1970.bitPattern
            let bits = Double(bitPattern: tail.newestBits) >= Double(bitPattern: recBits)
                ? tail.newestBits : recBits
            guard let frame = encodeFrame(lines: lines, timestampBits: bits) else {
                return appendFrame(lines: [line], timestampBits: newestBits([record]),
                                   codecID: s.codecID, to: url,
                                   totalBlocks: s.frames.count + 1)
            }
            do {
                let fh = try FileHandle(forUpdating: url)
                defer { try? fh.close() }
                try fh.truncate(atOffset: UInt64(tail.offset))
                try fh.seekToEnd()
                try fh.write(contentsOf: frame)
                return .compressed(blocks: s.frames.count)
            } catch { return .failed }
        }
        // Tail full -> pure append of a new frame.
        return appendFrame(lines: [line], timestampBits: newestBits([record]),
                           codecID: s.codecID, to: url, totalBlocks: s.frames.count + 1)
    }

    // MARK: prune (block-granular, no full decompress)

    /// Retention prune on a compressed file: drop leading whole blocks
    /// by header timestamps (no decoding), then whole blocks over the
    /// count cap, then trim at most one boundary block (only it is
    /// decoded/re-encoded). Single rewrite, only when something was
    /// dropped. Plain files -> `.notCompressed` (caller owns them).
    public static func prune(
        in url: URL, now: Date = Date(),
        maxEntries: Int = MessageHistory.maxEntries,
        retentionSeconds: TimeInterval = MessageHistory.retentionSeconds
    ) -> PruneResult {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return .noChange(records: 0)
        }
        guard let s = scan(data) else { return .notCompressed }
        guard s.supported else { return .unsupported }
        if s.frames.isEmpty {
            // Bare header (or header + garbage) -> canonicalize once.
            if s.truncated {
                return rewrite(data: header(codecID: s.codecID, capacity: s.blockCapacity),
                               to: url, kept: 0, droppedRecords: 0, droppedBlocks: 0)
            }
            return .noChange(records: 0)
        }
        let cutoff = now.addingTimeInterval(-retentionSeconds).timeIntervalSince1970
        var dropLeading = 0
        // 1. Age: drop leading frames whose NEWEST record is stale
        // (inclusive boundary: newest == cutoff is kept).
        while dropLeading < s.frames.count,
              Double(bitPattern: s.frames[dropLeading].newestBits) < cutoff
        {
            dropLeading += 1
        }
        var kept = Array(s.frames.dropFirst(dropLeading))
        var keptCount = kept.reduce(0) { $0 + $1.recordCount }
        // 2. Count cap: drop leading whole frames while over cap.
        while kept.count > 1, keptCount - kept[0].recordCount >= maxEntries {
            keptCount -= kept[0].recordCount
            kept.removeFirst()
        }
        // 3. Partial boundary trim (at most one frame decoded).
        var trimmed: (frame: Data, records: Int)? = nil
        if keptCount > maxEntries, let first = kept.first {
            let drop = keptCount - maxEntries
            guard drop < first.recordCount,
                  let lines = decodeFrameLines(first, in: data, codecID: s.codecID),
                  lines.count == first.recordCount
            else { return .failed }
            let rest = Array(lines.dropFirst(drop))
            let recs = rest.compactMap { MessageHistory.decode(line: $0) }
            guard let frame = encodeFrame(
                lines: rest, timestampBits: recs.isEmpty ? first.newestBits : newestBits(recs))
            else { return .failed }
            trimmed = (frame, rest.count)
            kept.removeFirst()
            keptCount -= first.recordCount
        }
        let finalKept = keptCount + (trimmed?.records ?? 0)
        let droppedRecords = s.totalRecords - finalKept
        let droppedBlocks = s.frames.count - kept.count - (trimmed == nil ? 0 : 1)
        if dropLeading == 0, trimmed == nil, kept.count == s.frames.count, !s.truncated {
            return .noChange(records: finalKept)
        }
        var out = header(codecID: s.codecID, capacity: s.blockCapacity)
        if let t = trimmed { out.append(t.frame) }
        for f in kept {
            out.append(data[f.offset ..< f.offset + f.totalLength])
        }
        if writeAtomically(out, to: url) {
            return .pruned(kept: finalKept, droppedRecords: droppedRecords,
                           droppedBlocks: max(droppedBlocks, 0))
        }
        return .failed
    }

    // MARK: - frame codec

    static func decodeFrame(
        _ f: Frame, in data: Data, codecID: UInt32
    ) -> [HistoryRecord]? {
        guard let lines = decodeFrameLines(f, in: data, codecID: codecID),
              lines.count == f.recordCount
        else { return nil }
        let recs = lines.compactMap { MessageHistory.decode(line: $0) }
        return recs.count == f.recordCount ? recs : nil
    }

    static func decodeFrameLines(
        _ f: Frame, in data: Data, codecID: UInt32
    ) -> [String]? {
        let start = f.offset + frameHeaderSize
        guard start + f.payloadLength <= data.count else { return nil }
        let payload = data[start ..< start + f.payloadLength]
        guard let raw = HistoryCodec.decompress(
            Data(payload), uncompressedSize: f.uncompressedLength, codecID: codecID),
            let text = String(data: raw, encoding: .utf8)
        else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static func encodeFrame(lines: [String], timestampBits: UInt64) -> Data? {
        let raw = Data(lines.joined(separator: "\n").utf8)
        guard let payload = HistoryCodec.compress(raw) else { return nil }
        var d = Data()
        appendU32(&d, UInt32(payload.count))
        appendU32(&d, UInt32(lines.count))
        appendU64(&d, timestampBits)
        appendU32(&d, UInt32(raw.count))
        d.append(payload)
        return d
    }

    static func newestBits(_ records: [HistoryRecord]) -> UInt64 {
        records.map { $0.timestamp.timeIntervalSince1970.bitPattern }.max(by: {
            Double(bitPattern: $0) < Double(bitPattern: $1)
        }) ?? 0
    }

    // MARK: - file helpers

    static func header(codecID: UInt32, capacity: Int) -> Data {
        var d = Data()
        d.append(magic)
        appendU16(&d, version)
        appendU32(&d, codecID)
        appendU16(&d, UInt16(clamping: capacity))
        return d
    }

    static func migrate(records: [HistoryRecord], to url: URL, capacity: Int) -> AppendResult {
        let lines = records.compactMap { MessageHistory.encode($0) }
        var out = header(codecID: HistoryCodec.lzmeshID, capacity: capacity)
        var blocks = 0
        var i = 0
        // Reuse caller timestamps for exact newest-bits per block.
        while i < lines.count {
            let end = min(i + capacity, lines.count)
            let slice = Array(records[i ..< end])
            guard let frame = encodeFrame(
                lines: Array(lines[i ..< end]), timestampBits: newestBits(slice))
            else { return .failed }
            out.append(frame)
            blocks += 1
            i = end
        }
        return writeAtomically(out, to: url) ? .compressed(blocks: blocks) : .failed
    }

    static func appendFrame(
        lines: [String], timestampBits: UInt64, codecID: UInt32,
        to url: URL, totalBlocks: Int
    ) -> AppendResult {
        guard let frame = encodeFrame(lines: lines, timestampBits: timestampBits) else {
            return .failed
        }
        do {
            let fh = try FileHandle(forWritingTo: url)
            defer { try? fh.close() }
            try fh.seekToEnd()
            try fh.write(contentsOf: frame)
            return .compressed(blocks: totalBlocks)
        } catch { return .failed }
    }

    static func appendPlain(line: String, to url: URL) -> Bool {
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let fh = try FileHandle(forWritingTo: url)
            defer { try? fh.close() }
            try fh.seekToEnd()
            try fh.write(contentsOf: Data((line + "\n").utf8))
            return true
        } catch { return false }
    }

    static func writeAtomically(_ data: Data, to url: URL) -> Bool {
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch { return false }
    }

    static func rewrite(
        data: Data, to url: URL, kept: Int, droppedRecords: Int, droppedBlocks: Int
    ) -> PruneResult {
        writeAtomically(data, to: url)
            ? .pruned(kept: kept, droppedRecords: droppedRecords, droppedBlocks: droppedBlocks)
            : .failed
    }

    // MARK: - int codec (big-endian)

    static func readU16(_ d: Data, at o: Int) -> UInt16 {
        UInt16(d[o]) << 8 | UInt16(d[o + 1])
    }

    static func readU32(_ d: Data, at o: Int) -> UInt32 {
        UInt32(d[o]) << 24 | UInt32(d[o + 1]) << 16 | UInt32(d[o + 2]) << 8 | UInt32(d[o + 3])
    }

    static func readU64(_ d: Data, at o: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0 ..< 8 { v = (v << 8) | UInt64(d[o + i]) }
        return v
    }

    static func appendU16(_ d: inout Data, _ v: UInt16) {
        d.append(UInt8(v >> 8))
        d.append(UInt8(v & 0xFF))
    }

    static func appendU32(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8((v >> 24) & 0xFF))
        d.append(UInt8((v >> 16) & 0xFF))
        d.append(UInt8((v >> 8) & 0xFF))
        d.append(UInt8(v & 0xFF))
    }

    static func appendU64(_ d: inout Data, _ v: UInt64) {
        for i in stride(from: 56, through: 0, by: -8) {
            d.append(UInt8((v >> i) & 0xFF))
        }
    }
}
