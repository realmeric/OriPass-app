import AppKit
import Combine
import SwiftUI

/// A row of the sidebar that can be selected, and so what the item list
/// shows.
enum SidebarRow: Hashable {
    case allItems, favorites, passwordHealth
    case vault(Vault.Place)
    case archive, trash
}

/// The three columns, as the arrows know them.
enum Pane {
    case sidebar, list, details
}

/// Somewhere the window has been: a row of the sidebar, the item chosen
/// under it, and under Password Health the card whose items were listed. An id
/// and never a value, and gone with the panes at the lock.
struct Visit: Equatable {
    var row: SidebarRow
    var item: String?
    var card: WatchCard?
}

/// The two menus the item list's header drops.
enum ListMenu: Equatable {
    case categories, sort
}

/// What the unlocked window knows about itself. The door makes it when the
/// vault opens and drops it when it locks, so nothing a pane was holding
/// outlives the lock (D6). Four things of it are written down: whether VAULTS
/// is folded shut, in the defaults it was handed, and the category, the
/// order and the direction the item list was left in, which are choices and
/// are in the settings (`ListChoices`). A window that
/// opens again opens on All Items with its sidebar out, no item selected and
/// nowhere to go back to.
@MainActor
final class Panes: ObservableObject {
    static let vaultsFoldedKey = "vaultsFolded"
    /// Letters typed further apart than this start a new word.
    static let typingPause: TimeInterval = 1

    let store: VaultStore
    /// Where a row's site icon comes from. Made with the panes, so the icons
    /// held in memory go when they do.
    let icons: IconStore
    /// What the details are doing with the selected item (`Reading`).
    let reading = Reading()
    let clipboard: Clipboard
    /// Where Large Type goes up, and nowhere in a shot and in most tests.
    let stage: LargeTypeStage?
    /// Where an attachment is opened, and nowhere in a shot and in most
    /// tests (`AttachmentDesk`).
    let desk: AttachmentDesk?
    /// What asks again for an item that asks (`Reprompt`), and nothing in
    /// a shot and in most tests.
    let reprompt: Reprompt?
    /// What ⇧⌘F arms (`ArmedFill`), and nothing in a shot and in most tests.
    let armedFill: ArmedFill?
    /// What the account's menu raises for Settings: the door's, and nothing
    /// in a shot and in most tests, where the row is grey.
    var showSettings: (() -> Void)?
    /// The attachment being fetched for Quick Look, which another item and
    /// the lock both stop.
    var fetch: Task<Void, Never>?
    /// The one item these panes are for, when they are a window of its own
    /// (`ItemWindows`) and have no list to choose from.
    let pinned: String?
    /// The windows opened on one item each. A window of that kind opens
    /// none.
    let windows: ItemWindows?
    /// How long a row says "Copied".
    var acknowledgement = Motion.acknowledged
    var acknowledging: Task<Void, Never>?
    var optionWatch: OptionWatch?
    /// ⇧⌘D. What he asked for, which a window too narrow for three columns
    /// overrules (`PaneLayout`).
    @Published var wantsSidebar = true
    @Published private(set) var vaultsFolded: Bool
    /// The row he chose last, which a sync may since have taken away.
    @Published private var chosen = SidebarRow.allItems
    /// The card of Password Health whose items the list holds, after its "Show
    /// Items". Without one the row is the dashboard and has no list.
    @Published private(set) var watched: WatchCard?

