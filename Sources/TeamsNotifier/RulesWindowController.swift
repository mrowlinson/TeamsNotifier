import AppKit
import Foundation
import TeamsCore

/// Notify-rules editor: table of rules + Add/Remove + per-row editor
/// (kind, value, enabled switch). Mirrors ScheduleWindowController: edits
/// a draft copy; Save hands it to the app (which syncs the filter
/// scalars, persists to config.json); closing or Cancel discards.
/// Menu-bar-only character kept: on-demand window, Cmd-W closes to
/// nothing, no dock change.
///
/// Guided for new users: an intro line teaches what rules are, a blank
/// state explains that blank = notify everything, Add picks by GOAL in
/// plain words (each choice shows what it does + an example), rows read
/// as sentences, and the editor shows a full description + example per
/// kind with plain-words validation. Display only: persistence,
/// migration, decode, and filter behavior are untouched.
///
/// The kind field is free text with the stock kinds' display names
/// offered for completion (ids store underneath), so NEW rule types
/// are addable (not a fixed set). Unknown kinds store and round-trip;
/// the filter ignores them until a lane implements them.
@MainActor
final class RulesWindowController: NSWindowController {
    private static var shared: RulesWindowController?

    /// Show the editor for a draft of `current`. `onSave` runs on Save
    /// with the validated rules; close/Cancel drops the draft.
    static func show(current: [NotifyRule], onSave: @escaping @MainActor ([NotifyRule]) -> Void) {
        if shared == nil {
            shared = RulesWindowController()
        }
        shared?.beginEditing(rules: current, onSave: onSave)
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: state

    private var draft: [NotifyRule] = []
    private var onSave: (@MainActor ([NotifyRule]) -> Void)?

    // MARK: views

    private let tableView = NSTableView()
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let kindCombo = NSComboBox()
    private let valueLabel = NSTextField(labelWithString: "Value:")
    private let valueField = NSTextField()
    private let enabledCheck = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let introLabel = NSTextField(labelWithString: "")
    private let blankLabel = NSTextField(labelWithString: "")
    private let addDescLabel = NSTextField(labelWithString: "")
    private let descLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private enum Col: String, CaseIterable {
        case on, rule
    }

    /// Default Add-row hint (also restored when the goal menu closes).
    private static let addHint = "Add: pick a goal and the rule builds itself (value prefilled where needed)."

    /// Starter for the goal menu's Custom row: valid (unknown kinds
    /// always validate), renamed in the Kind combo by the owner.
    /// Not a seed: only stored on Save, fresh installs open blank.
    private static let customStarter = NotifyRule(kind: "my-custom-rule")

    /// Width of the longest kind display name in the system font, plus
    /// `extra` for control chrome. Sizes the Kind combo so full names
    /// show without clipping.
    private static func kindDisplayWidth(extra: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let widest = NotifyRule.knownDisplayNames
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return ceil(widest) + extra
    }

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 580),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = "Notify rules"
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
            case .rule: c.title = "Rule"; c.width = 440
            }
            c.resizingMask = [.userResizingMask]
            if col == .rule { c.resizingMask.insert(.autoresizingMask) }
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

        kindCombo.addItems(withObjectValues: NotifyRule.knownDisplayNames)
        kindCombo.numberOfVisibleItems = NotifyRule.knownKinds.count
        kindCombo.completes = true
        kindCombo.delegate = self
        kindCombo.target = self
        kindCombo.action = #selector(kindPicked)
        kindCombo.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            kindCombo.widthAnchor.constraint(equalToConstant: max(150, Self.kindDisplayWidth(extra: 32))),
        ])
        valueField.delegate = self
        valueField.placeholderString = "(ignored)"
        valueField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            valueField.widthAnchor.constraint(equalToConstant: 220),
        ])
        enabledCheck.target = self
        enabledCheck.action = #selector(enabledToggled)
        let editorRow = NSStackView(views: [
            NSTextField(labelWithString: "Kind:"),
            kindCombo,
            valueLabel,
            valueField,
            enabledCheck,
        ])
        editorRow.orientation = .horizontal
        editorRow.spacing = 6

        introLabel.stringValue = "Rules decide what notifies you: each rule quiets something, or narrows what gets through."
        blankLabel.stringValue = NotifyRule.blankStateText
        addDescLabel.stringValue = Self.addHint
        for lab in [introLabel, blankLabel, addDescLabel, descLabel] {
            lab.textColor = .secondaryLabelColor
            lab.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            lab.lineBreakMode = .byWordWrapping
            lab.usesSingleLineMode = false
        }
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.usesSingleLineMode = false
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
            introLabel, tableScroll, blankLabel, rowButtons, addDescLabel,
            editorRow, descLabel, hintLabel, errorLabel, bottomRow,
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
            introLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            introLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            blankLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            blankLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            addDescLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            addDescLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            descLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            descLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            hintLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            bottomRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            bottomRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
    }

    // MARK: editing

    private func beginEditing(rules: [NotifyRule], onSave: @escaping @MainActor ([NotifyRule]) -> Void) {
        draft = rules
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
        kindCombo.isEnabled = has
        valueField.isEnabled = has
        enabledCheck.isEnabled = has
        if has {
            kindCombo.stringValue = NotifyRule.displayName(for: draft[r].kind)
            valueField.stringValue = draft[r].value
            enabledCheck.state = draft[r].enabled ? .on : .off
            refreshKindChrome(kind: draft[r].kind.trimmingCharacters(in: .whitespaces))
        } else {
            kindCombo.stringValue = ""
            valueField.stringValue = ""
            enabledCheck.state = .off
            refreshKindChrome(kind: "")
        }
    }

    /// Description + hint + value-field label/placeholder/enabled for
    /// a kind id. The combo shows display names; free text stays for
    /// custom types.
    private func refreshKindChrome(kind: String) {
        if kind.isEmpty {
            descLabel.stringValue = ""
        } else {
            descLabel.stringValue = Self.describe(kind: kind)
        }
        hintLabel.stringValue = kind.isEmpty ? "" : NotifyRule.hint(for: kind)
        valueLabel.stringValue = NotifyRule.valueLabel(for: kind)
        valueField.placeholderString = NotifyRule.valuePlaceholder(for: kind)
        if selectedRow >= 0 {
            // Known kinds that ignore their value lock the field; custom
            // kinds keep it (extensible payload).
            let canonical = NotifyRule.canonicalKind(kind)
            valueField.isEnabled = !NotifyRule.knownKinds.contains(canonical) || NotifyRule.usesValue(canonical)
        }
    }

    /// Apply the editor controls to the selected row. Valid input updates
    /// the draft; invalid input shows the reason and leaves the draft at
    /// its last valid state (`revertUI` reloads the controls then).
    private func applyEditor(revertUI: Bool) {
        let r = selectedRow
        guard r >= 0 else { return }
        // Display name -> stored id (pasted ids, legacy included,
        // and custom text pass through).
        let kind = NotifyRule.kind(fromDisplayName: kindCombo.stringValue)
        let candidate = NotifyRule(
            kind: kind,
            value: valueField.stringValue.trimmingCharacters(in: .whitespaces),
            enabled: enabledCheck.state == .on)
        refreshKindChrome(kind: kind)
        // Plain-words validation (same validity as issue(); the stored
        // warnings keep issue() untouched).
        if let problem = candidate.plainIssue() {
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

    /// Full-sentence WHAT IT DOES + concrete example for a kind id
    /// (example hidden when the kind ignores its value).
    private static func describe(kind: String) -> String {
        let ex = NotifyRule.exampleText(for: kind)
        return ex.isEmpty ? NotifyRule.explanation(for: kind) : NotifyRule.explanation(for: kind) + " " + ex
    }

    private func updateStatus() {
        blankLabel.isHidden = !draft.isEmpty
        let on = draft.filter(\.enabled).count
        if draft.isEmpty {
            statusLabel.stringValue = "No rules: every message notifies."
        } else {
            statusLabel.stringValue = on == 1
                ? "\(draft.count) rules (1 on)."
                : "\(draft.count) rules (\(on) on)."
        }
    }

    /// Add by GOAL: popup menu of plain-words goals (highlighting one
    /// shows what it does + an example below); each pick appends a
    /// valid rule with its starter value. Custom row for free-text
    /// kinds (renamed in the Kind combo).
    @objc private func addEntry() {
        errorLabel.stringValue = ""
        let menu = NSMenu()
        menu.delegate = self
        for o in NotifyRule.goalOptions {
            let item = NSMenuItem(title: o.goal, action: #selector(goalPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = o.kind
            item.toolTip = o.example.isEmpty ? o.does : o.does + " " + o.example
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let custom = NSMenuItem(title: "Custom rule of my own…", action: #selector(goalPicked(_:)), keyEquivalent: "")
        custom.target = self
        custom.representedObject = ""
        custom.toolTip = Self.describe(kind: Self.customStarter.kind)
        menu.addItem(custom)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: addButton.bounds.height + 4), in: addButton)
    }

    @objc private func goalPicked(_ sender: NSMenuItem) {
        let picked = sender.representedObject as? String ?? ""
        let rule = picked.isEmpty
            ? Self.customStarter
            : NotifyRule(kind: picked, value: NotifyRule.defaultValue(for: picked))
        draft.append(rule)
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

    @objc private func kindPicked() {
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
        let rules = draft
        onSave = nil
        window?.close()
        save(rules)
    }

    @objc private func cancelDraft() {
        onSave = nil
        window?.close()
    }
}

// MARK: - NSTableView

extension RulesWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        draft.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < draft.count else { return nil }
        let rule = draft[row]
        switch tableColumn?.identifier.rawValue {
        case Col.on.rawValue:
            let id = NSUserInterfaceItemIdentifier("oncell")
            let button = (tableView.makeView(withIdentifier: id, owner: nil) as? NSButton) ?? {
                let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleRowEnabled(_:)))
                b.identifier = id
                return b
            }()
            button.state = rule.enabled ? .on : .off
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
            case Col.rule.rawValue:
                cell.textField?.stringValue = NotifyRule.sentence(for: rule)
                cell.textField?.textColor = rule.enabled ? .labelColor : .secondaryLabelColor
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

extension RulesWindowController: NSTextFieldDelegate, NSComboBoxDelegate {
    /// Live validation while typing: valid input applies, invalid input
    /// shows the reason and keeps the draft at its last valid state.
    func controlTextDidChange(_ obj: Notification) {
        applyEditor(revertUI: false)
    }

    /// Popup pick in the kind combo applies immediately (typing is
    /// covered by controlTextDidChange).
    func comboBoxSelectionDidChange(_ notification: Notification) {
        applyEditor(revertUI: false)
    }
}

extension RulesWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        onSave = nil // closes to nothing; next show() reconfigures
    }
}

// MARK: - goal menu highlight

extension RulesWindowController: NSMenuDelegate {
    /// Highlighting a goal shows its WHAT IT DOES + example in the
    /// Add hint line, so each choice explains itself before the pick.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard let kind = item?.representedObject as? String else {
            addDescLabel.stringValue = Self.addHint
            return
        }
        addDescLabel.stringValue = kind.isEmpty
            ? Self.describe(kind: Self.customStarter.kind)
            : Self.describe(kind: kind)
    }

    func menuDidClose(_ menu: NSMenu) {
        addDescLabel.stringValue = Self.addHint
    }
}
