import Foundation
import Testing
@testable import TeamsCore

private let utc = TimeZone(identifier: "UTC")!

@Suite("Chat window registry (one window per chat)")
struct ChatWindowRegistryTests {
    @Test func openNewOpens() {
        var r = ChatWindowRegistry()
        let res = r.open(chatID: "a")
        #expect(res == .opened)
        #expect(r.isOpen(chatID: "a"))
    }

    @Test func reopenFocusesExisting() {
        var r = ChatWindowRegistry()
        _ = r.open(chatID: "a")
        let res = r.open(chatID: "a")
        #expect(res == .focused)
    }

    @Test func distinctChatsBothOpen() {
        var r = ChatWindowRegistry()
        let ra = r.open(chatID: "a")
        let rb = r.open(chatID: "b")
        #expect(ra == .opened)
        #expect(rb == .opened)
        #expect(r.isOpen(chatID: "a") && r.isOpen(chatID: "b"))
    }

    @Test func closeThenOpenIsFreshOpen() {
        var r = ChatWindowRegistry()
        _ = r.open(chatID: "a")
        r.close(chatID: "a")
        #expect(!r.isOpen(chatID: "a"))
        let res = r.open(chatID: "a")
        #expect(res == .opened)
    }

    @Test func closeUnknownIsNoop() {
        var r = ChatWindowRegistry()
        r.close(chatID: "missing")
        #expect(!r.isOpen(chatID: "missing"))
    }
}

@Suite("Chat window history codec")
struct ChatWindowHistoryTests {
    @Test func urlShapesEndpoint() {
        let u = ChatWindowHistory.url(
            chatServiceBase: "https://amer.ng.msg.teams.microsoft.com",
            chatID: "19:abc@thread.v2")?.absoluteString
        #expect(u == "https://amer.ng.msg.teams.microsoft.com/v1/users/ME/conversations/19%3Aabc@thread.v2/messages?pageSize=50")
    }

    @Test func urlHonorsPageSize() {
        let u = ChatWindowHistory.url(chatServiceBase: "https://x", chatID: "c", pageSize: 10)?.absoluteString
        #expect(u == "https://x/v1/users/ME/conversations/c/messages?pageSize=10")
    }

    @Test func isTextMessage() {
        #expect(ChatWindowHistory.isTextMessage(type: "Text"))
        #expect(ChatWindowHistory.isTextMessage(type: "RichText/Html"))
        #expect(!ChatWindowHistory.isTextMessage(type: "ThreadActivity/MemberJoin"))
        #expect(!ChatWindowHistory.isTextMessage(type: "Control/Typing"))
        #expect(!ChatWindowHistory.isTextMessage(type: ""))
    }

    @Test func parseResponseIsChronological() {
        let body = """
        {"messages": [
          {"id": "new", "imdisplayname": "B", "content": "<p>second</p>", "messagetype": "RichText/Html", "composetime": "2026-09-21T12:01:00.000Z"},
          {"id": "old", "imdisplayname": "A", "content": "first", "messagetype": "Text", "composetime": "2026-09-21T12:00:00.000Z"}
        ]}
        """
        let msgs = ChatWindowHistory.parseMessagesResponse(Data(body.utf8))
        #expect(msgs.map(\.id) == ["old", "new"])
        #expect(msgs[0].sender == "A" && msgs[0].text == "first")
        #expect(msgs[1].text == "second")
    }

    @Test func parseSkipsNonTextAndEmpty() {
        let body = """
        {"messages": [
          {"id": "t", "imdisplayname": "A", "content": "keep", "messagetype": "Text"},
          {"id": "a", "imdisplayname": "", "content": "joined", "messagetype": "ThreadActivity/MemberJoin"},
          {"id": "e", "imdisplayname": "A", "content": "   ", "messagetype": "Text"},
          {"id": "h", "imdisplayname": "A", "content": "<p></p>", "messagetype": "RichText/Html"}
        ]}
        """
        let msgs = ChatWindowHistory.parseMessagesResponse(Data(body.utf8))
        #expect(msgs.map(\.id) == ["t"])
    }

    @Test func parseCorruptIsEmpty() {
        #expect(ChatWindowHistory.parseMessagesResponse(Data("nope".utf8)).isEmpty)
        #expect(ChatWindowHistory.parseMessagesResponse(Data("{}".utf8)).isEmpty)
        #expect(ChatWindowHistory.parseMessagesResponse(Data("{\"messages\":{}}".utf8)).isEmpty)
    }

    @Test func parseDateShapes() {
        #expect(ChatWindowHistory.parseDate("2026-09-21T12:34:56.789Z") != nil)
        #expect(ChatWindowHistory.parseDate("2026-09-21T12:34:56Z") != nil)
        #expect(ChatWindowHistory.parseDate("") == nil)
        #expect(ChatWindowHistory.parseDate("not-a-date") == nil)
    }

