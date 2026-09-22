import Testing
@testable import TeamsCore

@Suite("ChatFilter")
struct ChatFilterTests {
    let ownerMRI = "8:orgid:11111111-2222-3333-4444-555555555555"
    let ownerName = "Alex Rivera"

    func config() -> Config {
        Config(owner: Config.Owner(displayName: ownerName, upn: "alex@company.com", mri: ownerMRI), loudSubstring: "Watercooler")
    }

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

    // MARK: loud (noisy-chat) rule

    @Test func loudChatSilentWithoutMention() {
        let d = ChatFilter.decide(message: message(), isEdit: false, chatDisplayName: "Watercooler Chat", ownerMRI: ownerMRI, config: config())
        #expect(d == .skip(reason: "loud-no-mention"))
    }

    @Test func loudMatchCaseInsensitive() {
        for name in ["watercooler alerts", "Watercooler-x", "xxWatercoolerxx"] {
            let d = ChatFilter.decide(message: message(), isEdit: false, chatDisplayName: name, ownerMRI: ownerMRI, config: config())
            #expect(d == .skip(reason: "loud-no-mention"), "chat \(name)")
        }
    }

    @Test func loudChatNotifiesOnOwnerMRI() {
        let m = message(mentions: [Mention(id: "0", mri: ownerMRI, mentionType: "person", displayName: ownerName)])
        let d = ChatFilter.decide(message: m, isEdit: false, chatDisplayName: "Team Watercooler", ownerMRI: ownerMRI, config: config())
        #expect(d == .notify(reason: "loud-owner-mention"))
    }

    @Test func loudChatNotifiesOnOwnerNameFallback() {
        let m = message(content: "<p>ping</p>", mentions: [Mention(id: "0", mri: nil, displayName: ownerName)])
        let d = ChatFilter.decide(message: m, isEdit: false, chatDisplayName: "Watercooler", ownerMRI: ownerMRI, config: config())
        #expect(d == .notify(reason: "loud-owner-mention"))
    }

    @Test func loudChatNotifiesOnChannelMention() {
        for mention in [
            Mention(id: "0", mri: nil, mentionType: "channel", displayName: "channel"),
            Mention(id: "0", mri: nil, mentionType: "everyone", displayName: "Everyone"),
            Mention(id: "0", mri: nil, displayName: "Channel"),
        ] {
            let m = message(mentions: [mention])
            let d = ChatFilter.decide(message: m, isEdit: false, chatDisplayName: "Watercooler", ownerMRI: ownerMRI, config: config())
            #expect(d == .notify(reason: "loud-channel-mention"), "\(mention)")
        }
    }

    @Test func loudChatOtherPersonMentionStaysSilent() {
        let m = message(mentions: [Mention(id: "0", mri: "8:orgid:other", mentionType: "person", displayName: "Bob")])
        let d = ChatFilter.decide(message: m, isEdit: false, chatDisplayName: "Watercooler", ownerMRI: ownerMRI, config: config())
        #expect(d == .skip(reason: "loud-no-mention"))
    }

    // MARK: normal chats

    @Test func normalChatAlwaysNotifies() {
        let d = ChatFilter.decide(message: message(), isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: config())
        #expect(d == .notify(reason: "chat-message"))
    }

    // MARK: gates

    @Test func ownMessageSkippedByMRI() {
        let m = message(senderMRI: ownerMRI, senderName: ownerName)
        let d = ChatFilter.decide(message: m, isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: config())
        #expect(d == .skip(reason: "own-message"))
    }

    @Test func ownMessageSkippedByNameFallback() {
        let m = message(senderMRI: nil, senderName: ownerName)
        let d = ChatFilter.decide(message: m, isEdit: false, chatDisplayName: "Alice", ownerMRI: nil, config: config())
        #expect(d == .skip(reason: "own-message"))
    }

    @Test func typingAndActivitySkipped() {
        for t in ["Control/Typing", "Control/ClearTyping", "ThreadActivity/MemberJoined", "Event/Call"] {
            let d = ChatFilter.decide(message: message(type: t), isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: config())
            #expect(d == .skip(reason: "type:\(t.split(separator: "/").first!)"), "type \(t)")
        }
    }

    @Test func textAndRichTextPass() {
        for t in ["Text", "RichText/Html", "RichText/Media_GenericCard"] {
            let d = ChatFilter.decide(message: message(type: t), isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: config())
            #expect(d == .notify(reason: "chat-message"), "type \(t)")
        }
    }

    @Test func editsSkippedByDefault() {
        let d = ChatFilter.decide(message: message(), isEdit: true, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: config())
        #expect(d == .skip(reason: "edit"))
    }

    @Test func editsNotifyWhenEnabled() {
        var c = config()
        c.notifyOnEdit = true
        let d = ChatFilter.decide(message: message(), isEdit: true, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: c)
        #expect(d == .notify(reason: "chat-message"))
    }

    @Test func emptyLoudSubstringDisablesRule() {
        var c = config()
        c.loudSubstring = ""
        let d = ChatFilter.decide(message: message(), isEdit: false, chatDisplayName: "Watercooler", ownerMRI: ownerMRI, config: c)
        #expect(d == .notify(reason: "chat-message"))
    }
}
