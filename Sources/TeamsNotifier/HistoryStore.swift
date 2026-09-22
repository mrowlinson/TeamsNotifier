import Foundation
import TeamsCore

/// History store: one record per NOTIFIED message at
/// `~/Library/Application Support/TeamsNotifier/history.jsonl`.
/// LZMESH block-compressed on macOS 27+, plain JSONL elsewhere and
/// for legacy files (dual-read, migrate once on append).
/// Suppressed messages (muted, loud-chat no-mention, type/own/edit skips)
/// are never recorded.
///
/// Never faults: append/prune failures log at debug only, so the notify
/// path is never blocked or alarmed by history I/O.
public enum HistoryStore {
    public static var historyFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TeamsNotifier/history.jsonl")
    }

    /// Append one record synchronously (tiny write). Never throws.
    /// Compressed block store when the LZMESH codec is available
    /// (macOS 27+), else plain JSONL; legacy plain files migrate once.
    public static func append(
        sender: String, chat: String, threadID: String, text: String,
        date: Date = Date(), fileURL: URL? = nil
    ) {
        let url = fileURL ?? historyFileURL
        let r = HistoryBlockStore.append(
            HistoryRecord(timestamp: date, sender: sender, chat: chat,
                          threadID: threadID, text: text),
            to: url)
        switch r {
        case .compressed, .plain: break
        case .unsupported: Log.debug("history append skipped: unsupported file version")
        case .failed: Log.debug("history append failed")
        }
    }

    /// All records, oldest first. Reads compressed and legacy plain
    /// files (magic detection). Missing file -> []. Never throws.
    public static func readAll(fileURL: URL? = nil) -> [HistoryRecord] {
        HistoryBlockStore.readAll(from: fileURL ?? historyFileURL)
    }

    /// Enforce retention (10k entries + 30 days). Rewrites the file only
    /// when something was dropped. Missing file is a no-op. Never throws.
    public static func pruneIfNeeded(now: Date = Date(), fileURL: URL? = nil) {
        let url = fileURL ?? historyFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        // Compressed files prune block-granularly; plain falls through.
        switch HistoryBlockStore.prune(in: url, now: now) {
        case .pruned(let kept, let dropped, let blocks):
            Log.debug("history prune: removed \(dropped) records (\(blocks) blocks), kept \(kept)")
            return
        case .noChange: return
        case .notCompressed: break // plain path below
        case .unsupported: Log.debug("history prune skipped: unsupported file version"); return
        case .failed: Log.debug("history prune failed"); return
        }
        do {
            let data = try Data(contentsOf: url)
            let text = String(data: data, encoding: .utf8) ?? ""
            let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let nonBlank = rawLines.filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count
            let kept = MessageHistory.prune(MessageHistory.parse(text), now: now)
            let lines = kept.compactMap { MessageHistory.encode($0) }
            let out = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
            // Rewrite when records dropped (age/cap/corrupt) or when the
            // file is not yet canonical (stray blanks, missing newline).
            guard lines.count != nonBlank || out != text else { return }
            try out.write(to: url, atomically: true, encoding: .utf8)
            Log.debug("history prune: removed \(nonBlank - lines.count) of \(nonBlank), kept \(lines.count)")
        } catch {
            Log.debug("history prune failed: \(error)")
        }
    }

    /// Create the file (empty) when missing so Show-history always has
    /// something to open. Never throws.
    public static func ensureFileExists(fileURL: URL? = nil) {
        let url = fileURL ?? historyFileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
        } catch {
            Log.debug("history file create failed: \(error)")
        }
    }
}
