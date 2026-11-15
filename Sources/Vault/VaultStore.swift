import Combine
import Foundation

/// One item as the store holds it. A class, so a sync that changed one item
/// of forty hands every view the other thirty-nine as the objects they
/// already had, and so that "nothing is left after a lock" is something a
/// weak reference can show.
final class Entry: Identifiable, Redacted {
    let item: Item
    var id: String { item.id }
    /// How strong its password is, once that has been worked out
    /// (`VaultStore.score`). Nil until then, and for an item with none.
    fileprivate(set) var strength: Strength?

    init(_ item: Item) {
        self.item = item
    }

    var redactedLabel: String { "Entry(\(item.id))" }
}

/// What can be done to one item that the engine has to be told of.
enum ItemChange: Equatable {
    case favourite(Bool)
    /// To Personal or to a folder. A collection takes nothing (D9).
    case move(Vault.Place)
    case duplicate
    case archive, unarchive
    /// To the trash, back out of it, and past it.
    case delete, restore, deleteForGood
    /// The item as the editor left it (`Editor`), which still carries the
    /// object its form was filled from.
    case edit(Item)
    /// One file more among its attachments, read from where it is.
    case attach(URL)
    /// One passkey more on a login (`PasskeyDoor`).
    case passkey(MadePasskey)
}

/// The item the editor's form was filled from is not the one the store
/// holds any longer: a sync brought another while the form was open. Nothing
/// was sent, since what would have been sent was made from the old object
/// and would have put it back over the new one.
struct ItemChangedElsewhere: Error, Equatable {}

/// The only thing a view reads. While unlocked it holds every item, decrypted,
/// read once after the unlock and again after a sync; views read this and
/// never the engine. `lock()` empties it (D6).
@MainActor
final class VaultStore: ObservableObject {
    enum State: Equatable {
        case noCLI, loggedOut, locked, unlocking, unlocked
        /// With the engine's own sentence, or this app's for a shape it did
        /// not expect.
        case failed(String)
    }

    /// Posted with the store still full, in the turn the lock was asked
    /// for, for what must be gone before anything is taken out of it: a
    /// connection that could still be answered from it (`BrowserDoor`).
    static let willLock = Notification.Name("VaultStore.willLock")

    /// Posted when the store has been emptied, in the turn the lock was
    /// asked for. The engine is shut behind it, and whoever awaits `lock`
    /// has waited for that too. Every window and panel that shows
    /// anything listens for it.
    static let didLock = Notification.Name("VaultStore.didLock")

    /// Posted after the account has been taken off this Mac, for whatever
    /// keeps something of it that the store does not hold.
    static let didSignOut = Notification.Name("VaultStore.didSignOut")

    /// A sync is skipped after an unlock when the last one is younger than
    /// this.
    static let freshFor: TimeInterval = 5 * 60

    /// How long after a read that would take items away they are read
    /// again. An engine answering short is back to itself in less, as far as
    /// its source can be read (`docs/notes.md`, "When a list comes back
    /// short"), and an item deleted elsewhere arrives this much later.
    nonisolated static let secondRead: TimeInterval = 2

    @Published private(set) var state: State = .locked
    /// Moves when anything in the vault does. Everything below is as of it.
    @Published private(set) var revision = 0
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastSyncFailed = false
    /// When the server was last asked, whether or not it answered. What
    /// decides that it is time to ask again is measured from here and not
    /// from the last answer, so a Mac with no network asks as seldom as one
    /// with it (`SyncPolicy`). After an unlock it is the day `bw` gives.
    @Published private(set) var lastAttempt: Date?
    /// Whether the server is being asked now.
    @Published private(set) var isSyncing = false
    @Published private(set) var email: String?
    /// Where the account lives, as the engine says it. Nil is Bitwarden's
    /// own server, or no account.
    @Published private(set) var server: String?
    /// What the engine said when it last refused an unlock.
    @Published private(set) var refusal: String?
    /// Moves when passwords have been given their levels, which arrive
    /// behind the items and change nothing else about them.
    @Published private(set) var scored = 0
    /// What a search asks (`SearchIndex`). It arrives behind the items of
    /// each revision and goes at the lock; nil is not yet, or locked.
    @Published private(set) var searchIndex: SearchIndex?
    /// What Password Health counts (`Watch`). It arrives behind the levels of
    /// each revision and goes at the lock; nil is not yet, or locked.
    @Published private(set) var watch: Watch?

    private(set) var folders: [Folder] = []
    private(set) var collections: [SharedCollection] = []
    private var entries: [Entry] = []
    private var trashed: [Entry] = []
    /// Which opening of the vault this is. A change that was sent during
    /// one opening and answered during a later one belongs to neither
    /// (`apply`).
    private(set) var opening = 0
    /// How many times the vault has been told to shut. An unlock that
    /// finds it moved after a wait was locked while it was opening, and
    /// opens nothing: the lock is the last word.
    private var shuts = 0
    /// Which unlock is the latest. One that was locked out and comes back
    /// under a later one leaves the engine to that one.
    private var attempts = 0
    /// How many changes are with the engine and not yet answered.
    private var writing = 0 {
        didSet { if writing > oldValue { changes += 1 } }
    }
    /// How many changes have been sent since the store was made.
    private var changes = 0
    /// The last lock's wait for the engine to be gone. The next unlock
    /// starts behind it, so that two children are never alive at once.
    private var engineGoing: Task<Void, Never>?

