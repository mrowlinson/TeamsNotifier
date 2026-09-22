import Foundation
import Testing
@testable import TeamsCore

/// Content keyword rules: allow words force NOTIFY through any filter
/// skip, block words force SKIP through any filter notify. Match is
/// case-insensitive SUBSTRING against the message plain text (HTML
/// stripped). Both yield to mute; block beats allow on one message.
@Suite("Keyword rules")
struct KeywordRulesTests {
    let ownerMRI = "8:orgid:11111111-2222-3333-4444-555555555555"
    let ownerName = "Alex Rivera"

    func message(
        senderMRI: String? = "8:orgid:sender",
        senderName: String = "Alice",
        content: String = "hello",
        type: String = "RichText/Html",
        mentions: [Mention] = []
    ) -> EventMessage.Message {
        EventMessage.Message(
            chatID: "19:abc@thread.v2", messageID: "m1", senderMRI: senderMRI,
            senderName: senderName, content: content, messageType: type,
            threadTopic: nil, mentions: mentions, properties: [:], composeTime: nil
        )
    }

    func config(rules: [NotifyRule]) -> Config {
        var c = Config.default
        c.notifyRules = rules
        c.rulesStored = true
        c.applyRules()
        return c
    }

    /// Stock noisy setup: loud Watercooler chat silences bare messages.
    func noisy() -> Config {
        config(rules: [
            NotifyRule(kind: NotifyRule.noisyChats, value: "Watercooler", enabled: true),
            NotifyRule(kind: NotifyRule.noisyChannel, enabled: true),
            NotifyRule(kind: NotifyRule.nameBackup, enabled: true),
        ])
    }

    // MARK: (a) allow through noisy silence

    @Test func allowWordThroughNoisySilenceNotifies() {
        let c = config(rules: [
            NotifyRule(kind: NotifyRule.noisyChats, value: "Watercooler", enabled: true),
            NotifyRule(kind: NotifyRule.keywordAllow, value: "outage, urgent", enabled: true),
        ])
        // Baseline: bare message in the noisy chat stays silent.
        #expect(ChatFilter.decide(message: message(), isEdit: false, chatDisplayName: "Watercooler Chat", ownerMRI: ownerMRI, config: noisy()) == .skip(reason: "loud-no-mention"))
        // Allow word forces notify through the noisy skip.
        let hit = message(content: "prod outage in us-east")
        #expect(ChatFilter.decide(message: hit, isEdit: false, chatDisplayName: "Watercooler Chat", ownerMRI: ownerMRI, config: c) == .notify(reason: "keyword-allow"))
    }

    // MARK: (b) allow through type + edit skips

    @Test func allowWordThroughTypeSkipNotifies() {
        let c = config(rules: [
            NotifyRule(kind: NotifyRule.messageTypes, value: "Text, RichText", enabled: true),
            NotifyRule(kind: NotifyRule.keywordAllow, value: "sev1", enabled: true),
        ])
        // Control type with no keyword still skips.
        #expect(ChatFilter.decide(message: message(type: "Control/Typing"), isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: c) == .skip(reason: "type:Control"))
        // Same type carrying the word notifies.
        let hit = message(content: "sev1 bridge open", type: "Control/Typing")
        #expect(ChatFilter.decide(message: hit, isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: c) == .notify(reason: "keyword-allow"))
    }

    @Test func allowWordThroughEditSkipNotifies() {
        let c = config(rules: [
            NotifyRule(kind: NotifyRule.skipEdited, enabled: true),
            NotifyRule(kind: NotifyRule.keywordAllow, value: "urgent", enabled: true),
        ])
        #expect(ChatFilter.decide(message: message(), isEdit: true, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: c) == .skip(reason: "edit"))
        let hit = message(content: "urgent fix, see edit")
        #expect(ChatFilter.decide(message: hit, isEdit: true, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: c) == .notify(reason: "keyword-allow"))
    }

    @Test func allowWordThroughOwnSkipNotifies() {
        // Allow forces through EVERY filter skip, own messages included.
        let c = config(rules: [
            NotifyRule(kind: NotifyRule.skipMyMessages, enabled: true),
            NotifyRule(kind: NotifyRule.keywordAllow, value: "outage", enabled: true),
        ])
        let own = message(senderMRI: ownerMRI, senderName: ownerName, content: "outage update from me")
        #expect(ChatFilter.decide(message: own, isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: c) == .notify(reason: "keyword-allow"))
    }

    // MARK: (c) block through plain notify

    @Test func blockWordThroughPlainNotifySkips() {
        let c = config(rules: [
            NotifyRule(kind: NotifyRule.keywordBlock, value: "lunch, kudos", enabled: true),
        ])
        #expect(ChatFilter.decide(message: message(), isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: c) == .notify(reason: "chat-message"))
        let hit = message(content: "who wants lunch?")
        #expect(ChatFilter.decide(message: hit, isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: c) == .skip(reason: "keyword-block"))
    }

