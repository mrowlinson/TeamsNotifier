import Testing
@testable import TeamsCore

/// properties.alerts parse: only an explicit false mutes (fail-open).
@Suite("Conversation mute parse")
struct ConversationMuteTests {
    func conv(alerts: Any?) -> [String: Any] {
        var props: [String: Any] = ["consumptionhorizon": "0;0;x"]
        if let alerts { props["alerts"] = alerts }
        return ["id": "19:abc@thread.v2", "properties": props]
    }

    @Test func stringFalseMutes() {
        #expect(ConversationMute.isMuted(conv(alerts: "false")) == true)
    }

    @Test func stringFalseCaseAndSpaceTolerant() {
        for v in ["False", "FALSE", " false ", "\tFalse\n"] {
            #expect(ConversationMute.isMuted(conv(alerts: v)) == true, "alerts \(v.debugDescription)")
        }
    }

    @Test func stringTrueNotifies() {
        for v in ["true", "True", ""] {
            #expect(ConversationMute.isMuted(conv(alerts: v)) == false, "alerts \(v.debugDescription)")
        }
    }

    @Test func boolAndNumberShapes() {
        #expect(ConversationMute.isMuted(conv(alerts: false)) == true)
        #expect(ConversationMute.isMuted(conv(alerts: true)) == false)
        #expect(ConversationMute.isMuted(conv(alerts: 0)) == true)
        #expect(ConversationMute.isMuted(conv(alerts: 1)) == false)
    }

    @Test func absentOrUnknownFailsOpen() {
        #expect(ConversationMute.isMuted(conv(alerts: nil)) == false)
        #expect(ConversationMute.isMuted(conv(alerts: "maybe")) == false)
        #expect(ConversationMute.isMuted(conv(alerts: ["nested": true])) == false)
        #expect(ConversationMute.isMuted([:]) == false)
        #expect(ConversationMute.isMuted(["properties": "not-a-dict"]) == false)
    }
}
