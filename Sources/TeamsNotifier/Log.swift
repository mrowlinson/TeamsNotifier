import Foundation

/// Minimal stderr logger. Verbose gate set from --verbose.
public enum Log {
    nonisolated(unsafe) public static var verbose = false

    public static func info(_ msg: String) {
        fputs("[teamsnotifier] \(msg)\n", stderr)
    }

    public static func debug(_ msg: String) {
        if verbose { fputs("[teamsnotifier:debug] \(msg)\n", stderr) }
    }

    /// Loud failure: stderr + caller posts user-visible notification.
    public static func fault(_ msg: String) {
        fputs("[teamsnotifier:FAULT] \(msg)\n", stderr)
    }
}
