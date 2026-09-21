import Foundation

/// Timestamped log line format. Pure; Log.swift renders through here so
/// every line (stderr + file) carries an ISO8601 prefix.
public enum LogFormat {
    /// `2026-09-21T12:34:56Z [teamsnotifier] hello`.
    /// Tag keeps its brackets, e.g. `[teamsnotifier:debug]`.
    /// Fresh formatter per call: ISO8601DateFormatter is not thread-safe
    /// and log volume is far too low to matter.
    public static func line(tag: String, message: String, date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return "\(f.string(from: date)) \(tag) \(message)"
    }
}