    /// The lists every surface draws from, computed once per `revision` and
    /// never per frame.
    struct Shelves {
        var all: [Entry] = []
        var favourites: [Entry] = []
        /// Keyed by folder id; nil is Personal, the items in no folder.
        var byFolder: [String?: [Entry]] = [:]
        /// Keyed by collection id. An item may be in several, and in a folder
        /// as well.
        var byCollection: [String: [Entry]] = [:]
        /// The rows under VAULTS, in the sidebar's order.
        var vaults: [Vault] = [.personal]
        var byType: [ItemType: [Entry]] = [:]
        var archive: [Entry] = []
        var trash: [Entry] = []
    }

    /// What one read of the engine's lists brought.
    private struct Lists {
        let items: [Item]
        let trash: [Item]
        let folders: [Folder]
        let collections: [SharedCollection]
    }

    private var shelved: (revision: Int, shelves: Shelves)?
    /// How many times the shelves were computed, for the test that holds this
    /// to once per revision.
    private(set) var derivations = 0

    var shelves: Shelves {
        if let shelved, shelved.revision == revision { return shelved.shelves }
        derivations += 1
        var shelves = Shelves()
        shelves.archive = entries.filter(\.item.isArchived)
        shelves.all = entries.filter { !$0.item.isArchived }
        shelves.favourites = shelves.all.filter(\.item.favorite)
        shelves.byFolder = Dictionary(grouping: shelves.all, by: \.item.folderID)
        for entry in shelves.all {
            for collection in entry.item.collectionIDs {
                shelves.byCollection[collection, default: []].append(entry)
            }
        }
        shelves.vaults = Vault.ordered(folders: folders, collections: collections)
        shelves.byType = Dictionary(grouping: shelves.all, by: \.item.type)
        shelves.trash = trashed
        shelved = (revision, shelves)
        return shelves
    }

    /// What a vault's row lists.
    func entries(in place: Vault.Place) -> [Entry] {
        switch place {
        case .personal: return shelves.byFolder[nil] ?? []
        case .folder(let id): return shelves.byFolder[id] ?? []
        case .collection(let id): return shelves.byCollection[id] ?? []
        }
    }

    /// Whether the sidebar draws Archive. The archive is Premium's: 2026.9.1
    /// refused a free account with "Premium status is required to use this
    /// feature." Nothing the engine answers says which kind an account is,
    /// so an archive with something in it is the proof that there is one.
    var mayArchive: Bool { !shelves.archive.isEmpty }

    func entry(id: String) -> Entry? {
        entries.first { $0.id == id } ?? trashed.first { $0.id == id }
    }

    private let backend: VaultBackend
    /// This store's clock. Every age it states is read against it.
    let now: () -> Date
    private let readsAgainAfter: TimeInterval
    /// The sync started behind an unlock, kept so a test can wait for it.
    private(set) var backgroundSync: Task<Void, Never>?
    /// The levels being worked out off the main thread, kept so a shot and a
    /// test can wait for them and a lock can stop them.
    private(set) var scoring: Task<Void, Never>?
    /// How many passwords have been given a level since the store was made,
    /// for the test that holds it to once for each per unlock.
    private(set) var scorings = 0
    /// The index being made off the main thread, kept for the same two.
    private(set) var indexing: Task<Void, Never>?
    /// How many indexes have been made, for the test that holds it to one
    /// per revision.
    private(set) var indexings = 0
    /// Password Health's lists being made off the main thread, kept for the same
    /// two.
    private(set) var counting: Task<Void, Never>?
    /// How many times they have been made, for the test that holds it to
    /// once per revision.
    private(set) var countings = 0

    /// Who is asked whether a password has been seen in a breach (D13). A
    /// store with none asks nobody, which is every test's unless it says
    /// otherwise.
    let breaches: Breaches?
    /// Who is asked which sites take a one-time code (D13), on the same
    /// terms.
    let twoFactor: TwoFactorCheck?

    /// The cards Password Health has now: the four it counts by itself, and
    /// Vulnerable Passwords and Inactive two-factor authentication while
    /// their switches are on. Read when a page or a banner is drawn, so a
    /// switch turned off takes its card with it.
    var cards: [WatchCard] {
        WatchCard.allCases.filter { card in
            switch card {
            case .vulnerable: return breaches?.asks == true
            case .twoFactor: return twoFactor?.asks == true
            default: return true
            }
        }
    }

    init(backend: VaultBackend, now: @escaping () -> Date = Date.init, breaches: Breaches? = nil,
         twoFactor: TwoFactorCheck? = nil, secondRead: TimeInterval = VaultStore.secondRead) {
        self.backend = backend
        self.now = now
        readsAgainAfter = secondRead
        self.breaches = breaches
        self.twoFactor = twoFactor
        backend.onEngineLost = { [weak self] in
            Task { await self?.engineWent() }
        }
    }

