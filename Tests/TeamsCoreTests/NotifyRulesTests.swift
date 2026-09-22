import Foundation
import Testing
@testable import TeamsCore

/// Notify rules: migration preserves legacy behavior exactly, fresh
/// installs stay blank, new (unknown) rule types round-trip.
@Suite("Notify rules")
struct NotifyRulesTests {
    let ownerMRI = "8:orgid:11111111-2222-3333-4444-555555555555"
    let ownerName = "Michael Rowlinson"

    func message(
        senderMRI: String? = "8:orgid:sender",
        senderName: String = "Alice",
        type: String = "RichText/Html",
        mentions: [Mention] = []
    ) -> EventMessage.Message {
        EventMessage.Message(
            chatID: "19:abc@thread.v2", messageID: "m1", senderMRI: senderMRI,
            senderName: senderName, content: "hello", messageType: type,
            threadTopic: nil, mentions: mentions, properties: [:], composeTime: nil
        )
    }

    /// Every ChatFilter gate exercised once: own, type, edit, loud+mention,
    /// loud bare, normal. Asserts identical decisions under both configs.
    func expectSameDecisions(_ a: Config, _ b: Config) {
        let ownerMention = [Mention(id: "0", mri: ownerMRI, mentionType: "person", displayName: ownerName)]
        let cases: [(EventMessage.Message, Bool, String)] = [
            (message(), false, "Alice"),
            (message(senderMRI: ownerMRI, senderName: ownerName), false, "Alice"),
            (message(type: "Control/Typing"), false, "Alice"),
            (message(), true, "Alice"),
            (message(), false, "BTAC War Room"),
            (message(mentions: ownerMention), false, "BTAC War Room"),
            (message(type: "Text"), false, "Alice"),
        ]
        for (m, isEdit, chat) in cases {
            let da = ChatFilter.decide(message: m, isEdit: isEdit, chatDisplayName: chat, ownerMRI: ownerMRI, config: a)
            let db = ChatFilter.decide(message: m, isEdit: isEdit, chatDisplayName: chat, ownerMRI: ownerMRI, config: b)
            #expect(da == db, "chat \(chat) edit=\(isEdit) type=\(m.messageType)")
        }
    }

    // MARK: (b) fresh installs blank

    @Test func freshConfigHasBlankRules() throws {
        #expect(Config().notifyRules.isEmpty)
        #expect(Config.default.notifyRules.isEmpty)
        #expect(Config.default.rulesStored == false)
        #expect(Config.default.didMigrateRules == false)
        let missing = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tn-rules-fresh-\(UUID().uuidString).json").path
        let c = try Config.load(from: missing)
        #expect(c.notifyRules.isEmpty)
        #expect(c.didMigrateRules == false)
        #expect(c.rulesStored == false)
        // Zero seeds: nothing rule-like anywhere in the fresh value.
        let encoded = String(data: try JSONEncoder().encode(c), encoding: .utf8)!
        #expect(encoded.contains("notifyRules") && c.notifyRules.isEmpty)
    }

    @Test func freshLoadFromMissingFileIsPermissive() throws {
        // Missing file = fresh install: blank rules must pair with
        // permissive scalars (blank = notify everything), matching the
        // stored-empty decode path (storedEmptyMeansPermissive).
        let missing = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tn-rules-fresh-perm-\(UUID().uuidString).json").path
        let c = try Config.load(from: missing)
        #expect(c.notifyRules.isEmpty)
        #expect(c.skipOwnMessages == false)
        #expect(c.notifyOnEdit == true)
        #expect(c.loudSubstring == "")
        #expect(c.notifyTypes == [NotifyRule.allowAllMarker])
        // Absent new-kind rules default ON (harmless: no noisy chats).
        #expect(c.noisyChannelMentions == true)
        #expect(c.matchByDisplayName == true)
        let d = ChatFilter.decide(
            message: message(), isEdit: false, chatDisplayName: "Alice",
            ownerMRI: ownerMRI, config: c)
        #expect(d == .notify(reason: "chat-message"))
    }

    // MARK: (a) existing-install preservation

