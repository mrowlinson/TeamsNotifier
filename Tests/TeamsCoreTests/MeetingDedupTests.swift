import Foundation
import Testing
@testable import TeamsCore

/// Meeting-lifecycle collapse: one meeting burst (Play beacons, JSON
/// metadata blobs, Facilitator open/close, empty bodies) notifies ONCE
/// ("meeting-starting": the app posts synthesized "Meeting starting:
/// <chat>"); the raw bodies never notify. Fixtures below are shaped
/// EXACTLY like history.jsonl records 1-29 (2026-09-22).
@Suite("Meeting dedup")
struct MeetingDedupTests {
    let ownerMRI = "8:orgid:11111111-2222-3333-4444-555555555555"
    let ownerName = "Alex Rivera"

    let chatA = "Technology Team - Safety Huddle"
    let threadA = "19:meeting_NmI5ZmM2MTctNTI3MS00MzE2LThmZDAtMmI0ZWFmOTE4YjI3@thread.v2"
    let chatB = "Daily CI Safety Huddle"
    let threadB = "19:meeting_ZTFiNWU1MGUtMGU1OS00NzdiLWE3MGYtNGJkMmZmMmY4ZmYy@thread.v2"

    // history record 3 (record 10/16 same shape, other ids)
    let blobA = #"{"scopeId":"de247b47-a9f0-4c89-9b5a-c3a0c8a210dd","storageId":"29a44eb7-f806-4fcf-bdfc-c908ab7791c8@88183a67-3f7b-49a4-b2e4-1f8c2eff0dde","callId":"de247b47-a9f0-4c89-9b5a-c3a0c8a210dd","iCalUid":"040000008200E00074C5B7101A82E00807EA0916CCD8EA764541DD01000000000000000010000000ECD909C7F36EA242AE5A2F3C98FB3969","exchangeId":"","meetingTenantId":"88183a67-3f7b-49a4-b2e4-1f8c2eff0dde","modernGroupId":null,"meetingOrganizerId":"8:orgid:29a44eb7-f806-4fcf-bdfc-c908ab7791c8","isDeleted":false,"originatorParticipantId":"646b7704-0886-49f7-91a2-4854bcea2345","isExportedToOdsp":true}"#
    let blobA2 = #"{"scopeId":"dd4eedfc-f48d-4e56-9b6a-f220f5c5651a","storageId":"29a44eb7-f806-4fcf-bdfc-c908ab7791c8@88183a67-3f7b-49a4-b2e4-1f8c2eff0dde","callId":"dd4eedfc-f48d-4e56-9b6a-f220f5c5651a","iCalUid":"040000008200E00074C5B7101A82E00807EA0916CCD8EA764541DD01000000000000000010000000ECD909C7F36EA242AE5A2F3C98FB3969","exchangeId":"","meetingTenantId":"88183a67-3f7b-49a4-b2e4-1f8c2eff0dde","modernGroupId":null,"meetingOrganizerId":"8:orgid:29a44eb7-f806-4fcf-bdfc-c908ab7791c8","isDeleted":false,"originatorParticipantId":"d984eefb-43fe-4f10-8157-7273723c703c","isExportedToOdsp":true}"#
    // history record 4
    let openA = "Hi all, I’m here to help with the meeting. I’ll take notes and keep track of time.\n\r\n\n\r\n\nHere’s the agenda from the chat:\n\r\n\r\n\nCredit card reader issues (15 min)"
    // history record 7
    let closeA = "Everyone—that’s a wrap. Here’s the complete rundown of today’s meeting."
    // history record 22
    let blobB = #"{"scopeId":"d738ffa5-8ed0-4ec8-bb9d-1fcde3894594","storageId":"42647424-a5a7-4b80-a030-e4f1c494542b@88183a67-3f7b-49a4-b2e4-1f8c2eff0dde","callId":"d738ffa5-8ed0-4ec8-bb9d-1fcde3894594","iCalUid":"040000008200E00074C5B7101A82E00807EA0916454F53216E41DD01000000000000000010000000EE5ABFA3456DDA449EDA69726C5C349C","exchangeId":"","meetingTenantId":"88183a67-3f7b-49a4-b2e4-1f8c2eff0dde","modernGroupId":null,"meetingOrganizerId":"8:orgid:42647424-a5a7-4b80-a030-e4f1c494542b","isDeleted":false,"originatorParticipantId":"6ade2c03-3c6a-4b67-b030-8ffb685c86ec","isExportedToOdsp":true}"#
    // history record 23
    let openB = "Hi all, I’m here to help with the meeting. I’ll take notes and keep track of time.\n\r\n\r\nHere’s the agenda from the invite:\n\r\n\r\nQuote of the day (1 min)\nSafety concerns (1 min)\nDaily needs check (1 min)\nBarriers and assistance (2 min)"