    /// What the lock screen says when the engine went away under an open
    /// vault: it died, it closed its connection, or it never answered.
    static let engineWent = "The engine stopped answering."

    /// The engine is gone, so the vault shuts, and says why where a wrong
    /// password would. One that went while the vault was still opening is
    /// that unlock's own failure, and is said there.
    private func engineWent() async {
        let wasOpen = state == .unlocked
        await shut()
        if wasOpen, state == .locked { refusal = Self.engineWent }
    }

    // MARK: Opening

    /// Where the engine stands, asked when nothing is open: whether there is
    /// a `bw` at all, whether it has an account, and whose.
    func refresh() async {
        guard state != .unlocked, state != .unlocking else { return }
        do {
            let status = try await backend.status()
            // With no child serving the answer is a whole `bw` run, and a
            // password may have opened the vault under it.
            guard state != .unlocked, state != .unlocking else { return }
            email = status.email
            server = status.server
            switch status.state {
            case .noCLI: state = .noCLI
            case .loggedOut: state = .loggedOut
            case .locked, .unlocked: state = .locked
            }
        } catch {
            guard state != .unlocked, state != .unlocking else { return }
            state = .failed(Self.sentence(for: error))
        }
    }

    /// Whether the vault opened. The password is wiped either way. `kept`
    /// is for one that came out of the seal under a finger: nobody typed
    /// it, so the engine's no is said as the seal's.
    @discardableResult
    func unlock(password: SecretBytes, kept: Bool = false) async -> Bool {
        guard state != .unlocked, state != .unlocking else {
            password.wipe()
            return false
        }
        state = .unlocking
        refusal = nil
        attempts += 1
        let attempt = attempts
        let shuts = self.shuts
        do {
            await engineGoing?.value
            guard shuts == self.shuts else { throw VaultError.locked }
            try await backend.unlock(password: password)
            guard shuts == self.shuts else { throw VaultError.locked }
            try await load(unlessShutSince: shuts)
            return true
        } catch {
            guard shuts == self.shuts else {
                // Locked while it was opening. The lock has said so and
                // emptied the store; what this unlock started after the
                // lock shut the engine is shut here.
                password.wipe()
                if attempt == attempts { await backend.close() }
                return false
            }
            await fail(with: error)
            if kept, refusal == Self.notThePassword { refusal = Self.keptPasswordRefused }
            return false
        }
    }

    /// What a person is told for a master password the engine did not take.
    static let notThePassword = "That is not the master password."
    /// And for the one Touch ID was keeping, which is what a password
    /// changed in the web vault looks like from here.
    static let keptPasswordRefused = "The password Touch ID kept was refused."

    /// What is drawn for the engine's refusal of a password. 2026.9.1 says
    /// of a wrong one that a decryption failed, which is true and tells
    /// nobody what to do, so that sentence, and the one other versions are
    /// remembered to say, become this app's own. Any other refusal is the
    /// engine's to word.
    static func said(ofAPassword sentence: String) -> String {
        let said = sentence.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let wrong = ["cryptography error, the decryption operation failed", "invalid master password"]
        return wrong.contains { said.hasPrefix($0) } ? notThePassword : sentence
    }

    /// Whether this is the master password, asked while the vault is open
    /// and leaving it open whatever the answer (`Reprompt`). It throws
    /// what the engine said when the answer is no, and `VaultError.locked`
    /// when a lock came first. The password is wiped either way.
    func confirm(password: SecretBytes) async throws {
        guard state == .unlocked else {
            password.wipe()
            throw VaultError.locked
        }
        try await backend.confirm(password: password)
        guard state == .unlocked else { throw VaultError.locked }
    }

    private func load(unlessShutSince shuts: Int) async throws {
        var read = try await lists()
        // Nothing is held yet to doubt a list against, but no rows at all
        // can be `bw`'s answer to a decryption that threw (`sync`).
        if read.items.isEmpty {
            try? await Task.sleep(nanoseconds: UInt64(readsAgainAfter * 1_000_000_000))
            guard shuts == self.shuts else { throw VaultError.locked }
            read = try await lists()
        }
        Log.app.notice("\(self.readLine("unlock", read, missing: 0), privacy: .public)")
        let status = try? await backend.status()
        // Every wait of an unlock is behind this line.
        guard shuts == self.shuts else { throw VaultError.locked }
        entries = read.items.map(Entry.init)
        trashed = read.trash.map(Entry.init)
        opening += 1
        folders = read.folders
        collections = read.collections
        email = status?.email ?? email
        server = status?.server ?? server
        lastSync = status?.lastSync
        // Decided before anything is told the vault is open, so that
        // whatever else asks when a list is old (`SyncPolicy`) finds this
        // sync already counted and does not start a second.
        let isStale = lastSync.map { now().timeIntervalSince($0) > Self.freshFor } ?? true
        lastAttempt = isStale ? now() : lastSync
        lastSyncFailed = false
        revision += 1
        state = .unlocked
        score()
        index()
        count()

        // What `bw` already had is on screen. Whatever the server has that it
        // did not arrives behind it.
        if isStale {
            backgroundSync = Task { [weak self] in await self?.sync() }
        }
    }

