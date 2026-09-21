import AppKit
import Foundation
import TeamsCore

/// Rudimentary history viewer: table of notified messages (newest
/// first) + search + detail pane. Menu-bar-only character kept:
/// on-demand window, Cmd-W closes to nothing, no dock change.
@MainActor
final class HistoryWindowController: NSWindowController {
    private static var shared: HistoryWindowController?

    /// Show the window, creating it on first use. Reuses codec
    /// (MessageHistory.parse) for load; activates the app so the
    /// window is visible despite LSUIElement.
    static func show() {
        if shared == nil {
            shared = HistoryWindowController()
        }
        shared?.reload()
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: state

    private var allRecords: [HistoryRecord] = [] // newest first
    private var shownRecords: [HistoryRecord] = [] // filtered + capped
    private var truncated = false
    private var lastMtime: Date?
    private var pollTimer: Timer?

    // MARK: views

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let detailView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "No notifications yet.")

    // Column identifiers.
    private enum Col: String, CaseIterable {
        case time, sender, chat, message
    }

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = "TeamsNotifier history"
        win.center()
        win.isReleasedWhenClosed = false
        // Cmd-W closes: wire the standard close selector explicitly.
        win.standardWindowButton(.closeButton)?.keyEquivalent = "w"
        super.init(window: win)
        buildUI()
        win.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        searchField.placeholderString = "Filter sender, chat, or text"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        for col in Col.allCases {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.rawValue))
            switch col {
            case .time: c.title = "Time"; c.width = 130
            case .sender: c.title = "Sender"; c.width = 140
            case .chat: c.title = "Chat"; c.width = 160
            case .message: c.title = "Message"; c.width = 300
            }
            c.resizingMask = [.userResizingMask]
            if col == .message { c.resizingMask.insert(.autoresizingMask) }
            tableView.addTableColumn(c)
        }
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(copySelectedText)
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = true
        let tableScroll = NSScrollView()
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.documentView = tableView

        detailView.isEditable = false
        detailView.isSelectable = true
        detailView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let detailScroll = NSScrollView()
        detailScroll.hasVerticalScroller = true
        detailScroll.documentView = detailView
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            detailScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 90),
        ])

        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(tableScroll)
        split.addArrangedSubview(detailScroll)
        split.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = NSFont.systemFont(ofSize: 14)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(searchField)
        content.addSubview(split)
        content.addSubview(statusLabel)
        content.addSubview(emptyLabel)
        let g = content.layoutMarginsGuide
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: g.topAnchor),
            searchField.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            split.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            split.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: split.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: g.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: split.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: split.centerYAnchor),
        ])
        split.setPosition(320, ofDividerAt: 0)
    }

    // MARK: load + live update

    /// Reload from disk via the shared codec. Cheap enough to call
    /// on every poll tick that sees a new mtime.
    private func reload() {
        let url = HistoryStore.historyFileURL
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        allRecords = HistoryView.sortedNewestFirst(MessageHistory.parse(text))
        lastMtime = mtime(of: url)
        applyFilter()
    }

    private func mtime(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func applyFilter() {
        // Preserve selection across refreshes by record identity.
        let selected: HistoryRecord? =
            tableView.selectedRow >= 0 && tableView.selectedRow < shownRecords.count
            ? shownRecords[tableView.selectedRow] : nil
        let q = searchField.stringValue
        let filtered = HistoryView.filter(allRecords, query: q)
        // Cap applies to the rendered list; note truncation.
        let cap = HistoryView.capped(filtered)
        shownRecords = cap.rows
        // Truncated only when the FILE has more than rendered, not
        // when the user's filter narrows it.
        truncated = q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && cap.truncated
        tableView.reloadData()
        if let s = selected, let i = shownRecords.firstIndex(of: s) {
            tableView.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        } else if !shownRecords.isEmpty && tableView.selectedRow < 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateDetail()
        let empty = shownRecords.isEmpty
        emptyLabel.isHidden = !empty
        emptyLabel.stringValue =
            allRecords.isEmpty ? "No notifications yet." : "No matches."
        statusLabel.stringValue = HistoryView.statusLine(
            shown: shownRecords.count, total: allRecords.count, truncated: truncated)
    }

    private func updateDetail() {
        let i = tableView.selectedRow
        guard i >= 0, i < shownRecords.count else {
            detailView.string = ""
            return
        }
        let r = shownRecords[i]
        detailView.string = "\(r.sender) in \(r.chat)\n\(HistoryView.formatTime(r.timestamp))\n\n\(r.text)"
    }

    private func startPolling() {
        stopPolling()
        let t = Timer(
            timeInterval: 2.0, target: self,
            selector: #selector(pollTick), userInfo: nil, repeats: true)
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    @objc private func pollTick() {
        guard window?.isVisible == true else { return }
        let url = HistoryStore.historyFileURL
        let m = mtime(of: url)
        if m != lastMtime {
            reload()
        }
    }

    @objc private func searchChanged() {
        applyFilter()
    }

    /// Double-click a row copies its full text.
    @objc private func copySelectedText() {
        let i = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard i >= 0, i < shownRecords.count else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(shownRecords[i].text, forType: .string)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        startPolling()
    }
}

// MARK: - NSTableView

extension HistoryWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        shownRecords.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < shownRecords.count else { return nil }
        let r = shownRecords[row]
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        switch tableColumn?.identifier.rawValue {
        case Col.time.rawValue: cell.textField?.stringValue = HistoryView.formatTime(r.timestamp)
        case Col.sender.rawValue: cell.textField?.stringValue = r.sender
        case Col.chat.rawValue: cell.textField?.stringValue = r.chat
        default: cell.textField?.stringValue = HistoryView.snippet(r.text)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetail()
    }
}

// MARK: - NSWindowDelegate

extension HistoryWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        stopPolling() // closes to nothing; shared instance reopens fresh
    }
}
