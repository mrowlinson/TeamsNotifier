import Foundation
import TeamsCore

/// JSONL history store: one line per NOTIFIED message at
/// `~/Library/Application Support/TeamsNotifier/history.jsonl`.
/// Suppressed messages (muted, loud-chat no-mention, type/own/edit skips)
/// are never recorded. Plaintext on disk (owner acknowledged).
///
/// Never faults: append/prune failures log at debug only, so the notify
/// path is never blocked or alarmed by history I/O.
public enum HistoryStore {
    public static var historyFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TeamsNotifier/history.jsonl")
    }

    /// Append one record synchronously (tiny write). Never throws.
    public static func append(
        sender: String, chat: String, threadID: String, text: String,
        date: Date = Date(), fileURL: URL? = nil
    ) {
        guard let line = MessageHistory.encode(HistoryRecord(
            timestamp: date, sender: sender, chat: chat, threadID: threadID, text: text
        )) else {
            Log.debug("history append skipped: encode failed")
            return
        }
        let url = fileURL ?? historyFileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let fh = try FileHandle(forWritingTo: url)
            defer { try? fh.close() }
            try fh.seekToEnd()
            if let data = (line + "\n").data(using: .utf8) {
                try fh.write(contentsOf: data)
            }
        } catch {
            Log.debug("history append failed: \(error)")
        }
    }

    /// Enforce retention (10k entries + 30 days). Rewrites the file only
    /// when something was dropped. Missing file is a no-op. Never throws.
    public static func pruneIfNeeded(now: Date = Date(), fileURL: URL? = nil) {
        let url = fileURL ?? historyFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
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