    private func fail(with error: Error) async {
        await backend.close()
        empty()
        switch error {
        case VaultError.locked:
            state = .locked
        case VaultError.loggedOut:
            state = .loggedOut
        case VaultError.noCLI:
            state = .noCLI
        case VaultError.refused(let sentence):
            // A wrong password is a refusal, and so the door stays a door.
            refusal = Self.said(ofAPassword: sentence)
            state = .locked
        default:
            state = .failed(Self.sentence(for: error))
        }
    }

    // MARK: Shutting

    /// Empties every collection, shuts the engine, and tells every window.
    /// `forget` has the engine drop its session before it goes, for
    /// whoever is also deleting the seal (`Door.lockAndForget`).
    func lock(forget: Bool = false) async {
        shuts += 1
        await shut(forget: forget)
    }

    /// The lock itself, which the engine going by itself also comes to.
    /// That is no word of his, so an unlock it went under fails as itself.
    private func shut(forget: Bool = false) async {
        // The engine goes at once and takes a change it was making with
        // it. With `forget` its last request waits in the connection
        // behind that change, which is therefore made.
        let cutsAChange = writing > 0 && !forget
        backgroundSync?.cancel()
        backgroundSync = nil
        let wasOpen = state == .unlocked || state == .unlocking
        let scoring = self.scoring
        let indexing = self.indexing
        let counting = self.counting
        if wasOpen { NotificationCenter.default.post(name: Self.willLock, object: self) }
        empty()
        // Said before the first wait: an answer that is already on its way
        // finds the store locked and is filed nowhere, and the panes, the
        // pasteboard and the typist do not wait for a child to die.
        if wasOpen {
            state = .locked
            if cutsAChange { refusal = Self.cutShort }
            NotificationCenter.default.post(name: Self.didLock, object: self)
        }
        let before = engineGoing
        let going = Task { [backend, breaches, twoFactor] in
            await before?.value
            if forget { await backend.endSession() } else { await backend.close() }
            // It was holding the items it was reading, and lets go of them
            // at the next password it comes to. An index half made goes
            // the same way, and so do Password Health's lists.
            await scoring?.value
            await indexing?.value
            await counting?.value
            // After the count, which may have been asking: its answers,
            // and the connection it asked over.
            await breaches?.end()
            await twoFactor?.end()
        }
        engineGoing = going
        await going.value
        if engineGoing == going { engineGoing = nil }
    }

    /// What the lock screen says after a lock that came while the engine
    /// had a change to make: an edit, a new item, a file being attached.
    /// Whether the server has it depends on how far `bw` had got.
    static let cutShort = "A change was being saved at the lock and may be lost."

