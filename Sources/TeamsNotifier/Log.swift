import Foundation
import TeamsCore

/// stderr + file logger. Every line goes to stderr (unchanged format) and
/// is appended to ~/Library/Logs/TeamsNotifier.log. Call setupFileLogging()
/// once at launch: creates dirs, applies the rotation guard (>2MB ->
/// truncate to last 500KB), opens the append handle.
public enum Log {
    nonisolated(unsafe) public static var verbose = false
    nonisolated(unsafe) private static var handle: FileHandle?
    private static let lock = NSLock()

    public static var logFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TeamsNotifier.log")
    }

    public static func setupFileLogging(fileURL: URL? = nil) {
        let url = fileURL ?? logFileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            fputs("[teamsnotifier:FAULT] log dir create failed: \(error)\n", stderr)
            return
        }
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           LogRotation.needsRotation(fileSize: size),
           let fh = try? FileHandle(forReadingFrom: url)
        {
            do {
                try fh.seek(toOffset: UInt64(LogRotation.truncationOffset(fileSize: size)))
                let tail = (try fh.readToEnd()) ?? Data()
                try fh.close()
                try tail.write(to: url, options: .atomic)
            } catch {
                fputs("[teamsnotifier:FAULT] log rotation failed: \(error)\n", stderr)
                try? fh.close()
            }
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        do {
            handle = try FileHandle(forWritingTo: url)
            try handle?.seekToEnd()
        } catch {
            handle = nil
            fputs("[teamsnotifier:FAULT] log file open failed: \(error)\n", stderr)
        }
    }

    /// Last n lines of the log file (for "Copy diagnostics"). Empty when
    /// the file is missing or undecodable.
    public static func lastLines(_ n: Int, fileURL: URL? = nil) -> [String] {
        guard n > 0 else { return [] }
        let url = fileURL ?? logFileURL
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return Array(lines.suffix(n))
    }

    private static func emit(_ line: String) {
        fputs(line + "\n", stderr)
        guard let data = (line + "\n").data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        try? handle?.write(contentsOf: data)
    }

    public static func info(_ msg: String) {
        emit("[teamsnotifier] \(msg)")
    }

    public static func debug(_ msg: String) {
        if verbose { emit("[teamsnotifier:debug] \(msg)") }
    }

    /// Loud failure: stderr + file + caller posts user-visible notification.
    public static func fault(_ msg: String) {
        emit("[teamsnotifier:FAULT] \(msg)")
    }
}
