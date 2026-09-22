import Foundation
import Testing
@testable import TeamsCore

/// Teams per-chat mute gate: a chat muted in the Teams client skips with
/// "teams-muted", beating every gate below the global mute (keywords,
/// meeting-starting, mentions). Global mute keeps its own reason.
@Suite("Teams muted chats")
struct TeamsMutedFilterTests {
    let ownerMRI = "8:orgid:11111111-2222-3333-4444-555555555555"
    let ownerName = "Alex Rivera"
    let chatID = "19:abc@thread.v2"

    func config() -> Config {
        Config(owner: Config.Owner(displayName: ownerName, upn: "alex@company.com", mri: ownerMRI), loudSubstring: "Watercooler")
    }

    func message(
        chatID: String? = nil,
        senderMRI: String? = "8:orgid:sender",
        senderName: String = "Alice",
        content: String = "hello",
        type: String = "RichText/Html",
        mentions: [Mention] = []
    ) -> EventMessage.Message {
        EventMessage.Message(
            chatID: chatID ?? self.chatID, messageID: "m1", senderMRI: senderMRI,
            senderName: senderName, content: content, messageType: type,
            threadTopic: nil, mentions: mentions, properties: [:], composeTime: nil
        )
    }

    @Test func mutedChatSkips() {
        let d = ChatFilter.decide(
            message: message(), isEdit: false, chatDisplayName: "Alice",
            ownerMRI: ownerMRI, config: config(), teamsMutedChatIDs: [chatID])
        #expect(d == .skip(reason: "teams-muted"))
    }

    @Test func mutedBeatsKeywordAllow() {
        var c = config()
        c.allowKeywords = ["urgent"]
        let d = ChatFilter.decide(
            message: message(content: "urgent: outage"), isEdit: false, chatDisplayName: "Alice",
            ownerMRI: ownerMRI, config: c, teamsMutedChatIDs: [chatID])
        #expect(d == .skip(reason: "teams-muted"))
    }

    @Test func mutedBeatsKeywordBlock() {
        var c = config()
        c.blockKeywords = ["lunch"]
        let d = ChatFilter.decide(
            message: message(content: "lunch thread"), isEdit: false, chatDisplayName: "Alice",
            ownerMRI: ownerMRI, config: c, teamsMutedChatIDs: [chatID])
        #expect(d == .skip(reason: "teams-muted"))
    }

    @Test func mutedBeatsLoudMention() {
        let m = message(mentions: [Mention(id: "0", mri: ownerMRI, mentionType: "person", displayName: ownerName)])
        let d = ChatFilter.decide(
            message: m, isEdit: false, chatDisplayName: "Watercooler",
            ownerMRI: ownerMRI, config: config(), teamsMutedChatIDs: [chatID])
        #expect(d == .skip(reason: "teams-muted"))
    }

    @Test func mutedBeatsMeetingStartingWithoutConsumingWindow() {
        var dedup = MeetingStartDedup()
        let now = Date()
        let beacon = message(senderMRI: nil, senderName: "", content: "AlicePlay", type: "Text")
        let d = ChatFilter.decide(
            message: beacon, isEdit: false, chatDisplayName: "Alice",
            ownerMRI: ownerMRI, config: config(), meetingDedup: &dedup, now: now,
            teamsMutedChatIDs: [chatID])
        #expect(d == .skip(reason: "teams-muted"))
        // Muted skip claims no window: unmuted, the same meeting notifies.
        let d2 = ChatFilter.decide(
            message: beacon, isEdit: false, chatDisplayName: "Alice",
            ownerMRI: ownerMRI, config: config(), meetingDedup: &dedup, now: now)
        #expect(d2 == .notify(reason: "meeting-starting"))
    }

    @Test func globalMuteKeepsReason() {
        var c = config()
        c.muted = true
        let d = ChatFilter.decide(
            message: message(), isEdit: false, chatDisplayName: "Alice",
            ownerMRI: ownerMRI, config: c, teamsMutedChatIDs: [chatID])
        #expect(d == .skip(reason: "muted"))
    }

    @Test func otherChatsUnaffected() {
        let d = ChatFilter.decide(
            message: message(), isEdit: false, chatDisplayName: "Alice",
            ownerMRI: ownerMRI, config: config(), teamsMutedChatIDs: ["19:other@thread.v2"])
        #expect(d == .notify(reason: "chat-message"))
    }

    @Test func defaultSetEmpty() {
        // No teamsMutedChatIDs arg = old behavior (all existing call sites).
        let d = ChatFilter.decide(message: message(), isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: config())
        #expect(d == .notify(reason: "chat-message"))
    }
}
