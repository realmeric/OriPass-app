import AppKit

/// What a row's menu can ask of it (`docs/look.md`, "A field under the
/// pointer").
enum FieldAction: Equatable {
    case reveal, conceal, largeType, open, history
    /// An attachment's two.
    case quickLook, saveAs

    var name: String {
        switch self {
        case .reveal: return "Reveal"
        case .conceal: return "Conceal"
        case .largeType: return "Show in Large Type"
        case .open: return "Open in Browser"
        case .history: return "View password history"
        case .quickLook: return "Quick Look"
        case .saveAs: return "Save As…"
        }
    }
}

/// The menu standing open under a row's chevron.
struct FieldMenu: Equatable {
    let row: String
    let actions: [FieldAction]
    /// The row of it under the pointer.
    var highlighted: FieldAction?
}

/// What is being done to the item in the details, apart from which item it
/// is: the rows standing revealed, the row under the pointer, the row the
/// keys are on, its menu, the
/// row just copied, and the value up in Large Type. It is the panes', so it
/// goes with them at the lock, and they empty it when another item is chosen.
/// Kept apart from them so that a pointer crossing a row draws the details
/// again and not the list.
@MainActor
final class Reading: ObservableObject {
    @Published var revealed: Set<String> = []
    /// ⌥ is down, and the setting says that shows everything.
    @Published var isPeeking = false
    @Published var hovered: String?
    /// The row the keys are on, once → has brought them into the details.
    @Published var cursor: String?
    @Published var menu: FieldMenu?
    /// The row that says "Copied" for a moment.
    @Published var copied: String?
    @Published var largeType: LargeType?
    /// The earlier passwords, while the sheet that lists them is up.
    @Published var history: PasswordHistory?
    /// The attachments the engine is being asked for, by row.
    @Published var fetching: Set<String> = []
    /// What the engine said of an attachment it would not hand over, by row.
    @Published var unfetched: [String: String] = [:]
    /// The file being added to the item, or the one that was refused.
    @Published var adding: Adding?

    func shows(_ row: String) -> Bool { isPeeking || revealed.contains(row) }
}

/// ⌥ going down and coming up while the app has the keys. The app is told
/// only of keys pressed in its own windows, so leaving it counts as letting
/// go. It exists only while the setting is on and the vault is open.
@MainActor
final class OptionWatch {
    private var monitor: Any?
    private var leaving: NSObjectProtocol?
    private let registrations: [Instruments.Registration]

    init(changed: @escaping (Bool) -> Void) {
        registrations = [
            Instruments.register("option", kind: .observer, owner: "Reveal"),
            Instruments.register("resigned", kind: .observer, owner: "Reveal"),
        ]
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            changed(Self.isHeld(event.modifierFlags))
            return event
        }
        leaving = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                         object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { changed(false) }
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let leaving { NotificationCenter.default.removeObserver(leaving) }
    }

    /// ⌥ and nothing with it: ⌥⌘C is a copy and not a look.
    static func isHeld(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == .option
    }
}

extension Panes {
    // MARK: Copying

    /// A click on a row, and what the three keys come down to: the row's
    /// value to the pasteboard, and "Copied" on the row for a moment. False
    /// when the row holds nothing to copy. An item that asks is answered
    /// for first, and the copy is made when it has been.
    @discardableResult
    func copy(_ row: String) -> Bool {
        guard detail?.value(of: row) != nil else { return false }
        guarded(.copy) { $0.copyNow(row) }
        return true
    }

    private func copyNow(_ row: String) {
        // A one-time code is the one that stands now, and not the one that
        // stood when the item was asked about.
        guard let value = detail?.value(of: row, at: store.now()) else { return }
        clipboard.copy(value)
        reading.menu = nil
        reading.copied = row
        acknowledge()
    }

    /// "Copied", on a row or on an earlier password, for its moment. One
    /// copy at a time says it, so the one before is taken back at once.
    func acknowledge() {
        acknowledging?.cancel()
        let moment = acknowledgement
        acknowledging = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(moment * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.reading.copied = nil
            if self.reading.history?.copied != nil { self.reading.history?.copied = nil }
        }
    }

    /// ⌘C: the username, or the type's first field.
    @discardableResult
    func copyPrimary() -> Bool {
        detail?.primaryRow.map(copy) ?? false
    }

    /// ⇧⌘C.
    @discardableResult
    func copyPassword() -> Bool {
        detail?.passwordRowID.map(copy) ?? false
    }

    /// ⌥⌘C: the one-time code that stands at this instant.
    @discardableResult
    func copyCode() -> Bool {
        detail?.codeRowID.map(copy) ?? false
    }

    // MARK: Revealing

    var canReveal: Bool { editor != nil || detail?.hiddenRows.isEmpty == false }