    @Test func blockWordBeatsLoudMentionNotify() {
        // Block forces skip through a notify the noisy gate granted.
        let c = config(rules: [
            NotifyRule(kind: NotifyRule.noisyChats, value: "Watercooler", enabled: true),
            NotifyRule(kind: NotifyRule.keywordBlock, value: "kudos", enabled: true),
        ])
        let m = message(
            content: "kudos to the team",
            mentions: [Mention(id: "0", mri: ownerMRI, mentionType: "person", displayName: ownerName)])
        #expect(ChatFilter.decide(message: m, isEdit: false, chatDisplayName: "Watercooler", ownerMRI: ownerMRI, config: c) == .skip(reason: "keyword-block"))
    }

    // MARK: (d) block beats allow

    @Test func blockBeatsAllowSameMessage() {
        let c = config(rules: [
            NotifyRule(kind: NotifyRule.keywordAllow, value: "urgent", enabled: true),
            NotifyRule(kind: NotifyRule.keywordBlock, value: "lunch", enabled: true),
        ])
        let both = message(content: "urgent: lunch orders due")
        #expect(ChatFilter.decide(message: both, isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: c) == .skip(reason: "keyword-block"))
        // Either word alone still decides its own way.
        #expect(ChatFilter.decide(message: message(content: "urgent fix"), isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: c) == .notify(reason: "keyword-allow"))
        #expect(ChatFilter.decide(message: message(content: "lunch run"), isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: c) == .skip(reason: "keyword-block"))
    }

    // MARK: (e) mute beats keywords

    @Test func muteBeatsAllowKeyword() {
        var c = config(rules: [
            NotifyRule(kind: NotifyRule.keywordAllow, value: "outage", enabled: true),
        ])
        c.muted = true
        let hit = message(content: "outage now")
        #expect(ChatFilter.decide(message: hit, isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: c) == .skip(reason: "muted"))
    }

    @Test func muteBeatsBlockKeywordReason() {
        // Mute already skips; the mute reason wins (absolute gate).
        var c = config(rules: [
            NotifyRule(kind: NotifyRule.keywordBlock, value: "lunch", enabled: true),
        ])
        c.muted = true
        let hit = message(content: "lunch?")
        #expect(ChatFilter.decide(message: hit, isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: c) == .skip(reason: "muted"))
    }

    // MARK: (f) case-insensitive substring on plain text

    @Test func matchCaseInsensitiveSubstring() {
        let c = config(rules: [
            NotifyRule(kind: NotifyRule.keywordAllow, value: "sev", enabled: true),
        ])
        for content in ["SEV1 bridge", "a seveRity bump", "xxSeVxx"] {
            #expect(ChatFilter.decide(message: message(content: content), isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: c) == .notify(reason: "keyword-allow"), "content \(content)")
        }
        #expect(ChatFilter.decide(message: message(content: "all quiet"), isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: c) == .notify(reason: "chat-message"))
    }

    @Test func matchAgainstStrippedTextNotMarkup() {
        let c = config(rules: [
            NotifyRule(kind: NotifyRule.keywordAllow, value: "outage", enabled: true),
        ])
        // Tag soup around the word still hits (plainText match).
        let html = message(content: "<p>prod <b>outage</b> &amp; counting</p>")
        #expect(ChatFilter.decide(message: html, isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: c) == .notify(reason: "keyword-allow"))
        // Markup-only content carries no word: no hit.
        let bare = message(content: "<p><br/></p>")
        #expect(ChatFilter.decide(message: bare, isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: c) == .notify(reason: "chat-message"))
    }

    // MARK: gates: absent/disabled/blank = off, first wins

    @Test func keywordGatesOffWhenAbsentDisabledBlank() {
        let hit = message(content: "outage now")
        #expect(config(rules: []).allowKeywords.isEmpty)
        #expect(config(rules: []).blockKeywords.isEmpty)
        let off = config(rules: [
            NotifyRule(kind: NotifyRule.keywordAllow, value: "outage", enabled: false),
            NotifyRule(kind: NotifyRule.keywordBlock, value: "lunch", enabled: false),
        ])
        #expect(off.allowKeywords.isEmpty)
        #expect(off.blockKeywords.isEmpty)
        #expect(ChatFilter.decide(message: hit, isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: off) == .notify(reason: "chat-message"))
        let blank = config(rules: [
            NotifyRule(kind: NotifyRule.keywordAllow, value: "  ", enabled: true),
        ])
        #expect(blank.allowKeywords.isEmpty)
        #expect(ChatFilter.decide(message: hit, isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: blank) == .notify(reason: "chat-message"))
    }

