import AppKit
import Foundation
import TeamsCore

/// Basic mute-schedule editor: table of entries + Add/Remove + per-row
/// editor (days, start/end, enabled switch). Edits a draft copy; Save
/// hands it to the app (which persists to config.json and re-resolves
/// mute state); closing or Cancel discards. Menu-bar-only character
/// kept: on-demand window, Cmd-W closes to nothing, no dock change.
@MainActor
final class ScheduleWindowController: NSWindowController {
    private static var shared: ScheduleWindowController?

    /// Show the editor for a draft of `current`. `onSave` runs on Save
    /// with the validated entries; close/Cancel drops the draft.
    static func show(current: [MuteWindow], onSave: @escaping @MainActor ([MuteWindow]) -> Void) {
        if shared == nil {
            shared = ScheduleWindowController()
        }
        shared?.beginEditing(windows: current, onSave: onSave)
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: state

    private var draft: [MuteWindow] = []
    private var onSave: (@MainActor ([MuteWindow]) -> Void)?

    // MARK: views

    private let tableView = NSTableView()
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private var dayChecks: [NSButton] = []
    private let startField = NSTextField()
    private let endField = NSTextField()
    private let enabledCheck = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let errorLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private enum Col: String, CaseIterable {
        case on, days, start, end
    }

    /// Template for the Add button: a valid single-hour Monday entry the
    /// owner reshapes. Not a seeded schedule (fresh installs stay empty).
    private static let template = MuteWindow(days: [2], start: "12:00", end: "13:00")

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = "Mute schedule"
        win.center()
        win.isReleasedWhenClosed = false
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

        for col in Col.allCases {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.rawValue))
            switch col {
            case .on: c.title = "On"; c.width = 36
            case .days: c.title = "Days"; c.width = 180
            case .start: c.title = "Start"; c.width = 70
            case .end: c.title = "End"; c.width = 70
            }
            c.resizingMask = [.userResizingMask]
            if col == .days { c.resizingMask.insert(.autoresizingMask) }
            tableView.addTableColumn(c)
        }
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = true
        let tableScroll = NSScrollView()
        tableScroll.hasVerticalScroller = true
        tableScroll.documentView = tableView
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])

        addButton.target = self
        addButton.action = #selector(addEntry)
        removeButton.target = self
        removeButton.action = #selector(removeEntry)
        let rowButtons = NSStackView(views: [addButton, removeButton])
        rowButtons.orientation = .horizontal
        rowButtons.spacing = 8

        let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        var dayViews: [NSView] = []
        for (i, name) in dayNames.enumerated() {
            let b = NSButton(checkboxWithTitle: name, target: self, action: #selector(dayToggled(_:)))
            b.tag = i + 1 // Calendar weekday: Sun=1 ... Sat=7
            dayChecks.append(b)
            dayViews.append(b)
        }
        let dayRow = NSStackView(views: dayViews)
        dayRow.orientation = .horizontal
        dayRow.spacing = 4

        startField.placeholderString = "HH:MM"
        endField.placeholderString = "HH:MM (24:00 ok)"
        for f in [startField, endField] {
            f.delegate = self
            f.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                f.widthAnchor.constraint(equalToConstant: 90),
            ])
        }
        enabledCheck.target = self
        enabledCheck.action = #selector(enabledToggled)
        let timeRow = NSStackView(views: [
            NSTextField(labelWithString: "Start:"),
            startField,
            NSTextField(labelWithString: "End:"),
            endField,
            enabledCheck,
        ])
        timeRow.orientation = .horizontal
        timeRow.spacing = 6

        errorLabel.textColor = .systemRed
        errorLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        saveButton.target = self
        saveButton.action = #selector(saveDraft)
        saveButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelDraft)
        cancelButton.keyEquivalent = "\u{1b}"
        let bottomRow = NSStackView(views: [statusLabel, NSView(), cancelButton, saveButton])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 8

        let stack = NSStackView(views: [
            tableScroll, rowButtons, dayRow, timeRow, errorLabel, bottomRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        let g = content.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: g.topAnchor),
            stack.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: g.bottomAnchor),
            tableScroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            bottomRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            bottomRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
    }

    // MARK: editing

    private func beginEditing(windows: [MuteWindow], onSave: @escaping @MainActor ([MuteWindow]) -> Void) {
        draft = windows
        self.onSave = onSave
        tableView.reloadData()
        if !draft.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        loadEditor()
        updateStatus()
    }

    private var selectedRow: Int {
        let r = tableView.selectedRow
        return (0 ..< draft.count).contains(r) ? r : -1
    }

    /// Load the editor controls from the selected draft row (or disable
    /// them when nothing is selected). Clears any error.
    private func loadEditor() {
        errorLabel.stringValue = ""
        let r = selectedRow
        let has = r >= 0
        removeButton.isEnabled = has
        for b in dayChecks {
            b.isEnabled = has
            b.state = (has && draft[r].days.contains(b.tag)) ? .on : .off
        }
        startField.isEnabled = has
        endField.isEnabled = has
        enabledCheck.isEnabled = has
        if has {
            startField.stringValue = draft[r].start
            endField.stringValue = draft[r].end
            enabledCheck.state = draft[r].enabled ? .on : .off
        } else {
            startField.stringValue = ""
            endField.stringValue = ""
            enabledCheck.state = .off
        }
    }

    /// Apply the editor controls to the selected row. Valid input updates
    /// the draft; invalid input shows the reason and leaves the draft at
    /// its last valid state (`revertUI` reloads the controls then).
    private func applyEditor(revertUI: Bool) {
        let r = selectedRow
        guard r >= 0 else { return }
        let days = dayChecks.filter { $0.state == .on }.map(\.tag)
        let candidate = MuteWindow(
            days: days,
            start: startField.stringValue.trimmingCharacters(in: .whitespaces),
            end: endField.stringValue.trimmingCharacters(in: .whitespaces),
            enabled: enabledCheck.state == .on)
        if let problem = candidate.issue() {
            errorLabel.stringValue = problem
            if revertUI { loadEditorKeepingError() }
            return
        }
        errorLabel.stringValue = ""
        draft[r] = candidate
        tableView.reloadData(forRowIndexes: IndexSet(integer: r), columnIndexes: IndexSet(integersIn: 0 ..< Col.allCases.count))
        updateStatus()
    }

    /// Reload controls from the draft but keep the error text (so a bad
    /// discrete toggle visibly snaps back with its reason shown).
    private func loadEditorKeepingError() {
        let kept = errorLabel.stringValue
        loadEditor()
        errorLabel.stringValue = kept
    }

    private func updateStatus() {
        let on = draft.filter(\.enabled).count
        if draft.isEmpty {
            statusLabel.stringValue = "Empty schedule: never muted."
        } else {
            statusLabel.stringValue = on == 1
                ? "\(draft.count) entries (1 on)."
                : "\(draft.count) entries (\(on) on)."
        }
    }

    @objc private func addEntry() {
        errorLabel.stringValue = ""
        draft.append(Self.template)
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: draft.count - 1), byExtendingSelection: false)
        loadEditor()
        updateStatus()
    }

    @objc private func removeEntry() {
        let r = selectedRow
        guard r >= 0 else { return }
        draft.remove(at: r)
        tableView.reloadData()
        if !draft.isEmpty {
            tableView.selectRowIndexes(
                IndexSet(integer: min(r, draft.count - 1)), byExtendingSelection: false)
        }
        loadEditor()
        updateStatus()
    }

    @objc private func dayToggled(_ sender: NSButton) {
        applyEditor(revertUI: true)
    }

    @objc private func enabledToggled() {
        applyEditor(revertUI: true)
    }

    @objc private func toggleRowEnabled(_ sender: NSButton) {
        let r = sender.tag
        guard (0 ..< draft.count).contains(r) else { return }
        draft[r].enabled.toggle()
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: r),
            columnIndexes: IndexSet(integersIn: 0 ..< Col.allCases.count))
        if r == selectedRow {
            enabledCheck.state = draft[r].enabled ? .on : .off
        }
        updateStatus()
    }

    @objc private func saveDraft() {
        // Draft rows are always valid (applyEditor only stores valid
        // candidates), so Save persists exactly what the table shows.
        // Callback runs after close (no state depends on the window).
        guard let save = onSave else { window?.close(); return }
        let windows = draft
        onSave = nil
        window?.close()
        save(windows)
    }

    @objc private func cancelDraft() {
        onSave = nil
        window?.close()
    }
}

// MARK: - NSTableView

extension ScheduleWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        draft.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < draft.count else { return nil }
        let w = draft[row]
        switch tableColumn?.identifier.rawValue {
        case Col.on.rawValue:
            let id = NSUserInterfaceItemIdentifier("oncell")
            let button = (tableView.makeView(withIdentifier: id, owner: nil) as? NSButton) ?? {
                let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleRowEnabled(_:)))
                b.identifier = id
                return b
            }()
            button.state = w.enabled ? .on : .off
            button.tag = row
            return button
        default:
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
            case Col.days.rawValue: cell.textField?.stringValue = w.daysLabel
            case Col.start.rawValue: cell.textField?.stringValue = w.start
            case Col.end.rawValue: cell.textField?.stringValue = w.end
            default: break
            }
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        loadEditor()
    }
}

// MARK: - editor text + close

extension ScheduleWindowController: NSTextFieldDelegate {
    /// Live validation while typing: valid input applies, invalid input
    /// shows the reason and keeps the draft at its last valid state.
    func controlTextDidChange(_ obj: Notification) {
        applyEditor(revertUI: false)
    }
}

extension ScheduleWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        onSave = nil // closes to nothing; next show() reconfigures
    }
}
