import Foundation
import Testing
@testable import TeamsCore

/// Missing-file + sign-in presence: existing installs that never wrote a
/// config file migrate owner schedule/rules (not blank); truly fresh
/// installs stay empty/blank/permissive.
@Suite("Missing-file migration hint")
struct MigrateFixTests {
    @Test func missingFileExistingInstallMigratesOwnerValues() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tn-migratefix-\(UUID().uuidString)")
        let path = dir.appendingPathComponent("config.json").path
        defer { try? FileManager.default.removeItem(at: dir) }

        let c = try Config.load(from: path, existingInstall: true)
        // Owner schedule migrated.
        #expect(c.muteWindows == MuteWindow.ownerSchedule)
        #expect(c.didMigrateSchedule == true)
        // 6 stock owner rules migrated (exact hardcoded legacy behavior).
        #expect(c.notifyRules.map(\.kind) == NotifyRule.knownKinds)
        #expect(c.notifyRules.count == 6)
        #expect(c.notifyRules.allSatisfy { $0.enabled })
        let byKind = Dictionary(uniqueKeysWithValues: c.notifyRules.map { ($0.kind, $0) })
        #expect(byKind[NotifyRule.noisyChats]?.value == "BTAC")
        #expect(byKind[NotifyRule.messageTypes]?.value == "Text, RichText")
        #expect(c.didMigrateRules == true)
        #expect(c.rulesStored == false)
        // Scalars reflect owner behavior (not permissive blank).
        #expect(c.skipOwnMessages == true)
        #expect(c.notifyOnEdit == false)
        #expect(c.loudSubstring == "BTAC")
        #expect(c.notifyTypes == ["Text", "RichText"])
        #expect(c.noisyChannelMentions == true)
        #expect(c.matchByDisplayName == true)
        // Persisted: second load finds stored keys (no re-migration).
        let stored = try String(contentsOfFile: path, encoding: .utf8)
        #expect(stored.contains("muteWindows"))
        #expect(stored.contains("notifyRules"))
        let second = try Config.load(from: path)
        #expect(second.muteWindows == MuteWindow.ownerSchedule)
        #expect(second.notifyRules == c.notifyRules)
        #expect(second.didMigrateSchedule == false)
        #expect(second.didMigrateRules == false)
    }

    @Test func missingFileFreshHintStaysEmptyBlankPermissive() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tn-migratefix-fresh-\(UUID().uuidString).json").path
        let c = try Config.load(from: missing, existingInstall: false)
        #expect(c.muteWindows.isEmpty)
        #expect(c.notifyRules.isEmpty)
        #expect(c.didMigrateSchedule == false)
        #expect(c.didMigrateRules == false)
        #expect(c.rulesStored == false)
        #expect(c.skipOwnMessages == false)
        #expect(c.notifyOnEdit == true)
        #expect(c.loudSubstring == "")
        #expect(c.notifyTypes == [NotifyRule.allowAllMarker])
        // Absent new-kind rules default ON (harmless: no noisy chats).
        #expect(c.noisyChannelMentions == true)
        #expect(c.matchByDisplayName == true)
        // Fresh load writes nothing.
        #expect(FileManager.default.fileExists(atPath: missing) == false)

        // Default hint is fresh too.
        let missing2 = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tn-migratefix-fresh2-\(UUID().uuidString).json").path
        let d = try Config.load(from: missing2)
        #expect(d.muteWindows.isEmpty)
        #expect(d.notifyRules.isEmpty)
        #expect(d.didMigrateSchedule == false)
        #expect(d.didMigrateRules == false)
        #expect(d.notifyTypes == [NotifyRule.allowAllMarker])
        #expect(FileManager.default.fileExists(atPath: missing2) == false)
    }
}
