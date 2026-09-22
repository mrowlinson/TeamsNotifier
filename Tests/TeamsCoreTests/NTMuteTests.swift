import Foundation
import Testing
@testable import TeamsCore

@Suite("Log format")
struct LogFormatTests {
    @Test func timestampPrefixTagAfter() {
        let date = Date(timeIntervalSince1970: 1_787_000_000) // whole seconds
        let line = LogFormat.line(tag: "[teamsnotifier]", message: "hello", date: date)
        let parts = line.split(separator: " ", maxSplits: 2)
        #expect(parts.count == 3)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        #expect(f.date(from: String(parts[0])) == date)
        #expect(parts[1] == "[teamsnotifier]")
        #expect(parts[2] == "hello")
    }

    @Test func levelTagsKeepShape() {
        let d = LogFormat.line(tag: "[teamsnotifier:debug]", message: "m")
        let f = LogFormat.line(tag: "[teamsnotifier:FAULT]", message: "m")
        #expect(d.contains(" [teamsnotifier:debug] m"))
        #expect(f.contains(" [teamsnotifier:FAULT] m"))
    }
}

@Suite("Keep-alive schedule")
struct KeepAliveTests {
    @Test func halfLifetime() {
        #expect(KeepAlive.refreshDelay(expiresIn: 3600) == 1800)
        #expect(KeepAlive.refreshDelay(expiresIn: 600) == 300)
    }

    @Test func cappedAt30m() {
        #expect(KeepAlive.refreshDelay(expiresIn: 86400) == 1800)
    }

    @Test func flooredAt60s() {
        #expect(KeepAlive.refreshDelay(expiresIn: 100) == 60)
        #expect(KeepAlive.refreshDelay(expiresIn: 0) == 60)
    }

    @Test func retryBackoff() {
        #expect(KeepAlive.retryDelay(failures: 1) == 60)
        #expect(KeepAlive.retryDelay(failures: 2) == 120)
        #expect(KeepAlive.retryDelay(failures: 3) == 240)
        #expect(KeepAlive.retryDelay(failures: 4) == 480)
        #expect(KeepAlive.retryDelay(failures: 5) == 600)
        #expect(KeepAlive.retryDelay(failures: 99) == 600)
    }
}

@Suite("Message-loss settle")
struct MessageLossGuardTests {
    @Test func firstLossReregisters() {
        var g = MessageLossGuard(settleWindow: 60, maxConsecutive: 5)
        #expect(g.recordLoss(now: Date()) == .reregister)
    }

    @Test func burstWithinWindowIgnored() {
        var g = MessageLossGuard(settleWindow: 60, maxConsecutive: 5)
        let t = Date()
        #expect(g.recordLoss(now: t) == .reregister)
        for i in 1...4 {
            #expect(g.recordLoss(now: t.addingTimeInterval(TimeInterval(i))) == .ignoreSettle)
        }
    }

    @Test func overCapHolds() {
        var g = MessageLossGuard(settleWindow: 60, maxConsecutive: 5)
        let t = Date()
        #expect(g.recordLoss(now: t) == .reregister)
        for i in 1...4 {
            _ = g.recordLoss(now: t.addingTimeInterval(TimeInterval(i)))
        }
        #expect(g.recordLoss(now: t.addingTimeInterval(5)) == .hold)
        #expect(g.recordLoss(now: t.addingTimeInterval(6)) == .hold)
    }

    @Test func windowExpiryReregistersAgain() {
        var g = MessageLossGuard(settleWindow: 60, maxConsecutive: 5)
        let t = Date()
        #expect(g.recordLoss(now: t) == .reregister)
        #expect(g.recordLoss(now: t.addingTimeInterval(61)) == .reregister)
    }

    @Test func startupBurstFive() {
        // Live log: 5x loss right after registrations -> 1 re-register + 4 ignored.
        var g = MessageLossGuard()
        let t = Date()
        var actions: [MessageLossGuard.Action] = []
        for i in 0..<5 {
            actions.append(g.recordLoss(now: t.addingTimeInterval(TimeInterval(i))))
        }
        #expect(actions == [.reregister, .ignoreSettle, .ignoreSettle, .ignoreSettle, .ignoreSettle])
    }
}

@Suite("Notify settings mapping")
struct NotifySettingsTests {
    @Test func enabledBannerOk() {
        #expect(!NotifySettings.isAlertOff(alertSettingRaw: 2, alertStyleRaw: 1))
        #expect(NotifySettings.statusSuffix(alertSettingRaw: 2, alertStyleRaw: 1) == nil)
    }

    @Test func disabledIsOff() {
        #expect(NotifySettings.isAlertOff(alertSettingRaw: 1, alertStyleRaw: 1))
    }

    @Test func styleNoneIsOff() {
        #expect(NotifySettings.isAlertOff(alertSettingRaw: 2, alertStyleRaw: 0))
    }

    @Test func suffixText() {
        #expect(NotifySettings.statusSuffix(alertSettingRaw: 1, alertStyleRaw: 1)
            == " · notifications off in Settings")
    }
}

@Suite("Mute gate")
struct MuteTests {
    let ownerMRI = "8:orgid:owner"
    let ownerName = "Alex Rivera"

    func message(mentions: [Mention] = []) -> EventMessage.Message {
        EventMessage.Message(
            chatID: "19:abc@thread.v2", messageID: "m1", senderMRI: "8:orgid:sender",
            senderName: "Alice", content: "hello", messageType: "RichText/Html",
            threadTopic: nil, mentions: mentions, properties: [:], composeTime: nil
        )
    }

    func mutedConfig() -> Config {
        var c = Config(owner: Config.Owner(displayName: ownerName, upn: "alex@company.com", mri: ownerMRI))
        c.muted = true
        return c
    }

    @Test func mutedSkipsNormalChat() {
        let d = ChatFilter.decide(message: message(), isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: mutedConfig())
        #expect(d == .skip(reason: "muted"))
    }

    @Test func mutedSkipsEvenLoudMention() {
        let m = message(mentions: [Mention(id: "0", mri: ownerMRI, mentionType: "person", displayName: ownerName)])
        let d = ChatFilter.decide(message: m, isEdit: false, chatDisplayName: "Watercooler", ownerMRI: ownerMRI, config: mutedConfig())
        #expect(d == .skip(reason: "muted"))
    }

    @Test func unmutedUnchanged() {
        var c = mutedConfig()
        c.muted = false
        let d = ChatFilter.decide(message: message(), isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: c)
        #expect(d == .notify(reason: "chat-message"))
    }

    @Test func legacyConfigDecodesUnmuted() throws {
        let json = #"{"owner":{"displayName":"N","upn":"","mri":""},"loudSubstring":"Watercooler","notifyOnEdit":false,"skipOwnMessages":true,"notifyTypes":["Text"]}"#
        let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(c.muted == false)
    }

    @Test func mutedRoundTrips() throws {
        var c = Config.default
        c.muted = true
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(Config.self, from: data)
        #expect(back.muted == true)
    }
}