    @Published private(set) var category: ItemList.Category
    @Published private(set) var sort: ItemList.Sort
    /// What is typed into the list's own field, ⌥⌘F. Never written down.
    @Published var filter = "" {
        didSet { settle() }
    }
    @Published private(set) var isFiltering = false
    /// What is typed into the toolbar's field, ⌘F. Never written down.
    @Published var query = "" {
        didSet { settle() }
    }
    /// Whether that field has the keys, which is when it wears its ring.
    @Published var searchHasKeys = false
    /// Moves when the toolbar's field should have the caret.
    @Published private(set) var keysToSearch = 0
    @Published var openMenu: ListMenu?
    /// Which of the two menus over the details stands open (`ItemMenu`).
    @Published var detailMenu: DetailMenu?
    /// The item he is being asked about before it is deleted for good.
    @Published var confirming: String?
    /// What the engine said when it last would not make a change.
    @Published var refused: String?
    /// The form the details have become, while an item is being changed
    /// (`Editor`). It has an item of its own, so a search that hides the
    /// item from the list does not take the form away.
    @Published var editor: Editor? {
        didSet {
            // The generator a form's button raised has no field without it.
            if editor == nil, generator?.purpose == .field { endGenerating() }
        }
    }
    /// The generator, while it is up over a form's password or by itself
    /// (`Generator`).
    @Published var generator: Generator?
    /// The question between Cancel and a form with something changed in it
    /// being gone.
    @Published var isAskingToDiscard = false
    /// The sheet of the five kinds, while ⌘N has it up.
    @Published var choosing: NewItemChoice?
    /// The card asking for a vault's name, while the plus beside VAULTS or
    /// a vault's Rename has it up (`VaultNaming`).
    @Published var naming: VaultNaming?
    /// The vault he is being asked about before it is deleted.
    @Published var deletingVault: Vault?
    /// The row of the sidebar a dragged item is over, when it would take it.
    @Published var dropTarget: SidebarRow?
    /// The item being dragged out of the list.
    var dragged: String?
    /// The last change sent to the engine, kept so a test can wait for it.
    var writing: Task<Void, Never>?
    /// Every change the engine has not answered yet, so the lock can stop
    /// each of them from touching anything when it comes back (`end`).
    var writes: [Int: Task<Void, Never>] = [:]
    var writesBegun = 0
    /// The item the details last had in them (`settle`).
    private var shown: String?
    private var watching: Set<AnyCancellable> = []
    /// The item he chose last, which may not be in the list as it stands.
    @Published private var chosenItem: String?
    /// Whether "Last edited" stands open onto the date the item was made.
    /// The chosen item's, so it shuts when another is chosen.
    @Published private(set) var showsCreated = false
    /// Moves when the list should have the keys: a row was clicked, the
    /// filter was put away.
    @Published private(set) var keysToList = 0
    /// Where the window has been, behind ⌘[ and ⌘] and the toolbar's
    /// chevrons. It moves only with the row or the item, which publish for
    /// it, so a choice is still one change to the window.
    private(set) var history = History(at: Visit(row: .allItems, item: nil))
    /// The column the arrows, Return and Space are meant for (`PaneKeys`).
    @Published var focus = Pane.list
    /// Whether that column wears a ring, which it does once a key has moved
    /// in it and until the pointer chooses something.
    @Published var showsFocus = false
    /// ⌘/: the table of keys stands over the window.
    @Published var showsKeys = false
    /// Whether the sidebar is drawn, which the window's width decides with
    /// him (`PaneLayout`). The view says so, and ← reads it.
    var sidebarIsOut = true

    private let defaults: UserDefaults?
    /// The door's, in the main window. A window of one item and a model made
    /// with nothing have their own, which keep nothing.
    private let preferences: Preferences
    /// Follows `DetailChoices.revealWithOption`, so ⌥ is listened for from
    /// the turn the switch goes on and not after it goes off.
    var peeking: AnyCancellable?
    /// Where the generator's last settings are kept. The main window's
    /// defaults, in a window of one item too.
    let generatorDefaults: UserDefaults?
    private let now: () -> Date
    private let calendar: Calendar
    private var typed: (letters: String, at: Date)?
    /// Going back or forward is not itself somewhere new.
    private var isReturning = false
    private var arranged: (from: Arrangement, list: ItemList)?
    private var detailed: (revision: Int, detail: ItemDetail)?
    private var told: (from: Telling, banners: [Banner])?
    private var paged: (from: Paging, page: Dashboard)?
    /// What a click on a link does: hands the address to the default
    /// browser, or to whatever a test put in its place.
    let open: (URL) -> Void
    /// How many times the list was arranged, for the test that holds it to
    /// once per change and not once per frame.
    private(set) var arrangements = 0
    /// The same for the banners over the details and for Password Health's page.
    private(set) var tellings = 0
    private(set) var pagings = 0