    func config() -> Config {
        Config(owner: Config.Owner(displayName: ownerName, upn: "alex@company.com", mri: ownerMRI), loudSubstring: "Watercooler")
    }

    func message(
        chatID: String,
        senderMRI: String? = nil,
        senderName: String = "",
        content: String,
        messageID: String = "m1",
        type: String = "Text"
    ) -> EventMessage.Message {
        EventMessage.Message(
            chatID: chatID, messageID: messageID, senderMRI: senderMRI,
            senderName: senderName, content: content, messageType: type,
            threadTopic: nil, mentions: [], properties: [:], composeTime: nil
        )
    }

    func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    /// One history-shaped row: (timestamp, sender, A/B chat, content).
    /// Empty sender = beacon/blob shape (no MRI, like the wire).
    func decideRow(
        _ iso: String, _ sender: String, _ chat: String, _ content: String,
        id: String, dedup: inout MeetingStartDedup, config: Config
    ) -> ChatFilter.Decision {
        let thread = chat == "A" ? threadA : threadB
        let name = chat == "A" ? chatA : chatB
        let mri: String? = sender.isEmpty || sender == "Facilitator" ? nil : "8:orgid:someone"
        let m = message(chatID: thread, senderMRI: mri, senderName: sender, content: content, messageID: id)
        return ChatFilter.decide(message: m, isEdit: false, chatDisplayName: name, ownerMRI: ownerMRI, config: config, meetingDedup: &dedup, now: date(iso))
    }

    // MARK: full history replay: 29 records -> 2 notifies