    /// Waits for the changes that are with the engine to be answered, for
    /// whoever is about to end it and can spare the time, which a quit can
    /// and a shut lid cannot.
    func settle(within ceiling: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(ceiling)
        while writing > 0, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Sign Out: the vault shut and the engine's session ended, and then
    /// the account taken off this Mac by the engine. What is left is the
    /// logged-out lock screen, with nobody's name on it.
    func signOut() async {
        await lock(forget: true)
        await backend.signOut()
        email = nil
        server = nil
        await refresh()
        NotificationCenter.default.post(name: Self.didSignOut, object: self)
    }

    private func empty() {
        scoring?.cancel()
        scoring = nil
        indexing?.cancel()
        indexing = nil
        searchIndex = nil
        counting?.cancel()
        counting = nil
        watch = nil
        entries = []
        trashed = []
        folders = []
        collections = []
        shelved = nil
        revision += 1
    }

    // MARK: Syncing

    /// How many syncs are waiting for their answer: Sync Now can be pressed
    /// while the unlock's own is still out.
    private var asking = 0

    /// What the foot of the sidebar says (`SyncStanding`), as of this
    /// store's clock at the moment it is read.
    var standing: SyncStanding {
        if isSyncing { return .syncing }
        if lastSyncFailed { return .offline }
        guard let lastSync else { return .never }
        return .synced(now().timeIntervalSince(lastSync))
    }

    /// How long ago the server was last asked, or nil when it never was.
    var sinceLastAttempt: TimeInterval? {
        lastAttempt.map { now().timeIntervalSince($0) }
    }

    /// Has whatever draws the standing draw it again. No clock ticks for the
    /// age it states, so it is as old as the last time something was drawn,
    /// and a window that has just come to the front is the moment it is
    /// read.
    func restate() {
        guard state == .unlocked else { return }
        objectWillChange.send()
    }

    func sync() async {
        guard state == .unlocked else { return }
        let opening = self.opening
        lastAttempt = now()
        asking += 1
        isSyncing = true
        defer {
            asking -= 1
            if asking == 0 { isSyncing = false }
        }
        do {
            try await backend.sync()
            let first = try await listsNoChangeLandedAmong()
            guard state == .unlocked, opening == self.opening else { return }
            // `bw` answers a list with no rows, and a 200, when its
            // decryption throws, and the next read has them all
            // (`docs/notes.md`, "When a list comes back short"). So what a
            // read would take away with no reason in it is read again.
            let doubted = missing(from: first)
            Log.app.notice("\(self.readLine("sync", first, missing: doubted.count), privacy: .public)")
            var read: Lists? = first
            if !doubted.isEmpty {
                try? await Task.sleep(nanoseconds: UInt64(readsAgainAfter * 1_000_000_000))
                guard state == .unlocked, opening == self.opening else { return }
                let second = try await listsNoChangeLandedAmong()
                guard state == .unlocked, opening == self.opening else { return }
                let gone = missing(from: second)
                Log.app.notice("\(self.readLine("second", second, missing: gone.count), privacy: .public)")
                // Missing something the first had, it is no likelier to be
                // right than the first, and the next sync asks again.
                read = gone.isSubset(of: doubted) ? second : nil
            }
            lastSync = now()
            lastSyncFailed = false
            if let read { merge(read) }
        } catch {
            // The list stays as it was: `bw` still has what it last saw.
            if state == .unlocked { lastSyncFailed = true }
        }
    }

    /// The four lists as the engine has them now.
    private func lists() async throws -> Lists {
        async let items = backend.items()
        async let trash = backend.trash()
        async let folders = backend.folders()
        // An account in no organisation got an empty list from 2026.9.1.
        // What one that is in one gets has not been seen, so a refusal here
        // is no collections and not a vault that will not open.
        async let collections = try? backend.collections()
        let (readItems, readTrash, readFolders) = try await (items, trash, folders)
        return Lists(items: readItems, trash: readTrash, folders: readFolders, collections: await collections ?? [])
    }

    /// The same, to be put over what is held. A list read before a change of
    /// this app's was answered has not heard of it and would take it back,
    /// so reads that a change landed among are read again.
    private func listsNoChangeLandedAmong() async throws -> Lists {
        while true {
            await settle()
            let sent = changes
            let read = try await lists()
            if sent == changes, writing == 0 { return read }
        }
    }

    /// What is held and in neither list of `read`. An item that went from
    /// one list to the other has its reason in the read and is not here.
    private func missing(from read: Lists) -> Set<String> {
        var missing = Set((entries + trashed).map(\.id))
        missing.subtract((read.items + read.trash).map(\.id))
        return missing
    }

    private func readLine(_ read: String, _ lists: Lists, missing: Int) -> String {
        Self.readLine(read, items: lists.items.count, trash: lists.trash.count, folders: lists.folders.count,
                      heldItems: entries.count, heldTrash: trashed.count, missing: missing)
    }

    /// By id: an item that came back the same keeps the `Entry` it had, so
    /// the selection and the scroll position survive, and a sync that changed
    /// nothing publishes nothing.
    private func merge(_ read: Lists) {
        func merged(_ incoming: [Item], over existing: [Entry]) -> [Entry] {
            let known = Dictionary(existing.map { ($0.id, $0) }) { first, _ in first }
            return incoming.map { item in
                guard let entry = known[item.id] else { return Entry(item) }
                if entry.item == item { return entry }
                let changed = Entry(item)
                // An item renamed or moved has the password it had.
                if item.login?.password == entry.item.login?.password { changed.strength = entry.strength }
                return changed
            }
        }
        let newEntries = merged(read.items, over: entries + trashed)
        let newTrash = merged(read.trash, over: trashed + entries)
        let same = newEntries.elementsEqual(entries, by: ===)
            && newTrash.elementsEqual(trashed, by: ===) && read.folders == folders
            && read.collections == collections
        guard !same else { return }
        entries = newEntries
        trashed = newTrash
        folders = read.folders
        collections = read.collections
        revision += 1
        score()
        index()
        count()
    }

    /// The line a read of the lists leaves in the log: counts, and which
    /// read it was.
    nonisolated static func readLine(_ read: String, items: Int, trash: Int, folders: Int, heldItems: Int,
                                     heldTrash: Int, missing: Int) -> String {
        "\(read) read \(items) items, \(trash) in the trash, \(folders) folders, "
            + "over \(heldItems) and \(heldTrash) held, \(missing) missing"
    }

    // MARK: Writing

    /// What a change says when it is asked of an item it cannot be made to.
    static let cannotWrite = "\(AppInfo.name) cannot change this item."

    /// What a duplicate of an organisation's item is refused with.
    static let cannotCopyShared = "An item in an organisation's collection cannot be duplicated from here."

    /// One change to one item: one call on the engine, and then the item put
    /// where it now belongs among what is held, with no list read again.
    /// What comes back is the item as it now stands, the copy for a
    /// duplicate, and nil for one that is gone for good. A refusal is thrown
    /// in the engine's own sentence and leaves everything here as it was.
    ///
    /// The routes that put an item on a shelf answer with no item, so the
    /// date written here is this Mac's and the next sync brings the server's.
    @discardableResult
    func apply(_ change: ItemChange, to id: String) async throws -> Item? {
        guard state == .unlocked, let entry = entry(id: id) else { throw VaultError.locked }
        let item = entry.item
        let opening = self.opening
        writing += 1
        defer { writing -= 1 }
        var after: Item?
        switch change {
        case .favourite(let isFavourite):
            var edited = item
            edited.favorite = isFavourite
            after = try await save(item, as: edited)
        case .move(let place):
            var edited = item
            switch place {
            case .personal: edited.folderID = nil
            case .folder(let folder): edited.folderID = folder
            case .collection: throw VaultError.refused(Self.cannotWrite)
            }
            after = try await save(item, as: edited)
        case .duplicate:
            // Its object names the organisation and its collections, and a
            // copy made from it would be the organisation's (D9).
            guard item.organizationID == nil else { throw VaultError.refused(Self.cannotCopyShared) }
            guard let object = item.copied() else { throw VaultError.refused(Self.cannotWrite) }
            after = try await backend.create(object)
        case .archive:
            try await backend.archive(item)
            after = item.put(on: .archive, at: now())
        case .unarchive:
            try await backend.unarchive(item)
            after = item.put(on: .archive, at: nil)
        case .delete:
            try await backend.delete(item, permanently: false)
            after = item.put(on: .trash, at: now())
        case .restore:
            try await backend.restore(item)
            after = item.put(on: .trash, at: nil)
        case .deleteForGood:
            try await backend.delete(item, permanently: true)
        case .edit(let edited):
            guard edited.raw == item.raw else { throw ItemChangedElsewhere() }
            after = try await save(item, changedTo: edited)
        case .attach(let file):
            after = try await backend.attach(file, to: item)
        case .passkey(let made):
            guard let object = item.patched(item, holding: made) else { throw VaultError.refused(Self.cannotWrite) }
            after = try await backend.save(item, as: object)
        }
        // Locked while the engine was answering: there is nothing to put it
        // back among, and nothing is. Locked and opened again: what is held
        // now was read after this change was sent, and the item it was made
        // from is the last opening's.
        guard state == .unlocked, opening == self.opening else { return nil }

        let made = after.map(Entry.init)
        if after?.login?.password == item.login?.password { made?.strength = entry.strength }
        if change != .duplicate {
            // Where it was, if it is still on the same side of the trash.
            if let made, let place = entries.firstIndex(where: { $0.id == id }), !made.item.isInTrash {
                entries[place] = made
            } else if let made, let place = trashed.firstIndex(where: { $0.id == id }), made.item.isInTrash {
                trashed[place] = made
            } else {
                entries.removeAll { $0.id == id }
                trashed.removeAll { $0.id == id }
                if let made { made.item.isInTrash ? trashed.append(made) : entries.append(made) }
            }
        } else if let made {
            entries.append(made)
        }
        revision += 1
        score()
        index()
        count()
        return after
    }

    /// An item of `type` to fill a form from, in the vault at `place`, or
    /// in Personal when that is a collection, which takes nothing (D9). The
    /// engine is asked for its templates each time, and nothing is held
    /// here until `create`.
    func blank(_ type: ItemType, in place: Vault.Place = .personal) async throws -> Item {
        guard state == .unlocked else { throw VaultError.locked }
        guard let name = type.templateName else { throw VaultError.refused(Self.cannotWrite) }
        let template = try await backend.template("item")
        let part: JSONValue
        do {
            part = try await backend.template(name)
        } catch VaultError.refused(let sentence) where type == .sshKey && Self.isNoTemplate(sentence) {
            // 2026.9.1 has no template for a key (`docs/notes.md`, "Making
            // an item").
            part = Item.keyPart
        }
        var folder: String?
        if case .folder(let id) = place { folder = id }
        return try Item.blank(type, from: template, part: part, in: folder)
    }

    /// Whether the engine's sentence is the one for a template it does not
    /// have: "Unknown template object." from 2026.9.1, and the words that
    /// stood here before it was asked, in case another version says them.
    /// Any other refusal of a key's template, a locked vault among them, is
    /// not a reason to make the item from this app's own keys.
    static func isNoTemplate(_ sentence: String) -> Bool {
        sentence.localizedCaseInsensitiveContains("unknown template")
            || sentence.localizedCaseInsensitiveContains("no template")
    }

    /// One attachment, decrypted by the engine and written to `destination`
    /// (D4). Where that is and how long the file stays there is the
    /// caller's to see to: this is the one thing decrypted that the store
    /// has written anywhere (D6, `OpenCopies`).
    func fetch(_ attachment: Attachment, of id: String, to destination: URL) async throws {
        guard state == .unlocked, let item = entry(id: id)?.item else { throw VaultError.locked }
        let opening = self.opening
        try await backend.fetch(attachment, of: item, to: destination)
        guard state == .unlocked, opening == self.opening else { throw VaultError.locked }
    }

    /// A password of the engine's own making (D4). It is handed back and
    /// kept nowhere here.
    func generate(_ recipe: PasswordRecipe) async throws -> String {
        guard state == .unlocked else { throw VaultError.locked }
        return try await backend.generate(recipe)
    }

    /// `blank` as the form left it, sent to the engine, and what came back
    /// put among the items. Nil when the vault was locked meanwhile.
    @discardableResult
    func create(_ edited: Item, from blank: Item, holding passkey: MadePasskey? = nil) async throws -> Item? {
        guard state == .unlocked else { throw VaultError.locked }
        guard let object = blank.patched(edited, holding: passkey) else { throw VaultError.refused(Self.cannotWrite) }
        let opening = self.opening
        writing += 1
        defer { writing -= 1 }
        let made = try await backend.create(object)
        guard state == .unlocked, opening == self.opening else { return nil }
        entries.append(Entry(made))
        revision += 1
        score()
        index()
        count()
        return made
    }

    private func save(_ item: Item, as edited: Item) async throws -> Item {
        guard let object = item.patched(edited) else { throw VaultError.refused(Self.cannotWrite) }
        return try await backend.save(item, as: object)
    }

    /// An edit, and with it the password the item had, when the edit gave it
    /// another: that one has to be first among its earlier passwords
    /// afterwards. 2026.9.1 sees to that itself, and holds the password once
    /// when it is sent one as well (`docs/notes.md`, "Editing an item"). It
    /// is sent anyway: an old password that a later `bw` stopped keeping
    /// would be lost with nothing to show for it, and sending it costs one
    /// member of a list. An engine that added to what it was sent would
    /// have it twice, and is sent the list again with one of the two taken
    /// out. If that second word is refused the edit has still been made,
    /// and the old password is in the list twice and not lost.
    private func save(_ item: Item, changedTo edited: Item) async throws -> Item {
        guard let old = item.login?.password, !old.isEmpty, old != edited.login?.password else {
            return try await save(item, as: edited)
        }
        let saved = try await save(item, as: edited.remembering(old, at: now()))
        guard saved.passwordHistory.prefix(2).map(\.password) == [old, old] else { return saved }
        var once = saved
        once.passwordHistory.removeFirst()
        guard let repaired = try? await save(saved, as: once) else {
            Log.app.error("an earlier password is in an item's history twice")
            return saved
        }
        return repaired
    }

    // MARK: Vaults

    /// What a name is refused for before the engine is asked, in the words
    /// he reads.
    static let nameless = "A vault needs a name."
    static func taken(_ name: String) -> String { "There is already a vault called “\(name)”." }

    /// The name as it will be sent: trimmed, not empty, and not another
    /// vault's, Personal's and a collection's included, with İ, I, ı and i
    /// as one letter. `renaming` is the vault the name is for, which may
    /// keep its own name or change its case.
    func checkedName(_ typed: String, renaming place: Vault.Place? = nil) throws -> String {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw VaultError.refused(Self.nameless) }
        let folded = SearchIndex.folded(name)
        let clash = shelves.vaults.contains { $0.id != place && SearchIndex.folded($0.name) == folded }
        guard !clash else { throw VaultError.refused(Self.taken(name)) }
        return name
    }