    /// Without defaults nothing is remembered, which is what a shot and
    /// most tests want.
    init(store: VaultStore, defaults: UserDefaults? = nil, preferences: Preferences? = nil,
         icons: IconStore? = nil,
         calendar: Calendar = .current, now: @escaping () -> Date = Date.init,
         open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
         clipboard: Clipboard? = nil, stage: LargeTypeStage? = nil, pinned: String? = nil,
         generatorDefaults: UserDefaults? = nil, present: ((NSWindow) -> Void)? = nil,
         desk: AttachmentDesk? = nil, reprompt: Reprompt? = nil, armedFill: ArmedFill? = nil) {
        self.store = store
        self.desk = desk
        self.reprompt = reprompt
        self.armedFill = armedFill
        self.pinned = pinned
        windows = pinned == nil ? ItemWindows(present: present) : nil
        self.icons = icons ?? .off
        self.clipboard = clipboard ?? Clipboard(pasteboard: nil)
        self.stage = stage
        self.defaults = defaults
        self.generatorDefaults = generatorDefaults ?? defaults
        self.calendar = calendar
        self.now = now
        self.open = open
        let preferences = preferences ?? Preferences(defaults: defaults)
        self.preferences = preferences
        vaultsFolded = defaults?.bool(forKey: Self.vaultsFoldedKey) ?? false
        let list = preferences.settings.list
        category = list.category
        sort = ItemList.Sort(key: list.sort, isReversed: list.isReversed)
        peeking = preferences.$settings.map(\.details.revealWithOption).removeDuplicates().sink { [weak self] isOn in
            guard let self else { return }
            if !isOn {
                self.optionWatch = nil
                self.peek(false)
            } else if self.optionWatch == nil {
                self.optionWatch = OptionWatch { [weak self] in self?.peek($0) }
            }
        }
        // A sync can take the item out of the list, and an index that
        // arrives can take it out of what was found. Both say so before
        // they have changed, so the look is a turn later, and in that turn
        // the details are drawn empty.
        store.$revision.dropFirst().map { _ in () }
            .merge(with: store.$searchIndex.dropFirst().map { _ in () })
            .merge(with: store.$watch.dropFirst().map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.settle() } }
            .store(in: &watching)
    }

    /// The model of a window that shows `id` and nothing else, over the same
    /// vault, pasteboard and icons.
    func pinned(to id: String) -> Panes {
        Panes(store: store, icons: icons, calendar: calendar, now: now, open: open, clipboard: clipboard,
              stage: stage, pinned: id, generatorDefaults: generatorDefaults, desk: desk, reprompt: reprompt,
              armedFill: armedFill)
    }

    func toggleSidebar() {
        wantsSidebar.toggle()
        if !wantsSidebar, focus == .sidebar { focus = .list }
    }

    // MARK: The sidebar

    /// The rows above VAULTS, and the rows under it. Archive is there only
    /// for an account that has one.
    let upperRows: [SidebarRow] = [.allItems, .favorites, .passwordHealth]
    var lowerRows: [SidebarRow] { store.mayArchive ? [.archive, .trash] : [.trash] }
    var vaults: [Vault] { store.shelves.vaults }

    /// All Items when the row he chose is no longer drawn: a vault deleted on
    /// another device, an archive that has emptied.
    var selection: SidebarRow {
        switch chosen {
        case .vault(let place) where !vaults.contains { $0.id == place }: return .allItems
        case .archive where !store.mayArchive: return .allItems
        default: return chosen
        }
    }

    /// A row of the sidebar is a list of its own, so choosing one ends a
    /// search.
    func select(_ row: SidebarRow) {
        select(row, moving: false)
    }

    /// `moving` is a step with the arrows, which is the same visit carried
    /// along and not a new one.
    func select(_ row: SidebarRow, moving: Bool) {
        guard leaveEdit() else { return }
        chosen = row
        if watched != nil { watched = nil }
        if !query.isEmpty { query = "" }
        settle()
        record(moving: moving)
    }

    /// A card's "Show Items": the list is that card's items, under its
    /// name, and the row is still Password Health. Choosing the row again, or
    /// going back, is the dashboard.
    func show(_ card: WatchCard) {
        guard leaveEdit() else { return }
        chosen = .passwordHealth
        watched = card
        if !query.isEmpty { query = "" }
        settle()
        record(moving: false)
        keysToList += 1
    }

    /// Whether the dashboard stands where the list and the details would.
    /// A search is the whole vault's, whatever it was typed over.
    var showsDashboard: Bool {
        pinned == nil && selection == .passwordHealth && watched == nil && !isSearching
    }

    /// ⌘2 to ⌘9: the vaults in the sidebar's order, folded shut or not.
    /// False when there are fewer vaults than that.
    @discardableResult
    func selectVault(at index: Int) -> Bool {
        guard vaults.indices.contains(index) else { return false }
        select(.vault(vaults[index].id))
        return true
    }

    func toggleVaults() {
        vaultsFolded.toggle()
        defaults?.set(vaultsFolded, forKey: Self.vaultsFoldedKey)
    }

    /// What the item list shows for the selected row, and nothing else.
    /// Password Health's is the card he asked to see, as it was last counted.
    var listed: [Entry] {
        let shelves = store.shelves
        switch selection {
        case .allItems: return shelves.all
        case .favorites: return shelves.favourites
        case .passwordHealth: return watched.flatMap { store.watch?.entries(of: $0) } ?? []
        case .vault(let place): return store.entries(in: place)
        case .archive: return shelves.archive
        case .trash: return shelves.trash
        }
    }

    // MARK: The item list

    /// Everything the arrangement depends on.
    private struct Arrangement: Equatable {
        let revision: Int
        let row: SidebarRow
        /// A card's items are of whatever kind they are, so it has no
        /// category, and they are new when they have been counted again.
        let card: WatchCard?
        let counted: Int
        let category: ItemList.Category
        let sort: ItemList.Sort
        let filter: String
        let query: String
        /// Which index answered, while one is being asked.
        let index: Int
    }

    /// `listed`, narrowed, sorted and under its headings, or what the
    /// search found while something is typed into it. Arranged when one of
    /// the things it is made from has changed, and handed back as it was
    /// until then.
    var list: ItemList {
        let card = selection == .passwordHealth ? watched : nil
        let from = Arrangement(revision: store.revision, row: selection, card: card,
                               counted: card == nil ? 0 : store.countings,
                               category: card == nil ? category : .all,
                               sort: sort, filter: isFiltering ? filter : "",
                               query: isSearching ? query : "", index: isSearching ? store.indexings : 0)
        if let arranged, arranged.from == from { return arranged.list }
        arrangements += 1
        let list = isSearching
            ? ItemList(found: store.searchIndex?.search(query) ?? [])
            : ItemList(listed, category: from.category, sort: sort, filter: from.filter, calendar: calendar)
        arranged = (from, list)
        return list
    }

    /// Nil when the item he chose is not in the list: another row of the
    /// sidebar, a category it is not in, a sync that deleted it. It is his
    /// again when the list has it again.
    var selectedItem: Entry? {
        if let pinned { return store.entry(id: pinned) }
        guard let chosenItem, let place = list.place(of: chosenItem) else { return nil }
        return list.entries[place]
    }

    func select(item id: String?, moving: Bool = false) {
        // The item in the form may be chosen again. Any other is a way out
        // of the form, which asks first if something in it was changed.
        if let editor, editor.id != id, !leaveEdit() { return }
        defer { record(moving: moving) }
        if id != chosenItem {
            showsCreated = false
            // Revealed is the chosen item's and no other's.
            putAway()
        }
        chosenItem = id
        shown = selectedItem?.id
        openMenu = nil
    }

    /// Quick Access's ⇧⌘O: the window on this item, wherever it was. All
    /// Items with nothing typed has every item that is not put away, and
    /// the category is left alone when the item is already in it.
    @discardableResult
    func show(item id: String) -> Bool {
        guard editor?.id == id || leaveEdit() else { return false }
        select(.allItems)
        if isFiltering { endFilter() }
        if list.place(of: id) == nil { choose(.all) }
        guard list.place(of: id) != nil else { return false }
        select(item: id)
        focus = .list
        keysToList += 1
        return true
    }

    /// The item in the details is no longer the one that was: he chose
    /// another row of the sidebar or another category, typed into the search
    /// or the filter, or a sync took it. What was being done to it is put
    /// away, as it is when he chooses another item, so an item that comes
    /// back comes back as it was first drawn, with nothing revealed.
    /// Everything that can change what the list holds ends here.
    func settle() {
        // With no item chosen there is nothing to look for, and the list is
        // left to be arranged when it is next drawn.
        guard chosenItem != nil || pinned != nil || shown != nil else { return }
        let now = selectedItem?.id
        guard now != shown else { return }
        shown = now
        if showsCreated { showsCreated = false }
        putAway()
    }

    /// What the details draw for the selected item, worked out when the
    /// selection or the vault changes and handed back as it was until then.
    ///
    /// It is made from the item as the store holds it and not from the
    /// row. A search's list and a card's are made behind each revision and
    /// off the main thread, and until the new one is in the row is still
    /// the entry the old one was made from: the item as it was before the
    /// save or the sync that moved the revision.
    var detail: ItemDetail? {
        guard let row = selectedItem?.item else {
            detailed = nil
            return nil
        }
        if let detailed, detailed.revision == store.revision, detailed.detail.id == row.id {
            return detailed.detail
        }
        let item = store.entry(id: row.id)?.item ?? row
        let detail = ItemDetail(item: item, vault: store.vault(of: item), calendar: calendar)
        detailed = (store.revision, detail)
        return detail
    }

    /// Everything the banners depend on.
    private struct Telling: Equatable {
        let revision: Int
        let counted: Int
        let item: String
        let cards: [WatchCard]
        let canEdit: Bool
    }

    /// What the selected item is told, which is nothing before the vault has
    /// been counted. The buttons are left off an item that cannot be changed.
    /// Each card's list is looked through for the item when the item, the
    /// vault, the count or the cards being drawn have changed, and the
    /// banners are handed back as they were until then.
    var banners: [Banner] {
        guard let entry = selectedItem, let watch = store.watch else {
            told = nil
            return []
        }
        let from = Telling(revision: store.revision, counted: store.countings, item: entry.id,
                           cards: store.cards, canEdit: canEdit)
        if let told, told.from == from { return told.banners }
        tellings += 1
        let found = watch.banners(for: entry, among: from.cards, now: now())
        let banners = from.canEdit ? found : found.map(\.withoutAct)
        told = (from, banners)
        return banners
    }

    /// Everything Password Health's page depends on.
    private struct Paging: Equatable {
        let isCounted: Bool
        let counted: Int
        let cards: [WatchCard]
    }

    /// Password Health's page, made when the vault has been counted again or a
    /// card's switch was turned, and handed back as it was until then.
    var dashboard: Dashboard {
        let from = Paging(isCounted: store.watch != nil, counted: store.countings, cards: store.cards)
        if let paged, paged.from == from { return paged.page }
        pagings += 1
        let page = Dashboard(store.watch, cards: from.cards)
        paged = (from, page)
        return page
    }

    /// Does `go` at once, or for an item that asks, when he has shown
    /// again that the vault is his (`Reprompt`). By then the details may
    /// be another item's, and then nothing is done: an answer is for the
    /// item it was asked about.
    func guarded(_ act: GuardedAct, then go: @escaping @MainActor (Panes) -> Void) {
        guard let reprompt, let item = selectedItem?.item else { return go(self) }
        reprompt.allow(act, on: item) { [weak self] in
            guard let self, self.selectedItem?.id == item.id else { return }
            go(self)
        }
    }

    /// Whether the item in the details is still waiting to be answered for.
    var isHeldBack: Bool {
        guard let reprompt, let item = selectedItem?.item else { return false }
        return reprompt.asks(about: item)
    }

    /// How strong the selected item's password is: nil until the store has
    /// worked it out, and for an item with no password.
    var strength: Strength? { selectedItem?.strength }

    func toggleCreated() {
        showsCreated.toggle()
    }

    /// A link in the details, clicked. Only what a browser opens is handed
    /// on, whatever the note it came from says.
    @discardableResult
    func follow(_ link: URL) -> Bool {
        guard NoteText.mayOpen(link) else { return false }
        open(link)
        return true
    }

    /// A click on a row, which also takes the keys to the list.
    func click(item id: String) {
        select(item: id)
        focus = .list
        showsFocus = false
        keysToList += 1
    }

    /// Down and up. With nothing selected, down is the first row and up the
    /// last, and at either end the selection stays where it is.
    func moveSelection(by step: Int) {
        let list = self.list
        guard !list.isEmpty, step != 0 else { return }
        let last = list.entries.count - 1
        let place = selectedItem.flatMap { list.place(of: $0.id) }
            .map { min(max($0 + step, 0), last) } ?? (step > 0 ? 0 : last)
        select(item: list.entries[place].id, moving: true)
    }

    /// A letter typed at the list: the first row whose title starts with
    /// what has been typed since the last pause. False when no title does,
    /// and the selection stays.
    /// Whether a word is under way, so that a space belongs to it.
    var isTyping: Bool {
        typed.map { now().timeIntervalSince($0.at) < Self.typingPause } ?? false
    }

    @discardableResult
    func type(_ letters: String) -> Bool {
        focus = .list
        let moment = now()
        var word = letters
        if let typed, moment.timeIntervalSince(typed.at) < Self.typingPause {
            word = typed.letters + letters
        }
        typed = (word, moment)
        guard let found = list.first(titled: word) else { return false }
        select(item: found.id, moving: true)
        return true
    }

    func choose(_ category: ItemList.Category) {
        self.category = category
        preferences.settings.list.category = category
        openMenu = nil
        settle()
    }

    /// A key starts in its own first direction: A to Z, or newest first.
    func order(by key: ItemList.Key) {
        sort = ItemList.Sort(key: key, isReversed: false)
        remember(sort)
        openMenu = nil
    }

    func order(reversed: Bool) {
        sort.isReversed = reversed
        remember(sort)
        openMenu = nil
    }

    private func remember(_ sort: ItemList.Sort) {
        preferences.settings.list.sort = sort.key
        preferences.settings.list.isReversed = sort.isReversed
    }

    func toggle(_ menu: ListMenu) {
        reading.menu = nil
        detailMenu = nil
        openMenu = openMenu == menu ? nil : menu
    }

    /// ⌥⌘F: the header becomes a field, and the list is what matches it.
    /// Not while a search has the list.
    func beginFilter() {
        guard !isSearching else { return }
        openMenu = nil
        isFiltering = true
        settle()
    }

    /// The field goes and what was typed into it goes with it.
    func endFilter() {
        isFiltering = false
        filter = ""
        keysToList += 1
    }

    /// Esc at the list: the table of keys first, then a question, then a
    /// vault's name or its question, then the sheet of kinds, then the generator, then the open menu, then what the engine refused, then the search, then the
    /// filter, which a search hides while it has the list, and last the
    /// form, which asks before it goes if anything in it was changed. False
    /// when there was none of them.
    @discardableResult
    func dismiss() -> Bool {
        if showsKeys {
            showsKeys = false
            return true
        }
        if isAskingToDiscard {
            isAskingToDiscard = false
            return true
        }
        if naming != nil {
            naming = nil
            return true
        }
        if deletingVault != nil {
            deletingVault = nil
            return true
        }
        if choosing != nil {
            choosing = nil
            return true
        }
        if reading.history != nil {
            closeHistory()
            return true
        }
        if generator != nil {
            endGenerating()
            return true
        }
        if editor?.menu != nil {
            editor?.menu = nil
            return true
        }
        if confirming != nil {
            confirming = nil
            return true
        }
        if detailMenu != nil {
            detailMenu = nil
            return true
        }
        if reading.menu != nil {
            reading.menu = nil
            return true
        }
        if openMenu != nil {
            openMenu = nil
            return true
        }
        if refused != nil {
            refused = nil
            return true
        }
        if !query.isEmpty {
            endSearch()
            return true
        }
        if isFiltering {
            endFilter()
            return true
        }
        guard editor != nil else { return false }
        cancelEdit()
        return true
    }

    // MARK: Search

    /// Whether the list is showing what was found and not a sidebar row.
    var isSearching: Bool { !query.allSatisfy(\.isWhitespace) }

    /// ⌘F: the caret goes to the toolbar's field.
    func beginSearch() {
        reading.menu = nil
        openMenu = nil
        keysToSearch += 1
    }

    /// Esc in the field: what was typed goes, the list comes back and has
    /// the keys.
    func endSearch() {
        query = ""
        keysToList += 1
        history.amend(place)
    }

    /// Return in the field: the first of what was found, unless he had
    /// already chosen among them, and the keys to the list.
    func submitSearch() {
        guard isSearching else { return }
        if selectedItem == nil, let first = list.entries.first { select(item: first.id) }
        keysToList += 1
    }

    // MARK: Back and forward

    /// Where the window is. What a search found is in All Items whatever
    /// row it was typed over, so that is where going back looks for it.
    private var place: Visit {
        Visit(row: isSearching ? .allItems : selection, item: selectedItem?.id,
              card: isSearching || selection != .passwordHealth ? nil : watched)
    }

    private func record(moving: Bool) {
        guard !isReturning, pinned == nil else { return }
        if moving {
            history.amend(place)
        } else {
            history.visit(place)
        }
    }

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    /// ⌘[. False with nowhere to go back to.
    @discardableResult
    func goBack() -> Bool {
        guard let visit = history.goBack() else { return false }
        show(visit)
        return true
    }

    /// ⌘].
    @discardableResult
    func goForward() -> Bool {
        guard let visit = history.goForward() else { return false }
        show(visit)
        return true
    }

    /// The row and the item as they were. A row a sync has since taken away
    /// is All Items, an item it has taken is nothing selected, and an item
    /// the list's category now hides brings every category back.
    private func show(_ visit: Visit) {
        isReturning = true
        defer { isReturning = false }
        select(visit.row)
        if let card = visit.card { show(card) }
        select(item: visit.item)
        if let id = visit.item, selectedItem == nil, visit.card == nil, category != .all, listed.contains(where: { $0.id == id }) {
            choose(.all)
        }
        keysToList += 1
    }

    // MARK: The account's menu

    @discardableResult
    func syncNow() -> Task<Void, Never> {
        Task { [store] in await store.sync() }
    }

    @discardableResult
    func lock() -> Task<Void, Never> {
        Task { [store] in await store.lock() }
    }
}