    @Test func keywordFirstMatchWins() {
        let c = config(rules: [
            NotifyRule(kind: NotifyRule.keywordAllow, value: "outage", enabled: true),
            NotifyRule(kind: NotifyRule.keywordAllow, value: "lunch", enabled: true),
        ])
        #expect(c.allowKeywords == ["outage"])
    }

    @Test func keywordValueSplitsCommasAndLines() {
        #expect(NotifyRule.parseKeywords("outage, urgent") == ["outage", "urgent"])
        #expect(NotifyRule.parseKeywords("outage\nurgent\r\nsev1") == ["outage", "urgent", "sev1"])
        #expect(NotifyRule.parseKeywords("a,,b") == ["a", "b"])
        #expect(NotifyRule.parseKeywords("  ") == [])
        let c = config(rules: [
            NotifyRule(kind: NotifyRule.keywordAllow, value: "outage\nurgent", enabled: true),
        ])
        #expect(c.allowKeywords == ["outage", "urgent"])
    }

    // MARK: migration: no keyword rules invented

    @Test func migrateAddsNoKeywordRules() {
        let rules = NotifyRule.migrate(skipOwn: true, notifyOnEdit: false, types: ["Text", "RichText"], loud: "Watercooler")
        #expect(rules.map(\.kind) == NotifyRule.migratedKinds)
        #expect(!rules.contains(where: { $0.kind == NotifyRule.keywordAllow || $0.kind == NotifyRule.keywordBlock }))
    }

    @Test func legacyDecodeCarriesNoKeywords() throws {
        // Existing install ({} = legacy defaults): migrated rules have
        // no keyword kinds, and both keyword scalars stay empty.
        let c = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        #expect(c.allowKeywords.isEmpty)
        #expect(c.blockKeywords.isEmpty)
    }

    // MARK: (g) GUI model strings + round-trip

    @Test func keywordUXStringsExist() {
        for k in [NotifyRule.keywordAllow, NotifyRule.keywordBlock] {
            #expect(NotifyRule.displayName(for: k).contains(" "))
            #expect(!NotifyRule.displayName(for: k).contains("-"))
            #expect(!NotifyRule.goalTitle(for: k).isEmpty)
            #expect(NotifyRule.explanation(for: k).hasSuffix("."))
            #expect(!NotifyRule.exampleText(for: k).isEmpty)
            #expect(NotifyRule.usesValue(k))
            #expect(!NotifyRule.hint(for: k).isEmpty)
            #expect(!NotifyRule.valueLabel(for: k).isEmpty)
            #expect(!NotifyRule.valuePlaceholder(for: k).isEmpty)
            let picked = NotifyRule(kind: k, value: NotifyRule.defaultValue(for: k))
            #expect(picked.isValid)
            #expect(NotifyRule.sentence(for: picked).contains(picked.value))
        }
        // Sentences never leak raw ids.
        #expect(!NotifyRule.sentence(for: NotifyRule(kind: NotifyRule.keywordAllow, value: "outage")).contains("always-notify-keywords"))
        #expect(!NotifyRule.sentence(for: NotifyRule(kind: NotifyRule.keywordBlock, value: "lunch")).contains("never-notify-keywords"))
        // Plain-words validation names the display name + fix.
        let issue = NotifyRule(kind: NotifyRule.keywordAllow, value: "").plainIssue() ?? ""
        #expect(issue.contains("Always notify keywords"))
        #expect(issue.contains("outage, urgent"))
    }

    @Test func keywordRulesRoundTrip() throws {
        var c = Config.default
        c.notifyRules = [
            NotifyRule(kind: NotifyRule.keywordAllow, value: "outage, urgent", enabled: true),
            NotifyRule(kind: NotifyRule.keywordBlock, value: "lunch", enabled: false),
        ]
        c.rulesStored = true
        c.applyRules()
        #expect(c.allowKeywords == ["outage", "urgent"])
        #expect(c.blockKeywords.isEmpty) // disabled = gate off
        var back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        #expect(back.notifyRules == c.notifyRules)
        #expect(back.allowKeywords == ["outage", "urgent"])
        #expect(back.blockKeywords.isEmpty)
        #expect(back.normalizeRules().isEmpty)
        // Unknown-shape tolerant decode: missing keys fall back.
        let thin = try JSONDecoder().decode(Config.self, from: Data(#"{"notifyRules":[{"kind":"always-notify-keywords","value":"sev"}]}"#.utf8))
        #expect(thin.notifyRules == [NotifyRule(kind: "always-notify-keywords", value: "sev", enabled: true)])
        #expect(thin.allowKeywords == ["sev"])
    }
}