    /// A folder made, among the vaults. Nil when the vault was locked while
    /// the engine was answering: there is nothing to put it among.
    @discardableResult
    func makeVault(named typed: String) async throws -> Vault? {
        guard state == .unlocked else { throw VaultError.locked }
        let name = try checkedName(typed)
        let opening = self.opening
        writing += 1
        defer { writing -= 1 }
        let made = try await backend.createFolder(named: name)
        guard state == .unlocked, opening == self.opening else { return nil }
        folders.append(made)
        revision += 1
        return Vault(id: .folder(made.id), name: made.name)
    }

    /// A folder's new name. Nothing is sent when it is the one it has.
    func renameVault(_ place: Vault.Place, to typed: String) async throws {
        guard state == .unlocked else { throw VaultError.locked }
        guard case .folder(let id) = place, let folder = folders.first(where: { $0.id == id }) else {
            throw VaultError.refused(Self.cannotWrite)
        }
        let name = try checkedName(typed, renaming: place)
        guard name != folder.name else { return }
        let opening = self.opening
        writing += 1
        defer { writing -= 1 }
        let renamed = try await backend.rename(folder, to: name)
        guard state == .unlocked, opening == self.opening,
              let at = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[at] = renamed
        revision += 1
    }

    /// A folder gone, and what was in it, the trash's and the archive's
    /// too, in no folder, which is where the server puts it. Not one item
    /// is sent: the engine has already moved them, and the next sync brings
    /// whatever else it changed.
    func deleteVault(_ place: Vault.Place) async throws {
        guard state == .unlocked else { throw VaultError.locked }
        guard case .folder(let id) = place, let folder = folders.first(where: { $0.id == id }) else {
            throw VaultError.refused(Self.cannotWrite)
        }
        let opening = self.opening
        writing += 1
        defer { writing -= 1 }
        try await backend.delete(folder)
        guard state == .unlocked, opening == self.opening else { return }
        func emptied(_ held: [Entry]) -> [Entry] {
            held.map { entry in
                guard entry.item.folderID == id else { return entry }
                let moved = Entry(entry.item.outsideItsFolder())
                moved.strength = entry.strength
                return moved
            }
        }
        entries = emptied(entries)
        trashed = emptied(trashed)
        folders.removeAll { $0.id == id }
        revision += 1
        index()
        count()
    }