    /// Whether ⌘R would now conceal.
    var isAllRevealed: Bool {
        if let editor { return editor.isAllRevealed }
        guard let hidden = detail?.hiddenRows, !hidden.isEmpty else { return false }
        return reading.revealed.isSuperset(of: hidden)
    }

    /// ⌘R: every hidden field of the item shown, or every one hidden again
    /// if they were all showing.
    func toggleRevealed() {
        if let editor { return editor.toggleRevealed() }
        guard let hidden = detail?.hiddenRows, !hidden.isEmpty else { return }
        // Hiding is asked of nobody.
        guard !isAllRevealed else { return reading.revealed = [] }
        guarded(.reveal) { panes in
            guard let hidden = panes.detail?.hiddenRows else { return }
            panes.reading.revealed = Set(hidden)
        }
    }

    /// One row, from its menu.
    func toggleRevealed(_ row: String) {
        guard detail?.isHidden(row) == true else { return }
        guard !reading.revealed.contains(row) else {
            reading.revealed.remove(row)
            return
        }
        guarded(.reveal) { panes in
            guard panes.detail?.isHidden(row) == true else { return }
            panes.reading.revealed.insert(row)
        }
    }

    /// ⌥ down or up. Nothing listens for it unless the setting is on. Over
    /// an item that is still waiting to be answered for it shows nothing
    /// and asks nothing: ⌥ is held for too many other things.
    func peek(_ isHeld: Bool) {
        if isHeld, isHeldBack { return }
        guard reading.isPeeking != isHeld else { return }
        reading.isPeeking = isHeld
    }

    // MARK: A row's menu

    func actions(for row: String) -> [FieldAction] {
        if detail?.file(at: row) != nil { return [.quickLook, .saveAs] }
        guard let detail, detail.value(of: row) != nil, row != ItemDetail.notesRow else { return [] }
        if detail.isHidden(row) {
            let earlier = row == ItemDetail.passwordRow && !detail.item.passwordHistory.isEmpty
            return [reading.revealed.contains(row) ? .conceal : .reveal, .largeType] + (earlier ? [.history] : [])
        }
        if let website = detail.websites.first(where: { $0.row == row }) {
            return website.link == nil ? [.largeType] : [.open, .largeType]
        }
        return [.largeType]
    }

    func toggleMenu(for row: String) {
        let actions = actions(for: row)
        guard reading.menu?.row != row, !actions.isEmpty else {
            reading.menu = nil
            return
        }
        openMenu = nil
        detailMenu = nil
        reading.menu = FieldMenu(row: row, actions: actions)
    }

    func perform(_ action: FieldAction, on row: String) {
        reading.menu = nil
        switch action {
        case .reveal, .conceal:
            toggleRevealed(row)
        case .largeType:
            showLargeType(of: row)
        case .open:
            if let link = detail?.websites.first(where: { $0.row == row })?.link { follow(link) }
        case .history:
            showHistory()
        case .quickLook:
            openAttachment(row)
        case .saveAs:
            saveAttachment(row)
        }
    }

    // MARK: Large Type

    func showLargeType(of row: String) {
        guard detail?.value(of: row) != nil else { return }
        guarded(.largeType) { $0.raiseLargeType(of: row) }
    }

    private func raiseLargeType(of row: String) {
        guard let value = detail?.value(of: row, at: store.now()) else { return }
        let cells = LargeType(value, row: row)
        stage?.show(cells) { [weak self] in self?.reading.largeType = nil }
        reading.largeType = cells
    }

    func closeLargeType() {
        stage?.close()
        if reading.largeType != nil { reading.largeType = nil }
    }

    // MARK: Putting it all away

    /// What another item, the window closing and the lock each do first:
    /// every row concealed, the menus shut, the question withdrawn, Large
    /// Type down.
    func putAway() {
        acknowledging?.cancel()
        if !reading.revealed.isEmpty { reading.revealed = [] }
        if reading.isPeeking { reading.isPeeking = false }
        if reading.hovered != nil { reading.hovered = nil }
        if reading.cursor != nil { reading.cursor = nil }
        if reading.menu != nil { reading.menu = nil }
        if reading.copied != nil { reading.copied = nil }
        if detailMenu != nil { detailMenu = nil }
        if confirming != nil { confirming = nil }
        if reading.history != nil { reading.history = nil }
        putAwayAttachments()
        closeLargeType()
    }

    /// The door's last word to the panes it is about to drop: nothing they
    /// started is left running or standing on the screen (D6).
    func end() {
        putAway()
        // With whatever was typed into it and never saved.
        discardEdit()
        endGenerating()
        choosing = nil
        naming = nil
        deletingVault = nil
        peeking = nil
        optionWatch = nil
        // Every one of them, and not only the last: the first of two would
        // come back to panes that have gone and a vault that has shut.
        writes.values.forEach { $0.cancel() }
        writes = [:]
        windows?.closeAll()
        // A window of one item draws from the icons of the panes it came
        // from, which end them.
        if pinned == nil { icons.end() }
    }
}
