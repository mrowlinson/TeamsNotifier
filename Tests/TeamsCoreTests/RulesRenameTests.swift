import Foundation
import Testing
@testable import TeamsCore

/// Rules rename + newly exposed gates.
///
/// - (a) Pre-rename kind ids decode to the new rules with identical
///   behavior (owner file shape covered exactly).
/// - (b) Every exposed rule has enabled/disabled/absent behavior tests.
/// - (c) Audit completeness: the two newly exposed gates (noisy channel
///   mentions, display-name backup) are exercised at each call site.
@Suite("Rules rename")
struct RulesRenameTests {
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

    func ownerMention() -> Mention {
        Mention(id: "0", mri: ownerMRI, mentionType: "person", displayName: ownerName)
    }

    func nameOnlyOwnerMention() -> Mention {
        Mention(id: "0", mri: nil, displayName: ownerName)
    }

    func channelMention() -> Mention {
        Mention(id: "0", mri: nil, mentionType: "channel", displayName: "channel")
    }

    /// Stock owner rules (post-rename ids), enabled throughout.
    func stockRules() -> [NotifyRule] {
        NotifyRule.migrate(skipOwn: true, notifyOnEdit: false, types: ["Text", "RichText"], loud: "BTAC")
    }

    func config(rules: [NotifyRule]) -> Config {
        var c = Config.default
        c.notifyRules = rules
        c.rulesStored = true
        c.applyRules()
        return c
    }

    /// Decision matrix covering every gate: normal, own (MRI + name),
    /// type (text/control/member/call), edit, noisy bare, noisy + owner
    /// MRI mention, noisy + name-only mention, noisy + channel mention.
    func expectSameDecisions(_ a: Config, _ b: Config) {
        let cases: [(EventMessage.Message, Bool, String)] = [
            (message(), false, "Alice"),
            (message(senderMRI: ownerMRI, senderName: ownerName), false, "Alice"),
            (message(senderMRI: nil, senderName: ownerName), false, "Alice"),
            (message(type: "Text"), false, "Alice"),
            (message(type: "Control/Typing"), false, "Alice"),
            (message(type: "ThreadActivity/MemberJoined"), false, "Alice"),
            (message(type: "Event/Call"), false, "Alice"),
            (message(), true, "Alice"),
            (message(), false, "BTAC War Room"),
            (message(mentions: [ownerMention()]), false, "BTAC War Room"),
            (message(mentions: [nameOnlyOwnerMention()]), false, "BTAC War Room"),
            (message(mentions: [channelMention()]), false, "BTAC War Room"),
        ]
        for (m, isEdit, chat) in cases {
            let da = ChatFilter.decide(message: m, isEdit: isEdit, chatDisplayName: chat, ownerMRI: ownerMRI, config: a)
            let db = ChatFilter.decide(message: m, isEdit: isEdit, chatDisplayName: chat, ownerMRI: ownerMRI, config: b)
            #expect(da == db, "chat \(chat) edit=\(isEdit) type=\(m.messageType) mentions=\(m.mentions)")
        }
    }

    // MARK: (a) old ids decode to new rules, behavior identical