    // MARK: Scoring

    /// Gives every password that has no level one (`Strength`), off the main
    /// thread, and publishes once when they are all in. The passwords are
    /// read where the items hold them and go nowhere; what comes back is the
    /// levels. A password is scored once per unlock: an item a sync brought
    /// back unchanged keeps its `Entry` and so its level, and one that came
    /// back with the same password is handed it.
    private func score() {
        scoring?.cancel()
        let waiting = (entries + trashed).filter { entry in
            entry.strength == nil && entry.item.login?.password?.isEmpty == false
        }
        guard !waiting.isEmpty else {
            scoring = nil
            return
        }
        scoring = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) { Strength.levels(of: waiting) }
            let levels = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let levels, !Task.isCancelled, let self else { return }
            for (entry, level) in zip(waiting, levels) { entry.strength = level }
            self.scorings += waiting.count
            self.scored += 1
        }
    }

    // MARK: Indexing

    /// Makes the index of this revision's items, off the main thread. The
    /// one before it answers until this one is in, so a sync does not empty
    /// a search that is on screen. Archived and deleted items are not in it.
    private func index() {
        indexing?.cancel()
        let listed = shelves.all
        indexing = Task { [weak self] in
            let made = await Task.detached(priority: .userInitiated) { SearchIndex(listed) }.value
            guard !Task.isCancelled, let self else { return }
            self.searchIndex = made
            self.indexings += 1
        }
    }

    // MARK: Watching

    /// Makes Password Health's lists for this revision's items, off the main
    /// thread, once their passwords have their levels. The ones before them
    /// answer until these are in. Whatever moves the items again cancels
    /// this and asks anew, so the items it reads after the wait are the
    /// ones it was asked about.
    ///
    /// With the breach check on, the lists come in twice: at once with what
    /// is already known of these passwords, so a sync does not empty a card
    /// that was answered, and again when the ones nobody has asked about
    /// have been asked about. The count before this one is waited for
    /// first, since two asking at once would ask about the same five
    /// characters twice. The list of sites that take a code is held for the
    /// unlock, so it is in the first and, when it is not yet, is a third
    /// in between.
    private func count() {
        let before = counting
        before?.cancel()
        let scoring = self.scoring
        counting = Task { [weak self] in
            await scoring?.value
            guard !Task.isCancelled, let now = self?.now(),
                  let listed = self?.shelves.all.map({ (entry: $0, strength: $0.strength) }) else { return }
            let made = await Task.detached(priority: .userInitiated) { Watch(listed, now: now) }.value
            guard !Task.isCancelled, let self else { return }
            let breaches = self.breaches.flatMap { $0.asks ? $0 : nil }
            let twoFactor = self.twoFactor.flatMap { $0.asks ? $0 : nil }
            guard breaches != nil || twoFactor != nil else {
                self.watch = made
                self.countings += 1
                return
            }
            let logins = listed.map(\.entry)
            let known = await breaches?.sightings(among: logins)
            let offered = await twoFactor?.held
            guard !Task.isCancelled else { return }
            // A card that was answered keeps its answer meanwhile. One that
            // never was has no number yet.
            var next = made
            if let known {
                let had = self.watch?.vulnerable != nil
                next = next.seen(known.unasked == 0 || had ? known.seen : nil)
            }
            if let offered { next = await Self.marked(next, logins, by: offered) }
            guard !Task.isCancelled else { return }
            self.watch = next
            self.countings += 1
            if let twoFactor, offered == nil, let list = await twoFactor.load(), !Task.isCancelled {
                next = await Self.marked(next, logins, by: list)
                guard !Task.isCancelled else { return }
                self.watch = next
                self.countings += 1
            }
            guard let breaches, let known, known.unasked > 0 else { return }
            await before?.value
            guard !Task.isCancelled, await breaches.ask(about: logins) else { return }
            let answered = await breaches.sightings(among: logins)
            // A pass the network failed from its first request says nothing new.
            guard !Task.isCancelled, answered.unasked < known.unasked else { return }
            self.watch = next.seen(answered.seen)
            self.countings += 1
        }
    }

    /// The lists with the logins that lack a code their site would take,
    /// worked out off the main thread.
    private static func marked(_ watch: Watch, _ logins: [Entry], by list: TwoFactorList) async -> Watch {
        await Task.detached(priority: .userInitiated) { watch.inactive(among: logins, by: list) }.value
    }

    /// Counts again with nothing having moved: what a Password Health switch
    /// calls when it is turned, since the lists hold its card.
    func recount() {
        guard state == .unlocked else { return }
        count()
    }

    // MARK: -

    private static func sentence(for error: Error) -> String {
        switch error {
        case VaultError.refused(let sentence): return sentence
        case VaultError.timeout: return "The engine took too long to answer."
        case VaultError.transport: return engineWent
        case VaultError.turnedAway(let status): return VaultError.turnedAwaySentence(status)
        case let shape as ShapeError: return shape.sentence
        default: return "Something went wrong opening the vault."
        }
    }
}
