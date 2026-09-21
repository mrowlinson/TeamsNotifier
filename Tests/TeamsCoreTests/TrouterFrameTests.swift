import Testing
@testable import TeamsCore

@Suite("Trouter frames")
struct TrouterFrameTests {
    @Test func helloDetected() {
        #expect(TrouterFrame.isHello("1::"))
        #expect(!TrouterFrame.isHello("3:::{}"))
    }

    @Test func parseRequest() {
        let frame = #"3:::{"id":123,"url":"/v4/f/abc/messaging","headers":{"Content-Type":"application/json"},"body":"{\"a\":1}"}"#
        let req = TrouterFrame.parseRequest(frame)
        #expect(req?.id == 123)
        #expect(req?.url == "/v4/f/abc/messaging")
        #expect(req?.headers["Content-Type"] == "application/json")
        #expect(req?.body == #"{"a":1}"#)
    }

    @Test func parseRequestRejectsNon3() {
        #expect(TrouterFrame.parseRequest(#"5:1::{"name":"x"}"#) == nil)
        #expect(TrouterFrame.parseRequest("3:::not-json") == nil)
        #expect(TrouterFrame.parseRequest(#"3:::{"noid":1}"#) == nil)
    }

    @Test func requestAckShape() {
        let ack = TrouterFrame.requestAck(requestID: 123)
        #expect(ack.hasPrefix("3:::"))
        #expect(ack.contains("\"id\":123") && ack.contains("\"status\":200"))
    }

    @Test func eventAckOnlyForPlus() {
        #expect(TrouterFrame.eventAck(for: #"5:7+::{"name":"x"}"#) == "6:7::")
        #expect(TrouterFrame.eventAck(for: #"5:7::{"name":"x"}"#) == nil)
        #expect(TrouterFrame.eventAck(for: "3:::{}") == nil)
    }

    @Test func messageLossDetected() {
        #expect(TrouterFrame.isMessageLoss(#"5:3::{"name":"trouter.message_loss"}"#))
        #expect(!TrouterFrame.isMessageLoss(#"5:3::{"name":"other"}"#))
    }

    @Test func sessionIDParsed() {
        #expect(TrouterFrame.parseSessionID("abcdef123:180:180:websocket,xhr-polling") == "abcdef123")
        #expect(TrouterFrame.parseSessionID("") == nil)
    }

    @Test func authenticateFrameShape() {
        let f = TrouterFrame.authenticate(connectParams: ["sr": "x"], idToken: "TOK")
        #expect(f.hasPrefix("5:::"))
        #expect(f.contains("user.authenticate") && f.contains("Bearer TOK") && f.contains("\"sr\":\"x\""))
    }

    @Test func pingAndActivityShapes() {
        #expect(TrouterFrame.ping(sequence: 4) == #"5:4+::{"name":"ping"}"#)
        #expect(TrouterFrame.activity(sequence: 2).contains("user.activity"))
    }

    @Test func queryContainsRequiredParams() {
        let q = TrouterFrame.query(connectParams: ["sr": "a b", "sig": "x"], endpointID: "ep", ccid: "cc")
        #expect(q.contains("v=v4"))
        #expect(q.contains("sr=a%20b") || q.contains("sr=a+b"))
        #expect(q.contains("epid=ep") && q.contains("ccid=cc"))
        #expect(q.contains("auth=true") && q.contains("timeout=40") && q.contains("tc="))
    }
}
