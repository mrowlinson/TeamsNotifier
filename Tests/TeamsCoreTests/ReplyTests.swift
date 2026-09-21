import Foundation
import Testing
@testable import TeamsCore

@Suite("Reply payload builder")
struct ReplyPayloadTests {
    @Test func escapesHTML() {
        #expect(ReplyPayload.escape("a&b<c>d\"e'f") == "a&amp;b&lt;c&gt;d&quot;e&#39;f")
    }

    @Test func buildFields() {
        let p = ReplyPayload.build(text: "hi", clientMessageID: "123")
        #expect(p["content"] == "<p>hi</p>")
        #expect(p["messagetype"] == "RichText/Html")
        #expect(p["contenttype"] == "text")
        #expect(p["clientmessageid"] == "123")
    }

    @Test func buildEscapesContent() {
        let p = ReplyPayload.build(text: "<b>hi</b>", clientMessageID: "1")
        #expect(p["content"] == "<p>&lt;b&gt;hi&lt;/b&gt;</p>")
    }

    @Test func buildMultilineBreaks() {
        let p = ReplyPayload.build(text: "a\nb", clientMessageID: "1")
        #expect(p["content"] == "<p>a<br/>b</p>")
    }

    @Test func clientMessageIDIsNowMillis() {
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        let id = ReplyPayload.clientMessageID()
        let after = Int64(Date().timeIntervalSince1970 * 1000)
        let v = Int64(id)
        #expect(v != nil && v! >= before && v! <= after)
    }

    @Test func urlShapesEndpoint() {
        let u = ReplyPayload.url(
            chatServiceBase: "https://amer.ng.msg.teams.microsoft.com",
            chatID: "19:abc@thread.v2")?.absoluteString
        #expect(u == "https://amer.ng.msg.teams.microsoft.com/v1/users/ME/conversations/19%3Aabc@thread.v2/messages")
    }
}

@Suite("Reply userInfo round-trip")
struct ReplyInfoTests {
    @Test func roundTrip() {
        let chat = "19:abc@thread.v2"
        #expect(ReplyInfo.chatID(from: ReplyInfo.userInfo(chatID: chat)) == chat)
    }

    @Test func missingKeyIsNil() {
        #expect(ReplyInfo.chatID(from: [:]) == nil)
    }

    @Test func emptyValueIsNil() {
        #expect(ReplyInfo.chatID(from: [ReplyInfo.chatIDKey: ""]) == nil)
    }

    @Test func wrongTypeIsNil() {
        #expect(ReplyInfo.chatID(from: [ReplyInfo.chatIDKey: 42]) == nil)
    }
}

@Suite("Reply notification constants")
struct ReplyInfoConstantsTests {
    @Test func ids() {
        #expect(ReplyInfo.categoryID == "TN_MESSAGE")
        #expect(ReplyInfo.replyActionID == "TN_REPLY")
        #expect(ReplyInfo.chatIDKey == "TNChatID")
    }

    @Test func actionStrings() {
        #expect(ReplyInfo.actionTitle == "Reply")
        #expect(ReplyInfo.sendButtonTitle == "Send")
        #expect(ReplyInfo.textInputPlaceholder == "Type a reply…")
    }
}

@Suite("Reply gating")
struct ReplyGateTests {
    @Test func validReplies() {
        #expect(ReplyGate.canReply(chatID: "19:abc@thread.v2", text: "thanks"))
    }

    @Test func emptyTextBlocked() {
        #expect(!ReplyGate.canReply(chatID: "19:abc@thread.v2", text: ""))
        #expect(!ReplyGate.canReply(chatID: "19:abc@thread.v2", text: "   \n "))
    }

    @Test func emptyChatBlocked() {
        #expect(!ReplyGate.canReply(chatID: "", text: "thanks"))
    }

    @Test func mutedDoesNotGateReplies() {
        // Mute gates inbound notifications only (ChatFilter); the reply gate
        // takes no muted input by design, so a visible banner stays
        // answerable while muted.
        #expect(ReplyGate.canReply(chatID: "19:abc@thread.v2", text: "thanks"))
    }
}