    @Test func legacyDefaultsMigrateToStockRules() throws {
        // {} decodes with legacy defaults; migration must encode exactly
        // those, and decisions must match a stock Config() throughout.
        let migrated = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        #expect(migrated.didMigrateRules == true)
        #expect(migrated.rulesStored == false)
        let kinds = migrated.notifyRules.map(\.kind)
        #expect(kinds == NotifyRule.migratedKinds)
        let allOn = migrated.notifyRules.allSatisfy { $0.enabled }
        #expect(allOn)
        let loudValue = migrated.notifyRules.first(where: { $0.kind == NotifyRule.noisyChats })?.value
        #expect(loudValue == "BTAC")
        let typesValue = migrated.notifyRules.first(where: { $0.kind == NotifyRule.messageTypes })?.value
        #expect(typesValue == "Text, RichText")
        expectSameDecisions(migrated, Config())
    }

    @Test func legacyCustomScalarsPreservedExactly() throws {
        // Custom legacy settings migrate to rules encoding the same
        // effective behavior (skip-my-own-messages off, edits on, custom types/loud).
        let json = #"{"loudSubstring":"FOO","notifyOnEdit":true,"skipOwnMessages":false,"notifyTypes":["Text"]}"#
        let migrated = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(migrated.didMigrateRules == true)
        let byKind = Dictionary(uniqueKeysWithValues: migrated.notifyRules.map { ($0.kind, $0) })
        #expect(byKind[NotifyRule.skipMyMessages]?.enabled == false)
        #expect(byKind[NotifyRule.skipEdited]?.enabled == false)
        #expect(byKind[NotifyRule.messageTypes]?.value == "Text")
        #expect(byKind[NotifyRule.noisyChats]?.value == "FOO")
        var legacy = Config()
        legacy.loudSubstring = "FOO"
        legacy.notifyOnEdit = true
        legacy.skipOwnMessages = false
        legacy.notifyTypes = ["Text"]
        expectSameDecisions(migrated, legacy)
        // Scalars re-synced from the rules equal the legacy values.
        #expect(migrated.skipOwnMessages == false)
        #expect(migrated.notifyOnEdit == true)
        #expect(migrated.notifyTypes == ["Text"])
        #expect(migrated.loudSubstring == "FOO")
        #expect(migrated.noisyChannelMentions == true)
        #expect(migrated.matchByDisplayName == true)
    }