    @Test func historyReplayCollapsesToTwoNotifies() {
        let cfg = config()
        var dedup = MeetingStartDedup()
        let playA = chatA + "Play", playB = chatB + "Play"
        // (timestamp, sender, chat, content) per history.jsonl 1-29.
        let rows: [(String, String, String, String)] = [
            ("2026-09-22T11:57:09Z", "", "A", playA),
            ("2026-09-22T11:57:09Z", "", "A", playA),
            ("2026-09-22T11:57:09Z", "", "A", blobA),
            ("2026-09-22T11:59:39Z", "Facilitator", "A", openA),
            ("2026-09-22T12:02:14Z", "", "A", playA),
            ("2026-09-22T12:02:14Z", "", "A", playA),
            ("2026-09-22T12:02:37Z", "Facilitator", "A", closeA),
            ("2026-09-22T12:02:49Z", "", "A", playA),
            ("2026-09-22T12:02:49Z", "", "A", playA),
            ("2026-09-22T12:02:49Z", "", "A", blobA2),
            ("2026-09-22T12:02:51Z", "", "A", playA),
            ("2026-09-22T12:02:51Z", "", "A", playA),
            ("2026-09-22T12:02:56Z", "", "A", playA),
            ("2026-09-22T12:02:57Z", "", "A", playA),
            ("2026-09-22T12:02:57Z", "", "A", playA),
            ("2026-09-22T12:02:58Z", "", "A", blobA),
            ("2026-09-22T12:02:59Z", "", "A", playA),
            ("2026-09-22T12:02:59Z", "", "A", playA),
            ("2026-09-22T12:03:05Z", "", "A", playA),
            ("2026-09-22T12:03:42Z", "", "A", playA),
            ("2026-09-22T12:52:28Z", "", "B", playB),
            ("2026-09-22T12:52:29Z", "", "B", blobB),
            ("2026-09-22T12:53:07Z", "Facilitator", "B", openB),
            ("2026-09-22T12:55:18Z", "Masten, Marjorie", "B", ""),
            ("2026-09-22T12:57:39Z", "Masten, Marjorie", "B", ""),
            ("2026-09-22T12:57:42Z", "", "B", playB),
            ("2026-09-22T12:57:55Z", "Facilitator", "B", closeA),
            ("2026-09-22T12:58:33Z", "", "B", playB),
            ("2026-09-22T13:01:32Z", "Provost, Keith", "B", ""),
        ]
        var notifies: [Int] = []
        var decisions: [ChatFilter.Decision] = []
        for (i, r) in rows.enumerated() {
            let d = decideRow(r.0, r.1, r.2, r.3, id: "h\(i)", dedup: &dedup, config: cfg)
            decisions.append(d)
            if case .notify = d { notifies.append(i) }
        }
        // Exactly two notifies: first signal of each meeting burst.
        #expect(notifies == [0, 20])
        #expect(decisions[0] == .notify(reason: "meeting-starting"))
        #expect(decisions[20] == .notify(reason: "meeting-starting"))
        // Spot reasons: blob/open fold, closes fold-only, empties skip.
        #expect(decisions[2] == .skip(reason: "meeting-start-suppressed"))
        #expect(decisions[3] == .skip(reason: "meeting-start-suppressed"))
        #expect(decisions[6] == .skip(reason: "facilitator-close"))
        #expect(decisions[23] == .skip(reason: "empty-text"))
        #expect(decisions[24] == .skip(reason: "empty-text"))
        #expect(decisions[26] == .skip(reason: "facilitator-close"))
        #expect(decisions[28] == .skip(reason: "empty-text"))
        // No raw body ever notifies: every notify is the synthesized one.
        for d in decisions {
            if case .notify(let reason) = d { #expect(reason == "meeting-starting") }
        }
    }

    // MARK: window: later meeting notifies, repeats fold

    @Test func secondMeetingSameChatLaterNotifiesOnce() {
        let cfg = config()
        var dedup = MeetingStartDedup()
        let playA = chatA + "Play"
        func decide(_ iso: String, _ content: String) -> ChatFilter.Decision {
            let m = message(chatID: threadA, content: content, messageID: iso)
            return ChatFilter.decide(message: m, isEdit: false, chatDisplayName: chatA, ownerMRI: ownerMRI, config: cfg, meetingDedup: &dedup, now: date(iso))
        }
        #expect(decide("2026-09-22T10:00:00Z", playA) == .notify(reason: "meeting-starting"))
        #expect(decide("2026-09-22T10:01:00Z", playA) == .skip(reason: "meeting-start-suppressed"))
        #expect(decide("2026-09-22T10:02:00Z", blobA) == .skip(reason: "meeting-start-suppressed"))
        // 30min later: still the same burst window, folds.
        #expect(decide("2026-09-22T10:35:00Z", playA) == .skip(reason: "meeting-start-suppressed"))
        // Next meeting, 3h later: notifies once, then folds again.
        #expect(decide("2026-09-22T13:30:00Z", playA) == .notify(reason: "meeting-starting"))
        #expect(decide("2026-09-22T13:31:00Z", playA) == .skip(reason: "meeting-start-suppressed"))
        // Next day: notifies again.
        #expect(decide("2026-09-23T10:00:00Z", playA) == .notify(reason: "meeting-starting"))
    }

    @Test func blobFirstStillNotifiesSynthesizedOnce() {
        // A burst opening with the metadata blob notifies "meeting-starting"
        // (synthesized body at the app layer), never the raw JSON.
        let cfg = config()
        var dedup = MeetingStartDedup()
        let playA = chatA + "Play"
        let b = message(chatID: threadA, content: blobA, messageID: "b1")
        #expect(ChatFilter.decide(message: b, isEdit: false, chatDisplayName: chatA, ownerMRI: ownerMRI, config: cfg, meetingDedup: &dedup, now: date("2026-09-22T10:00:00Z")) == .notify(reason: "meeting-starting"))
        let p = message(chatID: threadA, content: playA, messageID: "p1")
        #expect(ChatFilter.decide(message: p, isEdit: false, chatDisplayName: chatA, ownerMRI: ownerMRI, config: cfg, meetingDedup: &dedup, now: date("2026-09-22T10:01:00Z")) == .skip(reason: "meeting-start-suppressed"))
    }

    // MARK: fold-only signals never open, extend open windows

    @Test func facilitatorCloseNeverOpensWindow() {
        let cfg = config()
        var dedup = MeetingStartDedup()
        let playA = chatA + "Play"
        let c = message(chatID: threadA, senderName: "Facilitator", content: closeA, messageID: "c1")
        #expect(ChatFilter.decide(message: c, isEdit: false, chatDisplayName: chatA, ownerMRI: ownerMRI, config: cfg, meetingDedup: &dedup, now: date("2026-09-22T10:00:00Z")) == .skip(reason: "facilitator-close"))
        #expect(dedup.count == 0) // lone close leaves no window behind
        let p = message(chatID: threadA, content: playA, messageID: "p1")
        #expect(ChatFilter.decide(message: p, isEdit: false, chatDisplayName: chatA, ownerMRI: ownerMRI, config: cfg, meetingDedup: &dedup, now: date("2026-09-22T10:30:00Z")) == .notify(reason: "meeting-starting"))
    }

    @Test func closeExtendsOpenWindow() {
        let cfg = config()
        var dedup = MeetingStartDedup()
        let playA = chatA + "Play"
        func decide(_ iso: String, _ sender: String, _ content: String) -> ChatFilter.Decision {
            let m = message(chatID: threadA, senderName: sender, content: content, messageID: iso)
            return ChatFilter.decide(message: m, isEdit: false, chatDisplayName: chatA, ownerMRI: ownerMRI, config: cfg, meetingDedup: &dedup, now: date(iso))
        }
        #expect(decide("2026-09-22T10:00:00Z", "", playA) == .notify(reason: "meeting-starting"))
        #expect(decide("2026-09-22T11:30:00Z", "Facilitator", closeA) == .skip(reason: "facilitator-close"))
        // 12:30 is 2.5h after the open but 1h after the close: folds.
        #expect(decide("2026-09-22T12:30:00Z", "", playA) == .skip(reason: "meeting-start-suppressed"))
    }

    @Test func meetingThreadEmptyExtendsWindow() {
        let cfg = config()
        var dedup = MeetingStartDedup()
        let playA = chatA + "Play"
        func decide(_ iso: String, _ sender: String, _ content: String) -> ChatFilter.Decision {
            let m = message(chatID: threadA, senderMRI: "8:orgid:someone", senderName: sender, content: content, messageID: iso)
            return ChatFilter.decide(message: m, isEdit: false, chatDisplayName: chatA, ownerMRI: ownerMRI, config: cfg, meetingDedup: &dedup, now: date(iso))
        }
        #expect(decide("2026-09-22T10:00:00Z", "", playA) == .notify(reason: "meeting-starting"))
        #expect(decide("2026-09-22T11:30:00Z", "Masten, Marjorie", "") == .skip(reason: "empty-text"))
        #expect(decide("2026-09-22T12:30:00Z", "", playA) == .skip(reason: "meeting-start-suppressed"))
    }

    // MARK: structural bodies never notify

    @Test func emptyTextRules() {
        let cfg = config()
        var dedup = MeetingStartDedup()
        func decide(_ m: EventMessage.Message, chat: String) -> ChatFilter.Decision {
            ChatFilter.decide(message: m, isEdit: false, chatDisplayName: chat, ownerMRI: ownerMRI, config: cfg, meetingDedup: &dedup, now: date("2026-09-22T10:00:00Z"))
        }
        // Meeting-thread empties skip, whatever the wire shape.
        #expect(decide(message(chatID: threadB, senderMRI: "8:orgid:someone", senderName: "Masten, Marjorie", content: ""), chat: chatB) == .skip(reason: "empty-text"))
        #expect(decide(message(chatID: threadB, senderName: "", content: "<p><br/></p>"), chat: chatB) == .skip(reason: "empty-text"))
        // Wire-blank bodies skip in normal chats too.
        #expect(decide(message(chatID: "19:abc@thread.v2", senderMRI: "8:orgid:sender", senderName: "Alice", content: "   "), chat: "Alice") == .skip(reason: "empty-text"))
        // Legacy: markup-only in a normal chat still notifies.
        #expect(decide(message(chatID: "19:abc@thread.v2", senderMRI: "8:orgid:sender", senderName: "Alice", content: "<p><br/></p>"), chat: "Alice") == .notify(reason: "chat-message"))
    }

    @Test func genericJSONAndCodeNeverNotifyNorOpen() {
        let cfg = config()
        var dedup = MeetingStartDedup()
        let now = date("2026-09-22T10:00:00Z")
        func decide(_ content: String) -> ChatFilter.Decision {
            let m = message(chatID: "19:abc@thread.v2", senderMRI: "8:orgid:sender", senderName: "Alice", content: content)
            return ChatFilter.decide(message: m, isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: cfg, meetingDedup: &dedup, now: now)
        }
        #expect(decide(#"{"hello":"world","n":1}"#) == .skip(reason: "json-blob"))
        #expect(decide("[1, 2, 3]") == .skip(reason: "json-blob"))
        #expect(decide("```\ndeploy log line 1\ndeploy log line 2\n```") == .skip(reason: "code-blob"))
        #expect(dedup.count == 0) // structural skips open no window
        // Almost-JSON still notifies (fail open on unparseable).
        #expect(decide("{not json") == .notify(reason: "chat-message"))
        #expect(decide("use `code` ticks inline") == .notify(reason: "chat-message"))
    }

    // MARK: beacon + facilitator shapes

    @Test func playBeaconVariants() {
        let cfg = config()
        // Strict "<chat>Play" matches even outside meeting threads.
        var d0 = MeetingStartDedup()
        let strict = message(chatID: "19:abc@thread.v2", content: "AlicePlay")
        #expect(MeetingSignal.classify(message: strict, chatDisplayName: "Alice") == .playBeacon)
        #expect(ChatFilter.decide(message: strict, isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: cfg, meetingDedup: &d0, now: date("2026-09-22T10:00:00Z")) == .notify(reason: "meeting-starting"))
        // Fallback: empty sender + meeting thread + suffix, chat unresolved.
        let fallback = message(chatID: threadA, content: "SomethingPlay")
        #expect(MeetingSignal.classify(message: fallback, chatDisplayName: threadA) == .playBeacon)
        // Negatives: lone "Play", human senders, wrong case.
        #expect(MeetingSignal.classify(message: message(chatID: threadA, content: "Play"), chatDisplayName: chatA) == .normal)
        let human = message(chatID: threadA, senderMRI: "8:orgid:someone", senderName: "Alice", content: "lets Play")
        #expect(MeetingSignal.classify(message: human, chatDisplayName: chatA) == .normal)
        let lower = message(chatID: threadA, content: "huddleplay")
        #expect(MeetingSignal.classify(message: lower, chatDisplayName: "huddle") == .normal)
    }

    @Test func facilitatorOtherTextStaysNormal() {
        // Only the observed open/close markers fold; other bot text notifies.
        let cfg = config()
        var dedup = MeetingStartDedup()
        let m = message(chatID: threadA, senderName: "Facilitator", content: "Reminder: 5 minutes left in the meeting.")
        #expect(MeetingSignal.classify(message: m, chatDisplayName: chatA) == .normal)
        #expect(ChatFilter.decide(message: m, isEdit: false, chatDisplayName: chatA, ownerMRI: ownerMRI, config: cfg, meetingDedup: &dedup, now: date("2026-09-22T10:00:00Z")) == .notify(reason: "chat-message"))
        // Markers match case-insensitively with straight quotes too.
        let open = message(chatID: threadA, senderName: "facilitator", content: "HI ALL, I'M HERE TO HELP WITH THE MEETING.")
        #expect(MeetingSignal.classify(message: open, chatDisplayName: chatA) == .facilitatorOpen)
        let close = message(chatID: threadA, senderName: "Facilitator", content: "That's a wrap, folks.")
        #expect(MeetingSignal.classify(message: close, chatDisplayName: chatA) == .facilitatorClose)
    }

    // MARK: normal traffic unaffected

    @Test func normalMessagesUnaffectedAroundBursts() {
        let cfg = config()
        var dedup = MeetingStartDedup()
        let playA = chatA + "Play"
        func decide(_ iso: String, _ sender: String, _ content: String) -> ChatFilter.Decision {
            let mri: String? = sender.isEmpty ? nil : "8:orgid:someone"
            let m = message(chatID: threadA, senderMRI: mri, senderName: sender, content: content, messageID: iso)
            return ChatFilter.decide(message: m, isEdit: false, chatDisplayName: chatA, ownerMRI: ownerMRI, config: cfg, meetingDedup: &dedup, now: date(iso))
        }
        #expect(decide("2026-09-22T10:00:00Z", "Priya", "can someone share the reader status?") == .notify(reason: "chat-message"))
        #expect(decide("2026-09-22T10:01:00Z", "", playA) == .notify(reason: "meeting-starting"))
        #expect(decide("2026-09-22T10:02:00Z", "Priya", "reader is back online") == .notify(reason: "chat-message"))
        #expect(decide("2026-09-22T10:03:00Z", "", playA) == .skip(reason: "meeting-start-suppressed"))
    }

    // MARK: stateless entry keeps first-signal semantics

    @Test func statelessDecideTakesFirstSignalBranch() {
        let cfg = config()
        let playA = chatA + "Play"
        let beacon = message(chatID: threadA, content: playA)
        #expect(ChatFilter.decide(message: beacon, isEdit: false, chatDisplayName: chatA, ownerMRI: ownerMRI, config: cfg) == .notify(reason: "meeting-starting"))
        let blob = message(chatID: threadA, content: blobA)
        #expect(ChatFilter.decide(message: blob, isEdit: false, chatDisplayName: chatA, ownerMRI: ownerMRI, config: cfg) == .notify(reason: "meeting-starting"))
        let open = message(chatID: threadA, senderName: "Facilitator", content: openA)
        #expect(ChatFilter.decide(message: open, isEdit: false, chatDisplayName: chatA, ownerMRI: ownerMRI, config: cfg) == .notify(reason: "meeting-starting"))
        // Stateless skips need no window.
        let close = message(chatID: threadA, senderName: "Facilitator", content: closeA)
        #expect(ChatFilter.decide(message: close, isEdit: false, chatDisplayName: chatA, ownerMRI: ownerMRI, config: cfg) == .skip(reason: "facilitator-close"))
        let empty = message(chatID: threadA, senderMRI: "8:orgid:someone", senderName: "Masten, Marjorie", content: "")
        #expect(ChatFilter.decide(message: empty, isEdit: false, chatDisplayName: chatA, ownerMRI: ownerMRI, config: cfg) == .skip(reason: "empty-text"))
        let json = message(chatID: "19:abc@thread.v2", senderMRI: "8:orgid:sender", senderName: "Alice", content: #"{"a":1}"#)
        #expect(ChatFilter.decide(message: json, isEdit: false, chatDisplayName: "Alice", ownerMRI: ownerMRI, config: cfg) == .skip(reason: "json-blob"))
    }
}
