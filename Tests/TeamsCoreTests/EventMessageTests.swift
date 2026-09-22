import Testing
@testable import TeamsCore

@Suite("EventMessage")
struct EventMessageTests {
    // Vectors generated with python gzip (independent of Swift decoder).
    static let gzipBody = "H4sIAAAAAAAC/6tWKqksSFWyUnItS80r8U0tLk5MT1XSUSpKLc4vLUpODYHI+qWWY8opWVUrVShZGdbWAgAwmkSTRgAAAA=="
    static let cpPayload = "H4sIAAAAAAAC/6tWykjNyclXslIqzy/KSVGqBQDRQQnYEQAAAA=="
    static let gpPayload = "eyJoZWxsbyI6IndvcmxkIn0="

    @Test func plainBody() throws {
        let obj = try EventMessage.decodeBody(headers: [:], body: #"{"a":1}"#)
        #expect((obj["a"] as? Int) == 1)
    }

    @Test func gzipTransportEncoding() throws {
        let obj = try EventMessage.decodeBody(
            headers: ["X-Microsoft-Skype-Content-Encoding": "gzip"], body: Self.gzipBody)
        #expect((obj["type"] as? String) == "EventMessage")
        #expect((obj["resourceType"] as? String) == "NewMessage")
    }

    @Test func nestedCP() throws {
        let obj = try EventMessage.decodeBody(headers: [:], body: #"{"cp":"\#(Self.cpPayload)"}"#)
        #expect((obj["hello"] as? String) == "world")
    }

    @Test func nestedGP() throws {
        let obj = try EventMessage.decodeBody(headers: [:], body: #"{"gp":"\#(Self.gpPayload)"}"#)
        #expect((obj["hello"] as? String) == "world")
    }

    @Test func invalidJSONThrows() {
        #expect(throws: EventMessage.DecodeError.self) {
            try EventMessage.decodeBody(headers: [:], body: "nope")
        }
    }

    @Test func badGzipThrows() {
        #expect(throws: EventMessage.DecodeError.self) {
            try EventMessage.decodeBody(
                headers: ["X-Microsoft-Skype-Content-Encoding": "gzip"], body: "aGVsbG8=")
        }
    }

    // MARK: parse

    func resource(overrides: [String: Any] = [:]) -> [String: Any] {
        var r: [String: Any] = [
            "messagetype": "RichText/Html",
            "from": "https://amer.ng.msg.teams.microsoft.com/v1/users/ME/contacts/8:orgid:aaa",
            "content": "<p>hi</p>",
            "imdisplayname": "Alice",
            "conversationLink": "https://amer.ng.msg.teams.microsoft.com/v1/users/ME/conversations/19:abc@thread.v2/messages/1",
            "id": "m1",
            "composetime": "2026-09-21T10:00:00.000Z",
        ]
        for (k, v) in overrides { r[k] = v }
        return r
    }

    @Test func parsesNewMessage() {
        let obj: [String: Any] = ["type": "EventMessage", "resourceType": "NewMessage", "resource": resource()]
        let parsed = EventMessage.parse(obj)
        #expect(parsed?.isEdit == false)
        #expect(parsed?.message.chatID == "19:abc@thread.v2")
        #expect(parsed?.message.senderMRI == "8:orgid:aaa")
        #expect(parsed?.message.senderName == "Alice")
        #expect(parsed?.message.plainText == "hi")
    }

    @Test func messageUpdateFlaggedEdit() {
        let obj: [String: Any] = ["type": "EventMessage", "resourceType": "MessageUpdate", "resource": resource()]
        #expect(EventMessage.parse(obj)?.isEdit == true)
    }

    @Test func nonMessageIgnored() {
        #expect(EventMessage.parse(["type": "EventMessage", "resourceType": "UserPresence", "resource": resource()]) == nil)
        #expect(EventMessage.parse(["type": "Other", "resourceType": "NewMessage", "resource": resource()]) == nil)
    }

    @Test func missingConversationLinkIgnored() {
        var r = resource()
        r.removeValue(forKey: "conversationLink")
        #expect(EventMessage.parse(["type": "EventMessage", "resourceType": "NewMessage", "resource": r]) == nil)
    }

    @Test func threadTopicCarried() {
        let obj: [String: Any] = ["type": "EventMessage", "resourceType": "NewMessage",
                                  "resource": resource(overrides: ["threadtopic": "Watercooler Chat"])]
        #expect(EventMessage.parse(obj)?.message.threadTopic == "Watercooler Chat")
    }

    @Test func mentionsParsedFromProperties() {
        let r = resource(overrides: ["properties": ["mentions": [["itemid": "0", "mri": "8:orgid:me", "displayName": "Me"]]]])
        let obj: [String: Any] = ["type": "EventMessage", "resourceType": "NewMessage", "resource": r]
        #expect(EventMessage.parse(obj)?.message.mentions.count == 1)
    }

    // MARK: id extraction

    @Test func chatIDFromLink() {
        #expect(EventMessage.chatID(fromConversationLink: "https://x/v1/users/ME/conversations/19:abc@thread.v2/messages/1") == "19:abc@thread.v2")
        #expect(EventMessage.chatID(fromConversationLink: "https://x/conversations/19%3Aabc%40thread.v2?x=1") == "19:abc@thread.v2")
        #expect(EventMessage.chatID(fromConversationLink: "https://x/conversations/19:abc@thread.v2;123?y=2") == "19:abc@thread.v2")
        #expect(EventMessage.chatID(fromConversationLink: "nonsense") == nil)
    }

    @Test func mriFromContactLink() {
        #expect(EventMessage.mri(fromContactLink: "https://x/v1/users/ME/contacts/8:orgid:aaa") == "8:orgid:aaa")
        #expect(EventMessage.mri(fromContactLink: "8:orgid:aaa") == "8:orgid:aaa")
        #expect(EventMessage.mri(fromContactLink: "") == nil)
    }
}