    @Test func migrationPersistsToStoreOnFirstLoad() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tn-rules-migrate-\(UUID().uuidString)")
        let path = dir.appendingPathComponent("config.json").path
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"owner":{"displayName":"N","upn":"","mri":""}}"#.write(
            toFile: path, atomically: true, encoding: .utf8)
        let first = try Config.load(from: path)
        let firstKinds = first.notifyRules.map(\.kind)
        #expect(firstKinds == NotifyRule.migratedKinds)
        #expect(first.didMigrateRules == true)
        let stored = try String(contentsOfFile: path, encoding: .utf8)
        #expect(stored.contains("notifyRules"))
        let second = try Config.load(from: path)
        #expect(second.notifyRules == first.notifyRules)
        #expect(second.didMigrateRules == false)
        #expect(second.rulesStored == true)
        expectSameDecisions(first, second)
    }

    // MARK: (c) new-rule add round-trips

    @Test func customKindRoundTripsUntouched() throws {
        var c = Config.default
        c.notifyRules = NotifyRule.migrate(skipOwn: true, notifyOnEdit: false, types: ["Text", "RichText"], loud: "BTAC")
        c.notifyRules.append(NotifyRule(kind: "my-future-rule", value: "x=1", enabled: false))
        c.rulesStored = true
        c.applyRules()
        var back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        #expect(back.notifyRules == c.notifyRules)
        #expect(back.rulesStored == true)
        let warnings = back.normalizeRules()
        #expect(warnings.isEmpty) // unknown kinds kept, no warnings
        #expect(back.notifyRules.contains(NotifyRule(kind: "my-future-rule", value: "x=1", enabled: false)))
        // Unknown rules are not enforced: decisions match without them.
        var without = c
        without.notifyRules.removeAll(where: { $0.kind == "my-future-rule" })
        without.applyRules()
        expectSameDecisions(back, without)
    }

    @Test func perRuleToggleRoundTrips() throws {
        var c = Config.default
        c.notifyRules = [
            NotifyRule(kind: NotifyRule.skipMyMessages, enabled: false),
            NotifyRule(kind: NotifyRule.noisyChats, value: "BTAC", enabled: false),
        ]
        c.rulesStored = true
        c.applyRules()
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        #expect(back.notifyRules == c.notifyRules)
        #expect(back.skipOwnMessages == false)
        #expect(back.loudSubstring == "")
    }

    // MARK: sync semantics

    @Test func storedEmptyMeansPermissive() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"notifyRules":[]}"#.utf8))
        #expect(c.rulesStored == true)
        #expect(c.skipOwnMessages == false)
        #expect(c.notifyOnEdit == true)
        #expect(c.loudSubstring == "")
        #expect(c.notifyTypes == ["*"])
        // Absent new-kind rules default ON (hardcoded pre-rules
        // behavior), yet everything still notifies: no noisy-chats rule
        // means no noisy chats exist for those gates to constrain.
        #expect(c.noisyChannelMentions == true)
        #expect(c.matchByDisplayName == true)
        // Everything notifies: own, edit, control type, bare loud chat.
        let cases: [(EventMessage.Message, Bool, String)] = [
            (message(senderMRI: ownerMRI, senderName: ownerName), false, "Alice"),
            (message(), true, "Alice"),
            (message(type: "Control/Typing"), false, "Alice"),
            (message(), false, "BTAC War Room"),
        ]
        for (m, isEdit, chat) in cases {
            let d = ChatFilter.decide(message: m, isEdit: isEdit, chatDisplayName: chat, ownerMRI: ownerMRI, config: c)
            if case .notify = d {} else { Issue.record("expected notify for \(chat) \(m.messageType)") }
        }
    }

    @Test func disabledRulesSwitchGatesOff() throws {
        var base = Config.default
        base.notifyRules = [
            NotifyRule(kind: NotifyRule.skipMyMessages, enabled: false),
            NotifyRule(kind: NotifyRule.messageTypes, value: "Text, RichText", enabled: false),
            NotifyRule(kind: NotifyRule.skipEdited, enabled: false),
            NotifyRule(kind: NotifyRule.noisyChats, value: "BTAC", enabled: false),
            NotifyRule(kind: NotifyRule.noisyChannel, enabled: false),
            NotifyRule(kind: NotifyRule.nameBackup, enabled: false),
        ]
        base.rulesStored = true
        base.applyRules()
        #expect(base.notifyTypes == ["*"])
        #expect(base.noisyChannelMentions == false)
        #expect(base.matchByDisplayName == false)
        let own = ChatFilter.decide(
            message: message(senderMRI: ownerMRI, senderName: ownerName),
            isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: base)
        #expect(own == .notify(reason: "chat-message"))
        let edit = ChatFilter.decide(
            message: message(), isEdit: true, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: base)
        #expect(edit == .notify(reason: "chat-message"))
        let ctrl = ChatFilter.decide(
            message: message(type: "Control/Typing"), isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: base)
        #expect(ctrl == .notify(reason: "chat-message"))
        let loud = ChatFilter.decide(
            message: message(), isEdit: false, chatDisplayName: "BTAC", ownerMRI: ownerMRI, config: base)
        #expect(loud == .notify(reason: "chat-message"))
    }

    @Test func wildcardAllowsEveryType() {
        var c = Config()
        c.notifyTypes = ["*"]
        for t in ["Text", "RichText/Html", "Control/Typing", "ThreadActivity/MemberJoined"] {
            let d = ChatFilter.decide(message: message(type: t), isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: c)
            #expect(d == .notify(reason: "chat-message"), "type \(t)")
        }
    }

    @Test func wildcardConfigRoundTripsStable() throws {
        var c = Config.default
        c.notifyRules = []
        c.rulesStored = true
        c.applyRules()
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        #expect(back.notifyRules.isEmpty)
        #expect(back.notifyTypes == ["*"])
        #expect(back.skipOwnMessages == false)
    }

    @Test func firstMatchWins() {
        var c = Config()
        c.notifyRules = [
            NotifyRule(kind: NotifyRule.skipMyMessages, enabled: false),
            NotifyRule(kind: NotifyRule.skipMyMessages, enabled: true),
        ]
        c.applyRules()
        #expect(c.skipOwnMessages == false)
    }

    // MARK: validation + tolerance

    @Test func ruleValidation() {
        #expect(NotifyRule(kind: NotifyRule.skipMyMessages).isValid)
        #expect(NotifyRule(kind: NotifyRule.skipEdited).isValid)
        #expect(NotifyRule(kind: NotifyRule.messageTypes, value: "Text").isValid)
        #expect(NotifyRule(kind: NotifyRule.noisyChats, value: "BTAC").isValid)
        #expect(NotifyRule(kind: NotifyRule.noisyChannel).isValid)
        #expect(NotifyRule(kind: NotifyRule.nameBackup).isValid)
        #expect(NotifyRule(kind: NotifyRule.keywordAllow, value: "outage, urgent").isValid)
        #expect(NotifyRule(kind: NotifyRule.keywordBlock, value: "lunch").isValid)
        #expect(NotifyRule(kind: "anything-new").isValid)
        #expect(NotifyRule(kind: "anything-new", value: "").isValid)
        #expect(!NotifyRule(kind: "").isValid)
        #expect(!NotifyRule(kind: NotifyRule.messageTypes, value: "  ").isValid)
        #expect(!NotifyRule(kind: NotifyRule.noisyChats, value: "").isValid)
        #expect(!NotifyRule(kind: NotifyRule.keywordAllow, value: "  ").isValid)
        #expect(!NotifyRule(kind: NotifyRule.keywordBlock, value: "").isValid)
    }

    @Test func parseTypes() {
        #expect(NotifyRule.parseTypes("Text, RichText") == ["Text", "RichText"])
        #expect(NotifyRule.parseTypes("Text") == ["Text"])
        #expect(NotifyRule.parseTypes("a,,b") == ["a", "b"])
        #expect(NotifyRule.parseTypes("  ") == [])
    }

    @Test func undecodableRulesRemigrateWithWarning() throws {
        let json = #"{"notifyTypes":["Text"],"notifyRules":"nope"}"#
        var c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        let remigKinds = c.notifyRules.map(\.kind)
        #expect(remigKinds == NotifyRule.migratedKinds)
        let remigTypes = c.notifyRules.first(where: { $0.kind == NotifyRule.messageTypes })?.value
        #expect(remigTypes == "Text")
        let w = c.normalizeRules()
        #expect(w.count == 1)
        #expect(c.normalizeRules().isEmpty) // drains once
    }

    @Test func invalidKnownRulesDroppedWithWarning() throws {
        let json = #"{"notifyRules":[{"kind":"noisy-chats-mention-only","value":""},{"kind":"only-these-message-types","value":"Text"},{"kind":"","value":"x"}]}"#
        var c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        let w = c.normalizeRules()
        #expect(w.count == 2)
        #expect(c.notifyRules == [NotifyRule(kind: "only-these-message-types", value: "Text")])
    }

    @Test func enabledDefaultsTrueWhenMissing() throws {
        let json = #"{"notifyRules":[{"kind":"skip-my-own-messages"}]}"#
        let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(c.notifyRules == [NotifyRule(kind: "skip-my-own-messages", value: "", enabled: true)])
    }

    @Test func migratedScalarsMatchLegacyFills() throws {
        // Legacy blanks filled exactly like Config.load did: loud "" ->
        // BTAC, types [] -> Text/RichText (in the migrated rules).
        let json = #"{"loudSubstring":"","notifyTypes":[]}"#
        let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        let fillLoud = c.notifyRules.first(where: { $0.kind == NotifyRule.noisyChats })?.value
        #expect(fillLoud == "BTAC")
        let fillTypes = c.notifyRules.first(where: { $0.kind == NotifyRule.messageTypes })?.value
        #expect(fillTypes == "Text, RichText")
    }
}
