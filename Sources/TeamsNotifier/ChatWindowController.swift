import AppKit
import Foundation
import TeamsCore

/// Per-chat conversation window: full history on open, live trouter
/// appends while open, send box at the bottom. One window per chat:
/// re-show focuses the existing window. Opened from the notification
/// "Open chat" action; close anytime (Cmd-W), the next notification
/// from that chat reopens it. Stays open indefinitely (no timers).
/// Menu-bar-only character kept: on-demand window, closes to nothing,
/// no dock change.
@MainActor
final class ChatWindowController: NSWindowController {
    private static var windows: [String: ChatWindowController] = [:]

    /// Show the window for a chat, focusing the existing one when open.
    /// First open loads full history via `api` (nil = offline: seed only).
    static func show(chatID: String, title: String, api: TeamsAPI?, seed: [ChatMessage] = []) {
        if let existing = windows[chatID] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let wc = ChatWindowController(chatID: chatID, title: title, api: api, seed: seed)
        windows[chatID] = wc
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await wc.loadHistory() }
    }

    /// Live trouter fan-out from App.handleMessage. No-op when the chat
    /// has no open window; dedupes redeliveries by message id.
    static func deliver(chatID: String, message: ChatMessage, isEdit: Bool) {
        guard let wc = windows[chatID] else { return }
        if isEdit {
            if wc.state.applyEdit(message) { wc.render() }
        } else {
            if wc.state.appendLive(message) { wc.render() }
        }
    }

    static func isOpen(chatID: String) -> Bool { windows[chatID] != nil }

    /// Offline smoke-test window (menu "Show demo chat", --chat-demo).
    static func showDemo() {
        show(chatID: ChatDemoMessages.chatID, title: "Demo chat", api: nil, seed: ChatDemoMessages.sample)
    }

    // MARK: state

    private let chatID: String
    private let api: TeamsAPI?
    private var state: ChatWindowState

    // MARK: views

    private let transcriptView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let inputField = NSTextField()
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)

    init(chatID: String, title: String, api: TeamsAPI?, seed: [ChatMessage] = []) {
        self.chatID = chatID
        self.api = api
        var s = ChatWindowState(chatID: chatID)
        s.loadHistory(seed)
        self.state = s
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = title.isEmpty ? chatID : title
        win.center()
        win.isReleasedWhenClosed = false
        win.standardWindowButton(.closeButton)?.keyEquivalent = "w"
        super.init(window: win)
        buildUI()
        render()
        win.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        transcriptView.isEditable = false
        transcriptView.isSelectable = true
        transcriptView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        // Bare NSTextView() has a zero frame and a zero-width text
        // container: no layout, empty transcript. Standard
        // NSTextView-in-NSScrollView setup so the view tracks the
        // scroller width and grows vertically.
        transcriptView.isVerticallyResizable = true
        transcriptView.isHorizontallyResizable = false
        transcriptView.autoresizingMask = [.width]
        let transcriptScroll = NSScrollView()
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.hasHorizontalScroller = false
        transcriptScroll.autohidesScrollers = true
        transcriptScroll.documentView = transcriptView
        transcriptScroll.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        inputField.placeholderString = "Type a message…"
        inputField.target = self
        inputField.action = #selector(sendClicked)
        inputField.translatesAutoresizingMaskIntoConstraints = false

        sendButton.target = self
        sendButton.action = #selector(sendClicked)
        sendButton.keyEquivalent = "\r"
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sendButton.widthAnchor.constraint(equalToConstant: 80),
        ])

        let sendRow = NSStackView(views: [inputField, sendButton])
        sendRow.orientation = .horizontal
        sendRow.spacing = 8
        sendRow.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(transcriptScroll)
        content.addSubview(statusLabel)
        content.addSubview(sendRow)
        let g = content.layoutMarginsGuide
        NSLayoutConstraint.activate([
            transcriptScroll.topAnchor.constraint(equalTo: g.topAnchor),
            transcriptScroll.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            transcriptScroll.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: transcriptScroll.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            sendRow.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            sendRow.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            sendRow.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            sendRow.bottomAnchor.constraint(equalTo: g.bottomAnchor),
        ])
        // The scroll view still has a zero frame here (autolayout not
        // run): proportional autoresizing from a zero superview leaves
        // the document view collapsed. Force layout, then fit the text
        // view to the real content size; autoresizing [.width] tracks
        // later resizes once both sizes are nonzero.
        content.layoutSubtreeIfNeeded()
        let cs = transcriptScroll.contentSize
        transcriptView.minSize = NSSize(width: 0, height: cs.height)
        transcriptView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        transcriptView.frame = NSRect(x: 0, y: 0, width: cs.width, height: max(cs.height, 1))
        transcriptView.textContainer?.containerSize = NSSize(width: cs.width, height: CGFloat.greatestFiniteMagnitude)
        transcriptView.textContainer?.widthTracksTextView = true
    }

    // MARK: history + live

    private func loadHistory() async {
        guard let api else {
            statusLabel.stringValue = state.messages.isEmpty
                ? "Offline — no history available."
                : "Demo chat — sending unavailable offline."
            return
        }
        statusLabel.stringValue = "Loading history…"
        do {
            let fetched = try await api.fetchMessages(chatID: chatID)
            state.loadHistory(fetched)
            render()
            statusLabel.stringValue = fetched.isEmpty
                ? "No messages yet."
                : "\(fetched.count) messages."
        } catch {
            statusLabel.stringValue = "History failed: \(TeamsAPI.reason(for: error))"
            Log.fault("chat history failed for \(chatID): \(error)")
        }
    }

    private func render() {
        transcriptView.string = ChatWindowHistory.transcript(state.messages)
        transcriptView.scrollToEndOfDocument(nil)
    }

    private func appendLive(_ m: ChatMessage) {
        if state.appendLive(m) { render() }
    }

    // MARK: send

    @objc private func sendClicked() {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let api else {
            statusLabel.stringValue = "Offline — sending unavailable."
            return
        }
        guard ReplyGate.canReply(chatID: chatID, text: text) else { return }
        inputField.stringValue = ""
        inputField.isEnabled = false
        sendButton.isEnabled = false
        statusLabel.stringValue = "Sending…"
        Task {
            do {
                try await api.sendReply(chatID: chatID, text: text)
                appendLive(ChatMessage(
                    id: ReplyPayload.clientMessageID(),
                    sender: "You", text: text, date: Date()))
                statusLabel.stringValue = ""
            } catch {
                statusLabel.stringValue = "Send failed: \(TeamsAPI.reason(for: error))"
                inputField.stringValue = text // restore so nothing is lost
                Log.fault("chat-window send failed: \(error)")
            }
            inputField.isEnabled = true
            sendButton.isEnabled = true
        }
    }
}

// MARK: - close

extension ChatWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Drop the registry entry so the next notification reopens fresh.
        Self.windows[chatID] = nil
    }
}

/// Canned conversation for the offline demo window (menu + --chat-demo).
enum ChatDemoMessages {
    static let chatID = "demo-chat"

    static var sample: [ChatMessage] {
        let now = Date()
        return [
            ChatMessage(
                id: "demo-1", sender: "Alice",
                text: "Hey, did you see the deploy go out?",
                date: now.addingTimeInterval(-3600)),
            ChatMessage(
                id: "demo-2", sender: "You",
                text: "Not yet — looking now.",
                date: now.addingTimeInterval(-3000)),
            ChatMessage(
                id: "demo-3", sender: "Alice",
                text: "All green on my side. Shipping it.",
                date: now.addingTimeInterval(-2400)),
        ]
    }
}
