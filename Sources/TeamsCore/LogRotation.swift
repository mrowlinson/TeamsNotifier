import Foundation

/// Log-file rotation policy: cap ~/Library/Logs/TeamsNotifier.log at 2MB,
/// truncating to the last 500KB on launch. Pure helpers; Log.swift in the
/// app target applies them to the real file.
public enum LogRotation {
    public static let maxBytes = 2 * 1024 * 1024
    public static let keepBytes = 500 * 1024

    /// True when the file must be truncated (strictly over the cap).
    public static func needsRotation(fileSize: Int) -> Bool {
        fileSize > maxBytes
    }

    /// Byte offset where the kept tail starts for a file of this size.
    public static func truncationOffset(fileSize: Int) -> Int {
        max(0, fileSize - keepBytes)
    }

    /// The bytes that survive rotation: the last keepBytes of data.
    public static func rotatedTail(of data: Data) -> Data {
        guard data.count > keepBytes else { return data }
        return data.suffix(keepBytes)
    }
}