    @Test func formatLineTimed() {
        let d = ChatWindowHistory.parseDate("2026-09-21T12:34:56.000Z")!
        let line = ChatWindowHistory.formatLine(
            ChatMessage(id: "1", sender: "Al", text: "hi", date: d), timeZone: utc)
        #expect(line == "[12:34] Al: hi")
    }

    @Test func formatLineUntimedAndUnknownSender() {
        #expect(ChatWindowHistory.formatLine(ChatMessage(id: "1", sender: "", text: "hi")) == "?: hi")
        #expect(ChatWindowHistory.formatLine(ChatMessage(id: "1", sender: "Al", text: "hi")) == "Al: hi")
    }

    @Test func transcriptJoinsBlankLine() {
        let t = ChatWindowHistory.transcript([
            ChatMessage(id: "1", sender: "A", text: "one"),
            ChatMessage(id: "2", sender: "B", text: "two"),
        ], timeZone: utc)
        #expect(t == "A: one\n\nB: two")
    }
}

@Suite("Chat window state (history load, live append, edits)")
struct ChatWindowStateTests {
    @Test func loadHistoryReplacesAndDedupes() {
        var s = ChatWindowState(chatID: "c")
        s.loadHistory([
            ChatMessage(id: "1", sender: "A", text: "one"),
            ChatMessage(id: "1", sender: "A", text: "one-dup"),
            ChatMessage(id: "", sender: "B", text: "untracked"),
            ChatMessage(id: "2", sender: "B", text: "two"),
        ])
        #expect(s.messages.map(\.text) == ["one", "untracked", "two"])
        // Second load replaces, not appends.
        s.loadHistory([ChatMessage(id: "3", sender: "C", text: "fresh")])
        #expect(s.messages.map(\.id) == ["3"])
    }

    @Test func appendLiveDedupesByID() {
        var s = ChatWindowState(chatID: "c")
        let first = s.appendLive(ChatMessage(id: "1", sender: "A", text: "one"))
        let echo = s.appendLive(ChatMessage(id: "1", sender: "A", text: "echo"))
        #expect(first)
        #expect(!echo)
        #expect(s.messages.count == 1)
        // Empty ids cannot dedupe: always appended.
        let u1 = s.appendLive(ChatMessage(id: "", sender: "B", text: "x"))
        let u2 = s.appendLive(ChatMessage(id: "", sender: "B", text: "x"))
        #expect(u1 && u2)
        #expect(s.messages.count == 3)
    }

    @Test func editReplacesInPlace() {
        var s = ChatWindowState(chatID: "c", messages: [
            ChatMessage(id: "1", sender: "A", text: "one"),
            ChatMessage(id: "2", sender: "B", text: "two"),
        ])
        let applied = s.applyEdit(ChatMessage(id: "1", sender: "A", text: "one-fixed"))
        #expect(applied)
        #expect(s.messages.map(\.text) == ["one-fixed", "two"])
    }

    @Test func editUnknownIsIgnoredNotAppended() {
        var s = ChatWindowState(chatID: "c", messages: [
            ChatMessage(id: "1", sender: "A", text: "one"),
        ])
        let ghost = s.applyEdit(ChatMessage(id: "9", sender: "Z", text: "ghost"))
        let untracked = s.applyEdit(ChatMessage(id: "", sender: "Z", text: "ghost"))
        #expect(!ghost)
        #expect(!untracked)
        #expect(s.messages.map(\.id) == ["1"])
    }

    @Test func closeReopenKeepsMessages() {
        var s = ChatWindowState(chatID: "c", messages: [
            ChatMessage(id: "1", sender: "A", text: "one"),
        ])
        s.close()
        #expect(!s.isOpen)
        s.reopen()
        #expect(s.isOpen)
        #expect(s.messages.map(\.id) == ["1"])
    }
}

@Suite("Chat window send path")
struct ChatWindowSendTests {
    @Test func payloadTrimsAndBuilds() {
        let p = ChatWindowSend.payload(chatID: "c", text: "  hi  ", clientMessageID: "7")
        #expect(p?["content"] == "<p>hi</p>")
        #expect(p?["messagetype"] == "RichText/Html")
        #expect(p?["clientmessageid"] == "7")
    }

    @Test func payloadGatesEmpty() {
        #expect(ChatWindowSend.payload(chatID: "", text: "hi", clientMessageID: "1") == nil)
        #expect(ChatWindowSend.payload(chatID: "c", text: "   ", clientMessageID: "1") == nil)
    }
}

@Suite("Open chat notification constants")
struct OpenChatConstantsTests {
    @Test func ids() {
        #expect(ReplyInfo.openActionID == "TN_OPEN_CHAT")
        #expect(ReplyInfo.openActionTitle == "Open chat")
    }
}
