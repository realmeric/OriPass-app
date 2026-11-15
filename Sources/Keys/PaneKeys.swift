import AppKit

/// What a bare key means in the column that has the keys (`docs/look.md`,
/// "The keyboard"). Up and down move within the column: a row of the
/// sidebar, an item, a field of the item. Left and right move between the
/// columns. Return and Space go into what is chosen, sidebar to list and list
/// to details, and in the details copy the field, which is what a click on
/// it does. The keys never leave the list's own view (`ListKeys`); the
/// column is a word here and a ring on the screen.
extension Panes {
    /// False when the key was nobody's, and the window may beep.
    @discardableResult
    func press(_ key: PaneKey) -> Bool {
        if showsKeys {
            // The sheet takes Esc and swallows the rest.
            if key == .escape { showsKeys = false }
            return true
        }
        if choosing != nil {
            if key == .escape { choosing = nil }
            return true
        }
        if reading.history != nil {
            if key == .escape { closeHistory() }
            return true
        }
        if generator?.purpose == .alone {
            if key == .escape { endGenerating() }
            return true
        }
        // Another item, or none, has taken the place of the one whose field
        // had the keys.
        if focus == .details, detail == nil || reading.cursor == nil { focus = .list }
        switch key {
        case .escape:
            return dismiss()
        case .delete:
            // On a row that cannot go to the Archive it is still the
            // window's key and not a beep.
            if focus != .sidebar { archiveSelected() }
            return true
        case .up, .down:
            showsFocus = true
            move(by: key == .down ? 1 : -1)
        case .left:
            showsFocus = true
            switch focus {
            case .details: leaveDetails()
            case .list where sidebarIsOut: focus = .sidebar
            default: break
            }
        case .right:
            showsFocus = true
            switch focus {
            case .sidebar: focus = .list
            case .list: enterDetails()
            case .details: break
            }
        case .enter, .space:
            showsFocus = true
            activate()
        }
        return true
    }

    private func move(by step: Int) {
        switch focus {
        case .sidebar: moveRow(by: step)
        case .list: moveSelection(by: step)
        case .details: moveField(by: step)
        }
    }

    /// The sidebar's rows as they are drawn, the vaults among them only
    /// while VAULTS is open.
    var sidebarRows: [SidebarRow] {
        upperRows + (vaultsFolded ? [] : vaults.map { .vault($0.id) }) + lowerRows
    }

    /// A vault selected under a folded heading has no row of its own, and
    /// the arrows leave it for the rows on either side of the heading.
    private func moveRow(by step: Int) {
        let rows = sidebarRows
        guard let place = rows.firstIndex(of: selection) else {
            if let row = step > 0 ? lowerRows.first : upperRows.last { select(row, moving: true) }
            return
        }
        select(rows[min(max(place + step, 0), rows.count - 1)], moving: true)
    }

    private func moveField(by step: Int) {
        guard let rows = detail?.stops, !rows.isEmpty else { return }
        let place = reading.cursor.flatMap(rows.firstIndex(of:))
            .map { min(max($0 + step, 0), rows.count - 1) } ?? (step > 0 ? 0 : rows.count - 1)
        reading.cursor = rows[place]
    }

    /// Into the details, onto the field it was on or the first. An item with
    /// no field to copy keeps the keys in the list.
    private func enterDetails() {
        if selectedItem == nil { moveSelection(by: 1) }
        guard let rows = detail?.stops, let first = rows.first else { return }
        focus = .details
        if reading.cursor.map(rows.contains) != true { reading.cursor = first }
    }

    private func leaveDetails() {
        focus = .list
        reading.cursor = nil
    }

    private func activate() {
        switch focus {
        case .sidebar:
            focus = .list
            if selectedItem == nil { moveSelection(by: 1) }
        case .list:
            enterDetails()
        case .details:
            if let row = reading.cursor { copy(row) }
        }
    }

    /// A click on a row of the sidebar: the row, and the arrows with it.
    func click(_ row: SidebarRow) {
        select(row)
        focus = .sidebar
        showsFocus = false
        reading.cursor = nil
    }

    // MARK: The table of keys

    /// ⌘/, which also puts it away.
    func toggleKeys() {
        openMenu = nil
        detailMenu = nil
        reading.menu = nil
        showsKeys.toggle()
    }

    /// What the sheet lists: the rows of the table that work, with the
    /// keys the menu bar has them on, ⌥ only while the setting that makes
    /// it reveal is on, and ⌘C's row saying email while the item in the
    /// details is a login whose username is one.
    var keyCommands: [KeyCommand] {
        KeyTable.working.filter { $0.id != .peek || optionWatch != nil }
            .map { KeyTable.asBound($0, in: NSApp.mainMenu) }
            .map { command in
                guard command.id == .copy else { return command }
                var named = command
                named.name = KeyTable.copyName(forUsername: detail?.item.login?.username)
                return named
            }
    }
}
