import AppKit
import Combine
import os
import QuartzCore
import SwiftUI

/// One thing an opened item offers: a field to copy, or a window to open
/// the item in.
struct QuickAction: Identifiable, Equatable {
    enum Act: Equatable {
        /// By the row's name among the item's rows (`ItemDetail.value`).
        case copy(String)
        case openWindow, openInApp
        /// The login's address in the browser, and ⌘\ there for two minutes
        /// (`ArmedFill`).
        case openAndFill
        /// Typed into the app that was in front (`Typist`).
        case fill
    }

    let id: String
    let name: String
    var keys: Stroke?
    let act: Act
    /// The first of its group, with a rule over it.
    var startsGroup = false

    static let openWindow = "open-window"
    static let openInApp = "open-in-app"
    static let fill = "fill"
    static let openAndFill = "open-and-fill"
}

/// Quick Access: the panel, whether it is up, what has been typed into it
/// and what it lists for that. Made once, at launch, with its view already
/// in it, and after that only ordered in and out, which is where D18's
/// 100 ms comes from.
///
/// Before a letter it lists the logins for what he is looking at
/// (`Suggestions`), under the site's name or the app's, and then the items
/// used last (`Recents`). After a letter it lists what `SearchIndex` finds.
/// Return copies the selected item's password, or what its type has in a
/// password's place, and puts the panel away. ⇧Return types the login into
/// the app the panel came up over (`Typist`). → opens the item: its actions
/// with their keys, and then every other field it has as a row that copies
/// it. Over a vault that is shut the panel is the lock, and what is typed
/// into its field in the meantime is searched for when the vault opens.
///
/// It goes away on Esc with nothing typed, on a click anywhere else, when
/// the keys leave it, after anything that copies or opens, and when the
/// vault locks. What was typed goes with it.
@MainActor
final class QuickAccess: ObservableObject {
    /// How many results are listed. Past these he types another letter.
    static let most = 50

    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            if isUp, panel.isVisible { timeLetter() }
            opened = nil
            notice = nil
            hasMoved = false
            refresh()
        }
    }
    @Published private(set) var isUp = false
    /// Whether the vault is open. While it is not the panel draws the lock.
    @Published private(set) var isOpen: Bool
    /// The suggested and then the used last, or the found, best first.
    @Published private(set) var rows: [Entry] = []
    /// The names over the list while some of it is suggested, each by the
    /// row it stands over. Empty otherwise: a list of one kind needs none.
    @Published private(set) var headings: [Int: String] = [:]
    @Published private(set) var selected = 0
    /// The first of the rows that are drawn, which the arrows move so that
    /// the selected one is among them.
    @Published private(set) var top = 0
    /// What the keys would do to the selected row, for the row and the strip
    /// of hints to say.
    @Published private(set) var offer = Offer()
    /// The item → opened, and nil while the panel is a list.
    @Published private(set) var opened: Opened?
    /// What is said under the field in the list's place, when a login that
    /// was to be typed was copied, or was not typed at all. A letter typed
    /// puts it away.
    @Published private(set) var notice: FillNotice?

    struct Offer: Equatable {
        /// ⌘C and ⇧⌘C, by the names of their actions.
        var primary: String?
        var password: String?
        var enter: String? { password ?? primary }
    }

    struct Opened {
        let entry: Entry
        let detail: ItemDetail
        let actions: [QuickAction]
        var chosen = 0
    }

    let door: Door
    let recents: Recents
    let panel: QuickPanel
    /// The field, which the view hands over when it is made, so the keys
    /// can be put in it without a turn of the run loop.
    weak var field: NSTextField?
    /// The lock's own field, emptied whenever the panel goes or the vault
    /// opens.
    let typedPassword = TypedSecret()
    /// For the trace: the seconds from `show` to the refresh the panel's
    /// first frame is due on.
    var drawn: ((CFTimeInterval) -> Void)?
    /// What brings the app forward for a window of one item (⌘O), and what
    /// brings its main window forward (⇧⌘O). Nothing in a test.
    var activate: () -> Void = {}
    var showApp: () -> Void = {}
    /// The finger being waited for and the password being tried, for a test
    /// to wait on too.
    private(set) var asking: Task<Void, Never>?
    private(set) var unlocking: Task<Void, Never>?
    /// The app that was in front when the panel last came up, kept after
    /// the panel has gone: it is where a login is typed. A lock forgets
    /// it, since nothing is typed into anything after one.
    private(set) var inFront: FrontApp?
    /// The browser in front being asked for its tab, for a test to wait on.
    private(set) var askingTab: Task<Void, Never>?
    /// The browser a page was opened in by Open & Fill being asked whether
    /// that page is the one in front, for a test to wait on.
    private(set) var askingArmed: Task<Void, Never>?

    private var store: VaultStore { door.store }
    private let present: (QuickPanel) -> Void
    private let front: () -> FrontApp?
    private let tabs: TabAsker?
    /// What types a login into the app in front. Without one nothing is
    /// filled and no row offers to.
    let typist: Typist?
    /// Who is told what the list holds and where the arrows are. Nobody in
    /// a test that gives none, and nobody in a shot.
    private let voice: Voice?
    private var lastCounted: String?
    /// Whether the system has been asked for Accessibility yet, which it is
    /// once. Not a choice, so it is a key of its own and not in `Settings`.
    static let askedKey = "fillAskedForAccessibility"
    /// Where that is written. A test's is nil, and the asking is remembered
    /// here alone.
    private let settings: UserDefaults?
    private var hasAsked = false
    /// ⌘\ over a browser: when its answer brings one login, that one is
    /// typed and the panel goes.
    private var fillsTheOnlyOne = false
    /// What the list is led by the logins of, for as long as the panel is
    /// up: the app that was in front, and the page it said it is on if it
    /// is a browser that said.
    private var lookingAt: FrontApp?
    private var page: Address?
    /// Until he has moved the selection, the first row is the selected one
    /// whatever arrives over it.
    private var hasMoved = false
    private let pointer: () -> CGPoint
    private let screens: () -> [NSRect]
    /// The window of this app's that had the keys, when this app was the
    /// one in front. Another app's window gets them back by itself.
    private weak var cameFrom: NSWindow?
    /// The store's, and never held: it goes at the lock (D6).
    private weak var index: SearchIndex?
    private var clicks: Any?
    private var watchingClicks: Instruments.Registration?
    private let firstFrame: FirstFrame
    private var showing: OSSignpostIntervalState?
    private var watching: Set<AnyCancellable> = []

    /// A test gives a `present` that orders nothing in, and its own pointer
    /// and screens. Unless it is told who is in front and whom to ask for a
    /// tab, nobody is and nobody is asked.
    init(door: Door, recents: Recents = Recents(file: nil),
         front: @escaping () -> FrontApp? = { nil }, tabs: TabAsker? = nil,
         typist: Typist? = nil, settings: UserDefaults? = nil, voice: Voice? = nil,
         present: @escaping (QuickPanel) -> Void = { $0.makeKeyAndOrderFront(nil) },
         pointer: @escaping () -> CGPoint = { NSEvent.mouseLocation },
         screens: @escaping () -> [NSRect] = { NSScreen.screens.map(\.frame) }) {
        self.door = door
        self.recents = recents
        self.front = front
        self.tabs = tabs
        self.typist = typist
        self.settings = settings
        self.voice = voice
        self.present = present
        self.pointer = pointer
        self.screens = screens
        let store = door.store
        isOpen = store.state == .unlocked
        panel = QuickPanel(size: CGSize(width: Metrics.quickWidth, height: QuickLayout.field))
        firstFrame = FirstFrame(in: panel)
        panel.hold(QuickAccessView(quick: self))
        panel.escape = { [weak self] in self?.escape() }
        panel.keys = { [weak self] in self?.press($0) ?? false }
        // The sheet that asks for a finger may take the keys, and the panel
        // is still what he is looking at.
        panel.lostKeys = { [weak self] in
            guard let self, self.asking == nil else { return }
            self.close()
        }
        NotificationCenter.default.publisher(for: VaultStore.didLock, object: store).sink { [weak self] _ in
            self?.close()
            self?.inFront = nil
            self?.askingArmed?.cancel()
            self?.askingArmed = nil
            // What has not been typed by now is not typed.
            self?.typist?.stop()
        }.store(in: &watching)
        // The ids used last are the account's, and go with it.
        NotificationCenter.default.publisher(for: VaultStore.didSignOut, object: store).sink { [weak self] _ in
            self?.recents.forget()
            self?.refresh(keepingPlace: false)
        }.store(in: &watching)
        // Each of the three says so before it has changed. The items a
        // revision brings are already in the store by then, and the state
        // and the index come with what they are about to be.
        store.$state.map { $0 == .unlocked }.removeDuplicates().sink { [weak self] isOpen in
            self?.vault(isOpen: isOpen)
        }.store(in: &watching)
        store.$searchIndex.sink { [weak self] index in
            self?.index = index
            self?.refresh(keepingPlace: true)
        }.store(in: &watching)
        store.$revision.dropFirst().sink { [weak self] _ in
            self?.refresh(keepingPlace: true)
        }.store(in: &watching)
    }

    /// What the hot key does.
    func toggle() {
        if isUp { close() } else { show() }
    }

    func show() {
        guard !isUp else { return }
        // Before the panel is ordered in: afterwards the app in front may
        // be this one.
        inFront = front()
        raise(over: inFront)
    }

    /// The panel ordered in, led by the logins for `app`. With a notice to
    /// say it comes up over nothing, and the app a login is typed into is
    /// still the one it was.
    private func raise(over app: FrontApp?) {
        let interval = Log.signposter.beginInterval("quick-access")
        let began = CACurrentMediaTime()
        isUp = true
        cameFrom = NSApp.isActive ? NSApp.keyWindow : nil
        lookingAt = app
        hasMoved = false
        // A browser is asked nothing over a vault that is shut: the first
        // question raises macOS's own about Automation, and there would be
        // nothing to suggest for the answer.
        if isOpen { askForTab() }
        refresh()
        panel.setFrame(QuickPlace.frame(of: CGSize(width: Metrics.quickWidth, height: height),
                                        pointer: pointer(), screens: screens()), display: false)
        present(panel)
        if let field { panel.makeFirstResponder(field) }
        if !isOpen { knock() }
        // A test's panel is on no screen: it is never refreshed, and no
        // click anywhere is its business.
        guard panel.isVisible else {
            Log.signposter.endInterval("quick-access", interval, "unseen")
            return
        }
        watchClicks()
        showing = interval
        firstFrame.wait { [weak self] due in
            self?.seen("shown")
            self?.drawn?(due - began)
        }
    }

    func close() {
        guard isUp else { return }
        // Before it is ordered out: losing the keys comes back here.
        isUp = false
        seen("closed")
        if let clicks { NSEvent.removeMonitor(clicks) }
        clicks = nil
        watchingClicks = nil
        opened = nil
        notice = nil
        fillsTheOnlyOne = false
        askingTab?.cancel()
        askingTab = nil
        lookingAt = nil
        page = nil
        lastCounted = nil
        // What was used a moment ago leads the list the panel next comes
        // up with.
        if query.isEmpty { refresh() } else { query = "" }
        // Its own editor holds the text too, and is asked for nothing again
        // until the panel is next up.
        field?.stringValue = ""
        typedPassword.take()?.wipe()
        let hadKeys = panel.isKeyWindow
        panel.orderOut(nil)
        // Only when the keys were this panel's to give. If another window
        // took them, that is where they belong.
        if hadKeys, NSApp.isActive, let cameFrom, cameFrom.isVisible { cameFrom.makeKey() }
        cameFrom = nil
    }

    /// The end of it, for whoever made one that is not the app's: a test, a
    /// shot, the trace. The panel holds the view and the view holds this, so
    /// neither would ever go by itself, and each test would leave a window
    /// behind it. The app's own lives as long as the app and is never ended.
    func end() {
        close()
        watching = []
        panel.contentView = nil
        panel.close()
    }

    /// Esc empties the field, and with the field already empty puts the
    /// panel away.
    func escape() {
        if query.isEmpty { close() } else { query = "" }
    }

    // MARK: What it lists

    /// Whether anything has been typed that can be looked for.
    var isSearching: Bool { !query.allSatisfy(\.isWhitespace) }

    /// Something was looked for, by an index that is there, and no item
    /// has it.
    var foundNothing: Bool { isOpen && isSearching && rows.isEmpty && index != nil }

    /// How many are listed, in words: the name the list has for VoiceOver,
    /// and what is said as a letter changes it. Nil while nothing is
    /// listed and nothing was looked for.
    var counted: String? {
        guard isOpen, opened == nil, notice == nil else { return nil }
        if foundNothing { return Self.nothing }
        switch rows.count {
        case 0: return nil
        case 1: return "1 result"
        default: return "\(rows.count) results"
        }
    }

    static let nothing = "No items match"
    /// What pressing a row does, by the name VoiceOver has for it when the
    /// row is not the selected one, whose own is `Offer.enter`.
    static let choosing = "Copy"

    /// The selected row as it is read out: what it is, and where in the
    /// list.
    var selectedSaid: String? {
        if let opened {
            guard opened.actions.indices.contains(opened.chosen) else { return nil }
            return "\(opened.actions[opened.chosen].name), \(opened.chosen + 1) of \(opened.actions.count)"
        }
        guard isOpen, rows.indices.contains(selected) else { return nil }
        let item = rows[selected].item
        let words = [item.name, QuickAccess.second(of: item)].compactMap { $0 }
        return (words + ["\(selected + 1) of \(rows.count)"]).joined(separator: ", ")
    }

    /// "deniz – github.com". The address is cut to its host, which is the
    /// part that tells two logins apart.
    static func second(of item: Item) -> String? {
        let parts = [item.secondLine, item.iconHost].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " – ")
    }

    /// The count, said once for each list that has another one.
    private func sayCount() {
        guard let voice, isUp else { return }
        let counted = self.counted
        guard counted != lastCounted else { return }
        lastCounted = counted
        if let counted { voice.say(counted, in: panel) }
    }

    var height: CGFloat {
        if isOpen, notice != nil { return QuickLayout.field + Metrics.quickNotice }
        return QuickLayout.height(isOpen: isOpen, rows: rows.count, headings: headingsDrawn, actions: opened?.actions,
                                  foundNothing: foundNothing)
    }

    /// How many of the headings are over one of the rows that are drawn.
    var headingsDrawn: Int {
        headings.keys.filter { $0 >= top && $0 < top + QuickLayout.rows }.count
    }

    /// A browser is asked which page it is on while the panel is already
    /// up, so the key never waits for it (D18). Until it has answered
    /// nothing is suggested for it, and when it will not say nothing is.
    private func askForTab() {
        guard let tabs, let lookingAt, lookingAt.browser != nil else { return }
        askingTab = Task { [weak self] in
            let written = await tabs.address(of: lookingAt)
            guard let self, !Task.isCancelled, self.isUp else { return }
            self.askingTab = nil
            self.page = written.flatMap { Address.page($0) }
            self.refresh(keepingPlace: true)
            guard self.fillsTheOnlyOne else { return }
            self.fillsTheOnlyOne = false
            // Not when he has typed or moved in the meantime: the panel
            // is his by then.
            guard !self.hasMoved, self.query.isEmpty, self.opened == nil,
                  let suggested = self.suggestions()?.entries, suggested.count == 1 else { return }
            self.fill(suggested[0])
        }
    }

    /// The logins for the page or the app in front, from the items a search
    /// looks among: none archived and none deleted. The index has read
    /// their addresses already.
    private func suggestions() -> Suggestions? {
        guard askingTab == nil, let listed = index?.logins else { return nil }
        if let page { return Suggestions.forPage(page, among: listed, usedLast: recents.ids) }
        return lookingAt.flatMap { Suggestions.forApp($0, among: listed, usedLast: recents.ids) }
    }

    /// For a shot, whose panel never comes up: what was in front, said and
    /// not asked.
    func look(at app: FrontApp, on written: String? = nil) {
        inFront = app
        lookingAt = app
        page = written.flatMap { Address.page($0) }
        refresh()
    }

    /// `keepingPlace` is for a change that was not his: a sync, an index
    /// arriving, a browser's answer. The row he moved to is still the
    /// selected one if it is still listed, and if he has not moved it is
    /// the first, so a suggestion that arrives late is under Return. A
    /// letter typed starts from the top.
    private func refresh(keepingPlace: Bool = false) {
        let was = keepingPlace && hasMoved && rows.indices.contains(selected) ? rows[selected].id : nil
        var found: [Entry] = []
        var headings: [Int: String] = [:]
        if !isOpen {
            found = []
        } else if isSearching {
            found = Array((index?.search(query, usedLast: recents.ids) ?? []).prefix(Self.most))
        } else {
            let suggested = suggestions()
            let leading = Array((suggested?.entries ?? []).prefix(Self.most))
            let used = recents.ids.filter { id in !leading.contains { $0.id == id } }
                .compactMap { store.entry(id: $0) }
                .filter { !$0.item.isArchived && !$0.item.isInTrash }
            found = leading + used
            if let suggested {
                headings[0] = suggested.heading
                if !used.isEmpty { headings[leading.count] = "Recently Used" }
            }
        }
        if !found.elementsEqual(rows, by: ===) { rows = found }
        if headings != self.headings { self.headings = headings }
        select(was.flatMap { id in found.firstIndex { $0.id == id } } ?? 0)
        // An opened item that a sync changed is opened again as it now is,
        // and one that has gone is shut.
        if let opened, store.entry(id: opened.entry.id) !== opened.entry {
            let chosen = opened.chosen
            self.opened = store.entry(id: opened.entry.id).map(open)
            self.opened?.chosen = min(chosen, (self.opened?.actions.count ?? 1) - 1)
        }
        resize()
        sayCount()
    }

    private func select(_ place: Int) {
        let place = max(0, min(place, rows.count - 1))
        if place != selected { selected = place }
        let top = min(place, max(self.top, place - QuickLayout.rows + 1))
        if top != self.top { self.top = top }
        let offer = rows.indices.contains(place) ? self.offer(for: rows[place].item) : Offer()
        if offer != self.offer { self.offer = offer }
    }

    private func vault(isOpen: Bool) {
        guard isOpen != self.isOpen else { return }
        self.isOpen = isOpen
        // Opened through the panel, a browser behind it is asked now.
        if isOpen, isUp { askForTab() }
        refresh()
        guard isOpen else { return }
        typedPassword.take()?.wipe()
        guard isUp, let field else { return }
        // The keys back to the search, with the caret after what was typed
        // while the vault was shut and not around it.
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
    }

    private func resize() {
        let height = self.height
        guard panel.frame.height != height else { return }
        // The top edge stays where it is, and so the field does.
        var frame = panel.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        // Not drawn here and now: the views have not caught up with what
        // they are to draw, and would be drawn twice.
        panel.setFrame(frame, display: false)
    }

    private func detail(of item: Item) -> ItemDetail {
        ItemDetail(item: item, vault: store.vault(of: item))
    }

    /// A login says what it has by itself. Any other type is asked through
    /// its details, which read its notes, so it is not done for every row.
    private func offer(for item: Item) -> Offer {
        if let login = item.login {
            return Offer(primary: login.username?.isEmpty == false ? "Copy \(login.usernameWord.capitalized)" : nil,
                         password: login.password?.isEmpty == false ? "Copy Password" : nil)
        }
        let detail = detail(of: item)
        return Offer(primary: detail.primaryRow.map { Self.name(of: $0, in: detail) },
                     password: detail.passwordRowID.map { Self.name(of: $0, in: detail) })
    }

    // MARK: An opened item

    private func open(_ entry: Entry) -> Opened {
        let detail = detail(of: entry.item)
        return Opened(entry: entry, detail: detail,
                      actions: Self.actions(for: detail, fillsInto: canFill(entry.item) ? inFront?.name : nil,
                                            opensSite: canOpenAndFill(entry.item)))
    }

    /// A login with a password, something to type it with, and an app the
    /// panel came up over that is not this one.
    private func canFill(_ item: Item) -> Bool {
        typist != nil && inFront != nil && item.login?.password?.isEmpty == false
    }

    /// A login with an address a browser opens and a password, and
    /// something that arms the key for it.
    private func canOpenAndFill(_ item: Item) -> Bool {
        door.armedFill != nil && ArmedFill.canOpen(item)
    }

    /// The three copies that have keys, the two windows, and then every
    /// other row of the item that holds something, in the order the details
    /// draw them. Between the two windows are Open & Fill, when the login
    /// has a page to open, and then, when there is an app to type into, the
    /// fill, named for that app: the still has them in that order.
    static func actions(for detail: ItemDetail, fillsInto app: String? = nil,
                        opensSite: Bool = false) -> [QuickAction] {
        var actions: [QuickAction] = []
        if let row = detail.primaryRow {
            actions.append(QuickAction(id: row, name: name(of: row, in: detail), keys: Stroke("c", .command),
                                       act: .copy(row)))
        }
        if let row = detail.passwordRowID {
            actions.append(QuickAction(id: row, name: name(of: row, in: detail),
                                       keys: Stroke("c", [.command, .shift]), act: .copy(row)))
        }
        if let row = detail.codeRowID {
            actions.append(QuickAction(id: row, name: name(of: row, in: detail),
                                       keys: Stroke("c", [.command, .option]), act: .copy(row)))
        }
        let keyed = Set(actions.map(\.id))
        actions.append(QuickAction(id: QuickAction.openWindow, name: "Open in New Window",
                                   keys: Stroke("o", .command), act: .openWindow, startsGroup: !actions.isEmpty))
        if opensSite {
            actions.append(QuickAction(id: QuickAction.openAndFill, name: "Open & Fill",
                                       keys: Stroke(Stroke.enter, .option), act: .openAndFill))
        }
        if let app {
            actions.append(QuickAction(id: QuickAction.fill, name: app.isEmpty ? "Fill" : "Fill in \(app)",
                                       keys: Stroke(Stroke.enter, .shift), act: .fill))
        }
        actions.append(QuickAction(id: QuickAction.openInApp, name: "Open in \(AppInfo.name)",
                                   keys: Stroke("o", [.command, .shift]), act: .openInApp))
        for (place, row) in detail.stops.filter({ !keyed.contains($0) }).enumerated() {
            actions.append(QuickAction(id: row, name: name(of: row, in: detail), act: .copy(row),
                                       startsGroup: place == 0))
        }
        return actions
    }

    /// "Copy Username", or "Copy Email" for a username that is one. A
    /// custom field keeps the name he gave it, and one of several addresses
    /// says which.
    static func name(of row: String, in detail: ItemDetail) -> String {
        if row == ItemDetail.notesRow { return "Copy Notes" }
        if let website = detail.websites.first(where: { $0.row == row }) {
            let which = website.host.isEmpty ? website.written : website.host
            return detail.websites.count > 1 ? "Copy Website (\(which))" : "Copy Website"
        }
        if let field = detail.fields.first(where: { $0.id == row }) { return "Copy \(field.label)" }
        return "Copy \(detail.main.first { $0.id == row }?.label.capitalized ?? "Field")"
    }

    /// →, and a click on the square beside the selected row.
    @discardableResult
    func openSelected() -> Bool {
        guard isOpen, opened == nil, rows.indices.contains(selected) else { return false }
        opened = open(rows[selected])
        resize()
        return true
    }

    /// ←, and the cross.
    @discardableResult
    func back() -> Bool {
        guard opened != nil else { return false }
        opened = nil
        resize()
        return true
    }

    // MARK: The keys

    /// ⌘A, ⌘V, ⌘X and ⌘Z are the field's. Every other ⌘ key is taken here
    /// and goes no further: the menu bar's are the main window's, and ⌘O or
    /// ⌘R from the panel would be done to whatever item that has open.
    private static let fieldsOwn: Set<Stroke> = [
        Stroke("a", .command), Stroke("v", .command), Stroke("x", .command), Stroke("z", .command),
        Stroke("z", [.command, .shift]),
    ]

    /// A key going down in the panel, before its field has it. True when it
    /// was the panel's and the field is not to see it.
    func press(_ event: NSEvent) -> Bool {
        guard let stroke = Stroke(event) else { return false }
        let isMenus = stroke.modifiers.contains(.command) && !Self.fieldsOwn.contains(stroke)
        guard isOpen else { return isMenus }
        if let notice {
            // Return is the notice's one button, and nothing is listed
            // for an arrow to move in. A notice with no button is put
            // away by it.
            guard stroke == Stroke(Stroke.enter) else { return isMenus }
            if notice.button == nil { close() } else { allowTyping() }
            return true
        }
        switch stroke {
        case Stroke(Stroke.up): move(by: -1)
        case Stroke(Stroke.down): move(by: 1)
        case Stroke(Stroke.enter): pressReturn()
        case Stroke(Stroke.enter, .shift): fill()
        case Stroke(Stroke.enter, .option): openAndFill()
        case Stroke(Stroke.right):
            // With the caret inside what was typed, → is the caret's.
            return opened != nil || (caretIsAtEnd && openSelected())
        case Stroke(Stroke.left): return back()
        case Stroke("c", .command):
            // Letters selected in the field are what ⌘C means there.
            if fieldHasSelection { return false }
            copyPrimary()
        case Stroke("c", [.command, .shift]): copyPassword()
        case Stroke("c", [.command, .option]): copyCode()
        case Stroke("o", .command): openWindow()
        case Stroke("o", [.command, .shift]): openInApp()
        default: return isMenus
        }
        return true
    }

    private var editor: NSTextView? { panel.firstResponder as? NSTextView }

    private var caretIsAtEnd: Bool {
        guard let editor else { return true }
        let range = editor.selectedRange()
        return range.length == 0 && range.location == (editor.string as NSString).length
    }

    private var fieldHasSelection: Bool { (editor?.selectedRange().length ?? 0) > 0 }

    func move(by step: Int) {
        if var opened {
            opened.chosen = max(0, min(opened.chosen + step, opened.actions.count - 1))
            self.opened = opened
        } else {
            hasMoved = true
            select(selected + step)
            // The eight may have moved past a heading, or back under one.
            resize()
        }
        if let voice, let selectedSaid { voice.say(selectedSaid, in: panel) }
    }

    /// The item the keys are about: the opened one, or the selected row.
    private var current: (entry: Entry, detail: ItemDetail)? {
        if let opened { return (opened.entry, opened.detail) }
        guard isOpen, rows.indices.contains(selected) else { return nil }
        return (rows[selected], detail(of: rows[selected].item))
    }

    /// Return: the chosen action of an opened item, and for a row its
    /// password, or its first field when it has none (D16).
    func pressReturn() {
        if let opened {
            if opened.actions.indices.contains(opened.chosen) { perform(opened.actions[opened.chosen]) }
        } else if let current {
            copy(current.detail.passwordRowID ?? current.detail.primaryRow, of: current)
        }
    }

    /// ⌘C.
    @discardableResult
    func copyPrimary() -> Bool {
        current.map { copy($0.detail.primaryRow, of: $0) } ?? false
    }

    /// ⇧⌘C.
    @discardableResult
    func copyPassword() -> Bool {
        current.map { copy($0.detail.passwordRowID, of: $0) } ?? false
    }

    /// ⌥⌘C: the one-time code that stands when it is copied.
    @discardableResult
    func copyCode() -> Bool {
        current.map { copy($0.detail.codeRowID, of: $0) } ?? false
    }

    func perform(_ action: QuickAction) {
        guard let opened else { return }
        switch action.act {
        case .copy(let row): copy(row, of: (opened.entry, opened.detail))
        case .openWindow: openWindow()
        case .openInApp: openInApp()
        case .fill: fill(opened.entry)
        case .openAndFill: openAndFill()
        }
    }

    /// A click on a row: what Return would do there.
    func click(row place: Int) {
        guard rows.indices.contains(place) else { return }
        select(place)
        pressReturn()
    }

    /// The one way a value leaves the panel: to the door's pasteboard, which
    /// takes it off again (`Clipboard`), with the item put first among the
    /// used and the panel put away. False, and the panel still up, when the
    /// item has no such row.
    ///
    /// An item that asks is answered for first (`Reprompt`). The panel
    /// goes before the question comes, since a card for the password
    /// would take the keys from it, and the value is read from the vault
    /// again when the answer is yes.
    @discardableResult
    private func copy(_ row: String?, of item: (entry: Entry, detail: ItemDetail)) -> Bool {
        guard let row, let value = item.detail.value(of: row, at: store.now()) else { return false }
        let id = item.entry.id
        guard let reprompt = door.reprompt, reprompt.asks(about: item.entry.item) else {
            door.clipboard.copy(value)
            recents.use(id)
            close()
            return true
        }
        close()
        reprompt.allow(.copy, on: item.entry.item) { [weak self] in
            guard let self, let item = self.store.entry(id: id)?.item,
                  let value = self.detail(of: item).value(of: row, at: self.store.now()) else { return }
            self.door.clipboard.copy(value)
            self.recents.use(id)
        }
        return true
    }

    // MARK: Filling

    /// ⇧Return: the selected login, or the opened one, typed into the app
    /// the panel came up over. False, and the panel as it was, when there
    /// is no such app, or the item is no login with a password.
    @discardableResult
    func fill() -> Bool {
        current.map { fill($0.entry) } ?? false
    }

    /// ⌥Return: the selected login's first address in the default browser,
    /// and the login armed for ⌘\ there (`ArmedFill`). The panel goes first,
    /// so the browser coming forward does not meet it. False, and the panel
    /// as it was, for an item with no such address.
    @discardableResult
    func openAndFill() -> Bool {
        guard let armed = door.armedFill, let item = current?.entry.item, ArmedFill.canOpen(item) else {
            return false
        }
        recents.use(item.id)
        close()
        return armed.open(item, at: store.now())
    }

    /// ⌘\ from anywhere. With one login for the app in front, that one is
    /// typed and no panel is seen. Otherwise the panel comes up on what it
    /// has for that app, as its own key would bring it. A browser is asked
    /// its page with the panel already up, since the key waits for nothing
    /// (D18), and when the answer leaves one login the panel goes and that
    /// one is typed.
    func autofill() {
        guard !isUp else { return close() }
        guard isOpen, typist != nil, let app = front() else { return show() }
        // A page opened by Open & Fill is waiting for this key: its login,
        // with no panel and no asking which, once the browser has said it
        // is on that page. An item that asks is still asked.
        if let armed = door.armedFill, let id = armed.item(for: app, at: store.now()),
           let entry = store.entry(id: id), !entry.item.isInTrash, !entry.item.isArchived {
            guard let tabs, app.browser != nil else { return lead(with: entry, armed) }
            askingArmed?.cancel()
            askingArmed = Task { [weak self] in
                let written = await tabs.address(of: app)
                guard let self, !Task.isCancelled else { return }
                self.askingArmed = nil
                // He brought the panel up meanwhile, the vault locked, the
                // arming was used or lapsed, or another app is in front.
                guard !self.isUp, self.isOpen, self.front() == app,
                      armed.item(for: app, at: self.store.now()) == id,
                      let entry = self.store.entry(id: id), !entry.item.isInTrash, !entry.item.isArchived
                else { return }
                guard let page = written.flatMap({ Address.page($0) }) else { return self.lead(with: entry, armed) }
                guard entry.item.login?.uris.contains(where: { $0.belongs(to: page) }) == true else {
                    // Another site's page. The key is the ordinary one's
                    // there, and the page that was opened is still waiting.
                    return self.fillOrdinarily(over: app)
                }
                _ = armed.take(for: app, at: self.store.now())
                self.inFront = app
                if !self.fill(entry) { self.fillOrdinarily(over: app) }
            }
            return
        }
        fillOrdinarily(over: app)
    }

    /// The fill's key with nothing armed for what is in front.
    private func fillOrdinarily(over app: FrontApp) {
        if tabs != nil, app.browser != nil {
            show()
            fillsTheOnlyOne = askingTab != nil
            return
        }
        guard let listed = index?.logins,
              let suggested = Suggestions.forApp(app, among: listed, usedLast: recents.ids)?.entries,
              suggested.count == 1 else { return show() }
        inFront = app
        fill(suggested[0])
    }

    /// The armed login over a page nobody can name: a browser that would
    /// not say, or one that cannot be asked. Nothing is typed on the
    /// strength of the clock. The login is put first among the used, which
    /// is what leads the panel over such a browser, and ⇧Return types it.
    private func lead(with entry: Entry, _ armed: ArmedFill) {
        armed.clear()
        recents.use(entry.id)
        show()
    }

    /// An item that asks is answered for first, with the panel put away
    /// as it is for a copy, and the login is read from the vault again
    /// when the answer is yes. Until macOS allows the typing, the password
    /// is copied and the panel says so. A login the typist would not type
    /// (`Typist.Outcome.needsPasswordField`) brings the panel back to say
    /// that, and copies nothing: ⌘\ and a page opened by Open & Fill type
    /// with no panel up, and nothing else on the screen would tell a fill
    /// that was refused from one that is still to come.
    @discardableResult
    private func fill(_ entry: Entry) -> Bool {
        guard let typist, let app = inFront, canFill(entry.item) else { return false }
        let id = entry.id
        let go: @MainActor () -> Void = { [weak self] in
            guard let self, self.inFront == app, let login = self.store.entry(id: id)?.item.login,
                  let password = login.password, !password.isEmpty else { return }
            self.recents.use(id)
            guard typist.access.isTrusted else {
                self.door.clipboard.copy(password)
                self.say(.copiedInstead(of: app.name))
                return
            }
            self.close()
            typist.type(Filling(username: login.username, password: password), into: app,
                        pressingReturn: self.door.preferences.settings.fill.pressesReturn) { [weak self] outcome in
                guard outcome == .needsPasswordField, let self, self.isOpen, self.inFront == app else { return }
                self.say(.needsPasswordField(in: app.name))
            }
        }
        guard let reprompt = door.reprompt, reprompt.asks(about: entry.item) else {
            go()
            return true
        }
        close()
        reprompt.allow(.fill, on: entry.item, then: go)
        return true
    }

    /// For a shot, whose panel never comes up.
    func tell(_ notice: FillNotice) {
        opened = nil
        self.notice = notice
    }

    private func say(_ notice: FillNotice) {
        tell(notice)
        if isUp { resize() } else { raise(over: nil) }
        // The panel may have come up unasked, with the keys in its field.
        voice?.say("\(notice.title). \(notice.sentence)", in: panel)
    }

    /// The notice's button, and Return while it is up. The first time it
    /// is macOS's own question, which is put once. After that it is the
    /// list in System Settings where the switch is.
    func allowTyping() {
        guard let typist, notice?.button != nil else { return }
        close()
        guard hasAsked || settings?.bool(forKey: Self.askedKey) == true else {
            hasAsked = true
            settings?.set(true, forKey: Self.askedKey)
            return typist.access.ask()
        }
        typist.access.openSettings()
    }

    /// ⌘O: the item in a window of its own, which is the open panes' to
    /// make and to close at the lock.
    @discardableResult
    func openWindow() -> Bool {
        guard let id = current?.entry.id, let panes = door.panes, let windows = panes.windows else { return false }
        recents.use(id)
        close()
        activate()
        return windows.open(id, from: panes) != nil
    }

    /// ⇧⌘O: the main window, on the item.
    @discardableResult
    func openInApp() -> Bool {
        guard let id = current?.entry.id, let panes = door.panes else { return false }
        recents.use(id)
        close()
        let isShown = panes.show(item: id)
        showApp()
        return isShown
    }

    // MARK: The lock

    /// The panel has come up over a vault that is shut. A finger is asked
    /// for at once when one can open it, and the keys stay in the search
    /// field meanwhile. Otherwise they go to the password.
    private func knock() {
        if store.state == .locked, door.hasSeal { askForFinger() } else { typedPassword.takeKeys() }
    }

    /// Also the fingerprint in the lock's field. The door does the asking,
    /// so the main window's lock screen and this one never ask at once.
    func askForFinger() {
        guard asking == nil else { return }
        let asked = door.askForFinger()
        asking = Task { [weak self] in
            await asked.value
            guard let self else { return }
            self.asking = nil
            guard self.isUp else { return }
            // If the sheet took the keys, they come back.
            if self.panel.isVisible, !self.panel.isKeyWindow { self.present(self.panel) }
            if !self.isOpen { self.typedPassword.takeKeys() }
        }
    }

    /// The button of a lock that has nothing to type into: the main window
    /// is where an account is signed in.
    func openApp() {
        close()
        showApp()
    }

    /// Return in the lock's field.
    func unlock(with password: SecretBytes) {
        unlocking = door.unlock(with: password)
    }

    /// An interval named `quick-type`, from a letter reaching the model to
    /// the main thread having nothing left to do about it: the search, the
    /// list laid out again and the commit to the window server. It is what a
    /// letter typed by a hand costs (`docs/notes.md`, "Timing"), and says
    /// how many items it listed and nothing of them.
    private func timeLetter() {
        let interval = Log.signposter.beginInterval("quick-type")
        let idle = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false,
                                                      CFIndex.max) { [weak self] _, _ in
            let listed = MainActor.assumeIsolated { self?.rows.count ?? 0 }
            Log.signposter.endInterval("quick-type", interval, "\(listed) listed")
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), idle, .commonModes)
    }

    private func seen(_ outcome: StaticString) {
        firstFrame.stop()
        guard let showing else { return }
        self.showing = nil
        Log.signposter.endInterval("quick-access", showing, "\(outcome, privacy: .public)")
    }

    /// A click on the menu bar, the Dock or the desktop takes the keys from
    /// nobody, so losing them is not the whole of "a click outside". Only
    /// other apps' events come to a global monitor, and watching the button
    /// asks for no permission.
    private func watchClicks() {
        clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] _ in
            Task { @MainActor in
                // A click on the sheet that asks for a finger is not a
                // click away from the panel.
                guard let self, self.asking == nil else { return }
                self.close()
            }
        }
        watchingClicks = Instruments.register("clicks-outside", kind: .observer, owner: "QuickAccess")
    }
}

/// One turn of the display, and then nothing: the first refresh after the
/// panel was ordered in is the one its first frame is in. The link is made
/// when the panel goes up and ended at that refresh, or when the panel goes
/// away before it, so between showings there is none, and a lock, which
/// puts the panel away, leaves none behind it (D18). While there is one it
/// is in `Instruments` as the timer it is.
@MainActor
private final class FirstFrame: NSObject {
    private weak var panel: NSWindow?
    private var link: CADisplayLink?
    private var ticking: Instruments.Registration?
    private var seen: ((CFTimeInterval) -> Void)?

    init(in panel: NSWindow) {
        self.panel = panel
    }

    func wait(_ seen: @escaping (CFTimeInterval) -> Void) {
        stop()
        guard let panel else { return }
        self.seen = seen
        let link = panel.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        ticking = Instruments.register("first-frame", kind: .timer, owner: "QuickAccess")
    }

    /// The link holds its target, so it is ended here and not in a `deinit`
    /// that would never come.
    func stop() {
        seen = nil
        link?.invalidate()
        link = nil
        ticking = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let seen = self.seen
        stop()
        seen?(link.targetTimestamp)
    }
}