    @Test func legacyMapCoversFourOldIDs() {
        #expect(NotifyRule.legacyKinds == [
            "skip-own": NotifyRule.skipMyMessages,
            "allow-types": NotifyRule.messageTypes,
            "skip-edits": NotifyRule.skipEdited,
            "loud-chat": NotifyRule.noisyChats,
        ])
        #expect(NotifyRule.canonicalKind("skip-own") == NotifyRule.skipMyMessages)
        #expect(NotifyRule.canonicalKind(NotifyRule.noisyChats) == NotifyRule.noisyChats)
        #expect(NotifyRule.canonicalKind("my-future-rule") == "my-future-rule")
        #expect(NotifyRule.canonicalKind("") == "")
        #expect(NotifyRule.knownKinds.count == 6)
    }

    @Test func oldKindsDecodeToNew() throws {
        let json = """
        {"notifyRules":[
        {"kind":"skip-own","enabled":true},
        {"kind":"allow-types","value":"Text, RichText","enabled":true},
        {"kind":"skip-edits","enabled":false},
        {"kind":"loud-chat","value":"BTAC","enabled":true}]}
        """
        let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(c.rulesStored == true)
        #expect(c.didMigrateRules == false)
        #expect(c.notifyRules.map(\.kind) == [
            NotifyRule.skipMyMessages, NotifyRule.messageTypes,
            NotifyRule.skipEdited, NotifyRule.noisyChats,
        ])
        // Payloads survive the remap.
        #expect(c.notifyRules[1].value == "Text, RichText")
        #expect(c.notifyRules[2].enabled == false)
        #expect(c.notifyRules[3].value == "BTAC")
        // Scalars resolve from the remapped rules (edits rule off).
        #expect(c.skipOwnMessages == true)
        #expect(c.notifyOnEdit == true)
        #expect(c.notifyTypes == ["Text", "RichText"])
        #expect(c.loudSubstring == "BTAC")
        // New gates absent in an old file: strict (IDs-only, owner-only).
        #expect(c.noisyChannelMentions == false)
        #expect(c.matchByDisplayName == false)
    }

    @Test func oldKindsBehaviorIdenticalToCanonical() throws {
        let oldJSON = """
        {"notifyRules":[
        {"kind":"skip-own","enabled":true},
        {"kind":"allow-types","value":"Text, RichText","enabled":true},
        {"kind":"skip-edits","enabled":true},
        {"kind":"loud-chat","value":"BTAC","enabled":true},
        {"kind":"noisy-chats-channel-mentions","enabled":true},
        {"kind":"my-name-as-backup","enabled":true}]}
        """
        let viaOld = try JSONDecoder().decode(Config.self, from: Data(oldJSON.utf8))
        let canonical = config(rules: stockRules())
        #expect(viaOld.notifyRules == canonical.notifyRules)
        expectSameDecisions(viaOld, canonical)
    }

    @Test func ownerFileShapeBehaviorUnchanged() throws {
        // Exact owner config shape (pre-rename ids, legacy scalars).
        let ownerJSON = """
        {"owner":{"mri":"","displayName":"Michael Rowlinson","upn":""},
        "notifyRules":[{"kind":"skip-own","value":"","enabled":true},
        {"kind":"allow-types","value":"Text, RichText","enabled":true},
        {"kind":"skip-edits","value":"","enabled":true},
        {"kind":"loud-chat","value":"BTAC","enabled":true}],
        "scheduleTZ":"America/New_York","skipOwnMessages":true,"muted":false,
        "notifyOnEdit":false,"loudSubstring":"BTAC",
        "muteWindows":[{"days":[2,3,4,5,6],"enabled":true,"start":"16:40","end":"24:00"}],
        "notifyTypes":["Text","RichText"]}
        """
        let loaded = try JSONDecoder().decode(Config.self, from: Data(ownerJSON.utf8))
        // Rules remapped; legacy scalars re-synced from them (unchanged).
        #expect(loaded.notifyRules.map(\.kind) == [
            NotifyRule.skipMyMessages, NotifyRule.messageTypes,
            NotifyRule.skipEdited, NotifyRule.noisyChats,
        ])
        #expect(loaded.skipOwnMessages == true)
        #expect(loaded.notifyOnEdit == false)
        #expect(loaded.loudSubstring == "BTAC")
        #expect(loaded.notifyTypes == ["Text", "RichText"])
        // Equivalent stock config decides identically throughout.
        var stock = Config.default
        stock.notifyRules = [
            NotifyRule(kind: NotifyRule.skipMyMessages, enabled: true),
            NotifyRule(kind: NotifyRule.messageTypes, value: "Text, RichText", enabled: true),
            NotifyRule(kind: NotifyRule.skipEdited, enabled: true),
            NotifyRule(kind: NotifyRule.noisyChats, value: "BTAC", enabled: true),
        ]
        stock.rulesStored = true
        stock.applyRules()
        expectSameDecisions(loaded, stock)
    }

    @Test func legacyKindsResolveInMemory() {
        // Programmatic legacy ids (never from decode) still hit the gate.
        var c = Config.default
        c.notifyRules = [
            NotifyRule(kind: "skip-own", enabled: true),
            NotifyRule(kind: "allow-types", value: "Text", enabled: true),
            NotifyRule(kind: "skip-edits", enabled: true),
            NotifyRule(kind: "loud-chat", value: "BTAC", enabled: true),
        ]
        c.rulesStored = true
        c.applyRules()
        #expect(c.skipOwnMessages == true)
        #expect(c.notifyTypes == ["Text"])
        #expect(c.notifyOnEdit == false)
        #expect(c.loudSubstring == "BTAC")
        // Mixed old/new: first match still wins.
        var m = Config.default
        m.notifyRules = [
            NotifyRule(kind: "skip-own", enabled: false),
            NotifyRule(kind: NotifyRule.skipMyMessages, enabled: true),
        ]
        m.applyRules()
        #expect(m.skipOwnMessages == false)
    }

    @Test func legacyValidatesAndHintsAsReplacement() {
        #expect(NotifyRule(kind: "skip-own").isValid)
        #expect(!NotifyRule(kind: "allow-types", value: " ").isValid)
        #expect(!NotifyRule(kind: "loud-chat", value: "").isValid)
        #expect(NotifyRule.hint(for: "loud-chat") == NotifyRule.hint(for: NotifyRule.noisyChats))
        #expect(NotifyRule.valuePlaceholder(for: "allow-types") == "Text, RichText")
    }

    // MARK: (b) every exposed rule has behavior tests

    @Test func skipMyMessagesGate() {
        let on = config(rules: [NotifyRule(kind: NotifyRule.skipMyMessages, enabled: true)])
        let off = config(rules: [NotifyRule(kind: NotifyRule.skipMyMessages, enabled: false)])
        let absent = config(rules: [])
        let own = message(senderMRI: ownerMRI, senderName: ownerName)
        #expect(ChatFilter.decide(message: own, isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: on) == .skip(reason: "own-message"))
        #expect(ChatFilter.decide(message: own, isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: off) == .notify(reason: "chat-message"))
        #expect(ChatFilter.decide(message: own, isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: absent) == .notify(reason: "chat-message"))
    }

    @Test func messageTypesGate() {
        let stock = config(rules: [NotifyRule(kind: NotifyRule.messageTypes, value: "Text, RichText", enabled: true)])
        // Stock value: typing, member-join, call heads stay silent.
        for t in ["Control/Typing", "ThreadActivity/MemberJoined", "Event/Call"] {
            let d = ChatFilter.decide(message: message(type: t), isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: stock)
            if case .skip = d {} else { Issue.record("expected skip for \(t)") }
        }
        for t in ["Text", "RichText/Html"] {
            let d = ChatFilter.decide(message: message(type: t), isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: stock)
            #expect(d == .notify(reason: "chat-message"), "type \(t)")
        }
        // Custom value narrows; disabled/absent opens everything.
        let custom = config(rules: [NotifyRule(kind: NotifyRule.messageTypes, value: "Text", enabled: true)])
        #expect(custom.notifyTypes == ["Text"])
        let off = config(rules: [NotifyRule(kind: NotifyRule.messageTypes, value: "Text", enabled: false)])
        #expect(off.notifyTypes == ["*"])
        let d = ChatFilter.decide(message: message(type: "Control/Typing"), isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: off)
        #expect(d == .notify(reason: "chat-message"))
    }

    @Test func skipEditedGate() {
        let on = config(rules: [NotifyRule(kind: NotifyRule.skipEdited, enabled: true)])
        let off = config(rules: [NotifyRule(kind: NotifyRule.skipEdited, enabled: false)])
        let absent = config(rules: [])
        #expect(ChatFilter.decide(message: message(), isEdit: true, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: on) == .skip(reason: "edit"))
        #expect(ChatFilter.decide(message: message(), isEdit: true, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: off) == .notify(reason: "chat-message"))
        #expect(ChatFilter.decide(message: message(), isEdit: true, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: absent) == .notify(reason: "chat-message"))
    }

    @Test func noisyChatsGate() {
        let on = config(rules: [
            NotifyRule(kind: NotifyRule.noisyChats, value: "BTAC", enabled: true),
            NotifyRule(kind: NotifyRule.noisyChannel, enabled: true),
            NotifyRule(kind: NotifyRule.nameBackup, enabled: true),
        ])
        let off = config(rules: [NotifyRule(kind: NotifyRule.noisyChats, value: "BTAC", enabled: false)])
        let absent = config(rules: [])
        #expect(ChatFilter.decide(message: message(), isEdit: false, chatDisplayName: "BTAC War Room", ownerMRI: ownerMRI, config: on) == .skip(reason: "loud-no-mention"))
        #expect(ChatFilter.decide(message: message(), isEdit: false, chatDisplayName: "BTAC War Room", ownerMRI: ownerMRI, config: off) == .notify(reason: "chat-message"))
        #expect(ChatFilter.decide(message: message(), isEdit: false, chatDisplayName: "BTAC War Room", ownerMRI: ownerMRI, config: absent) == .notify(reason: "chat-message"))
        // Blank value with the rule on still disables the match.
        let blank = config(rules: [NotifyRule(kind: NotifyRule.noisyChats, value: "  ", enabled: true)])
        #expect(blank.loudSubstring == "")
    }

    // MARK: (c) newly exposed gates

    @Test func noisyChannelGate() {
        func cfg(_ channel: NotifyRule?) -> Config {
            var rules = [NotifyRule(kind: NotifyRule.noisyChats, value: "BTAC", enabled: true)]
            if let channel { rules.append(channel) }
            return config(rules: rules)
        }
        let on = cfg(NotifyRule(kind: NotifyRule.noisyChannel, enabled: true))
        let off = cfg(NotifyRule(kind: NotifyRule.noisyChannel, enabled: false))
        let absent = cfg(nil)
        #expect(on.noisyChannelMentions == true)
        #expect(off.noisyChannelMentions == false)
        #expect(absent.noisyChannelMentions == false)
        let ch = message(mentions: [channelMention()])
        #expect(ChatFilter.decide(message: ch, isEdit: false, chatDisplayName: "BTAC", ownerMRI: ownerMRI, config: on) == .notify(reason: "loud-channel-mention"))
        #expect(ChatFilter.decide(message: ch, isEdit: false, chatDisplayName: "BTAC", ownerMRI: ownerMRI, config: off) == .skip(reason: "loud-no-mention"))
        #expect(ChatFilter.decide(message: ch, isEdit: false, chatDisplayName: "BTAC", ownerMRI: ownerMRI, config: absent) == .skip(reason: "loud-no-mention"))
        // Direct owner mention still notifies with the channel gate off.
        let own = message(mentions: [ownerMention()])
        #expect(ChatFilter.decide(message: own, isEdit: false, chatDisplayName: "BTAC", ownerMRI: ownerMRI, config: off) == .notify(reason: "loud-owner-mention"))
    }

    @Test func nameBackupGateMentionSite() {
        func cfg(_ backup: NotifyRule?) -> Config {
            var rules = [
                NotifyRule(kind: NotifyRule.noisyChats, value: "BTAC", enabled: true),
                NotifyRule(kind: NotifyRule.noisyChannel, enabled: true),
            ]
            if let backup { rules.append(backup) }
            return config(rules: rules)
        }
        let on = cfg(NotifyRule(kind: NotifyRule.nameBackup, enabled: true))
        let off = cfg(NotifyRule(kind: NotifyRule.nameBackup, enabled: false))
        let absent = cfg(nil)
        let named = message(mentions: [nameOnlyOwnerMention()])
        #expect(ChatFilter.decide(message: named, isEdit: false, chatDisplayName: "BTAC", ownerMRI: ownerMRI, config: on) == .notify(reason: "loud-owner-mention"))
        #expect(ChatFilter.decide(message: named, isEdit: false, chatDisplayName: "BTAC", ownerMRI: ownerMRI, config: off) == .skip(reason: "loud-no-mention"))
        #expect(ChatFilter.decide(message: named, isEdit: false, chatDisplayName: "BTAC", ownerMRI: ownerMRI, config: absent) == .skip(reason: "loud-no-mention"))
        // MRI mention still notifies with the backup off (IDs only).
        let mri = message(mentions: [ownerMention()])
        #expect(ChatFilter.decide(message: mri, isEdit: false, chatDisplayName: "BTAC", ownerMRI: ownerMRI, config: off) == .notify(reason: "loud-owner-mention"))
    }

    @Test func nameBackupGateOwnMessageSite() {
        func cfg(_ backup: NotifyRule?) -> Config {
            var rules = [NotifyRule(kind: NotifyRule.skipMyMessages, enabled: true)]
            if let backup { rules.append(backup) }
            return config(rules: rules)
        }
        let on = cfg(NotifyRule(kind: NotifyRule.nameBackup, enabled: true))
        let off = cfg(NotifyRule(kind: NotifyRule.nameBackup, enabled: false))
        let absent = cfg(nil)
        // Sender ID missing: name match skips only with the backup on.
        let nameless = message(senderMRI: nil, senderName: ownerName)
        #expect(ChatFilter.decide(message: nameless, isEdit: false, chatDisplayName: "Alice", ownerMRI: nil, config: on) == .skip(reason: "own-message"))
        #expect(ChatFilter.decide(message: nameless, isEdit: false, chatDisplayName: "Alice", ownerMRI: nil, config: off) == .notify(reason: "chat-message"))
        #expect(ChatFilter.decide(message: nameless, isEdit: false, chatDisplayName: "Alice", ownerMRI: nil, config: absent) == .notify(reason: "chat-message"))
        // MRI match still skips with the backup off.
        let mri = message(senderMRI: ownerMRI, senderName: ownerName)
        #expect(ChatFilter.decide(message: mri, isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: off) == .skip(reason: "own-message"))
        // Empty names never match, backup or not.
        let empty = message(senderMRI: nil, senderName: "")
        var noName = on
        noName.owner.displayName = ""
        #expect(ChatFilter.decide(message: empty, isEdit: false, chatDisplayName: "Alice", ownerMRI: nil, config: noName) == .notify(reason: "chat-message"))
    }

    @Test func strictMatchingKeepsMRIRefusals() {
        // MRI present but different: not owner even with backup on.
        let other = [Mention(id: "0", mri: "8:orgid:other", displayName: ownerName)]
        #expect(!Mentions.mentionsOwner(other, ownerMRI: ownerMRI, ownerDisplayName: ownerName, matchByName: true))
        #expect(!Mentions.mentionsOwner(other, ownerMRI: ownerMRI, ownerDisplayName: ownerName, matchByName: false))
        // Backup off + no owner MRI anywhere: nothing matches.
        let named = [nameOnlyOwnerMention()]
        #expect(!Mentions.mentionsOwner(named, ownerMRI: nil, ownerDisplayName: ownerName, matchByName: false))
        #expect(Mentions.mentionsOwner(named, ownerMRI: nil, ownerDisplayName: ownerName, matchByName: true))
    }

    @Test func freshBlankNotifiesThroughoutNewGates() {
        // Blank rules: every gate off; even name-only/channel cases notify
        // (no noisy chats exist to constrain them).
        let blank = config(rules: [])
        for m in [message(mentions: [nameOnlyOwnerMention()]), message(mentions: [channelMention()])] {
            let d = ChatFilter.decide(message: m, isEdit: false, chatDisplayName: "BTAC", ownerMRI: ownerMRI, config: blank)
            #expect(d == .notify(reason: "chat-message"))
        }
        let own = message(senderMRI: nil, senderName: ownerName)
        let d = ChatFilter.decide(message: own, isEdit: false, chatDisplayName: "Alice", ownerMRI: nil, config: blank)
        #expect(d == .notify(reason: "chat-message"))
    }

    // MARK: GUI chrome helpers

    @Test func valueChromePerKind() {
        #expect(NotifyRule.valueLabel(for: NotifyRule.messageTypes) == "Types:")
        #expect(NotifyRule.valueLabel(for: NotifyRule.noisyChats) == "Chat text:")
        #expect(NotifyRule.valueLabel(for: NotifyRule.skipMyMessages) == "Value:")
        #expect(NotifyRule.valueLabel(for: "custom") == "Value:")
        #expect(NotifyRule.valuePlaceholder(for: NotifyRule.messageTypes) == "Text, RichText")
        #expect(NotifyRule.valuePlaceholder(for: NotifyRule.noisyChats) == "BTAC")
        #expect(NotifyRule.valuePlaceholder(for: NotifyRule.skipEdited) == "(ignored)")
        #expect(NotifyRule.usesValue(NotifyRule.messageTypes))
        #expect(NotifyRule.usesValue(NotifyRule.noisyChats))
        #expect(!NotifyRule.usesValue(NotifyRule.skipMyMessages))
        #expect(!NotifyRule.usesValue(NotifyRule.skipEdited))
        #expect(!NotifyRule.usesValue(NotifyRule.noisyChannel))
        #expect(!NotifyRule.usesValue(NotifyRule.nameBackup))
        #expect(!NotifyRule.usesValue("custom"))
        // Every known kind has a specific hint (not the custom fallback).
        for k in NotifyRule.knownKinds {
            #expect(NotifyRule.hint(for: k) != "Custom type: stored and round-tripped, not enforced yet.")
        }
        #expect(NotifyRule.hint(for: "custom") == "Custom type: stored and round-tripped, not enforced yet.")
    }
}
