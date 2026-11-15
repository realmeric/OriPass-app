import AppKit
import SwiftUI
import XCTest
@testable import OriPass

@MainActor
final class SearchTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "oripass-search-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func backend(_ vault: (items: [JSONValue], folders: [JSONValue]) = DemoVault.objects()) -> FakeBackend {
        let backend = FakeBackend(items: vault.items, folders: vault.folders, password: DemoVault.password)
        // Synced a minute ago, so no sync is running behind the search.
        backend.lastSync = Date().addingTimeInterval(-60)
        return backend
    }

    /// The demo vault open, with its index in.
    private func unlocked(_ backend: FakeBackend? = nil) async -> VaultStore {
        let store = VaultStore(backend: backend ?? self.backend())
        await store.unlock(password: SecretBytes(DemoVault.password))
        await store.indexing?.value
        return store
    }

    private func demoIndex() async throws -> SearchIndex {
        let store = await unlocked()
        return try XCTUnwrap(store.searchIndex)
    }

    /// A login, changed `age` days before the others' newest.
    private func login(_ name: String, user: String? = nil, address: String? = nil, notes: String? = nil,
                       fields: [(name: String, value: String, type: Int64)] = [], age: Int = 0) throws -> Entry {
        let changed = Date(timeIntervalSince1970: 1_790_000_000).addingTimeInterval(-Double(age) * 86_400)
        return Entry(try Item(json: .object([
            "id": .string("id-\(name)"), "type": .int(1), "name": .string(name),
            "notes": JSONValue(notes), "revisionDate": .string(VaultDate.string(changed)),
            "fields": .array(fields.map {
                .object(["name": .string($0.name), "value": .string($0.value), "type": .int($0.type)])
            }),
            "login": .object([
                "username": JSONValue(user), "password": .string("hunter2-of-\(name)"),
                "uris": .array(address.map { [.object(["uri": .string($0), "match": .null])] } ?? []),
            ]),
        ])))
    }

    private func hosted(_ panes: Panes) -> NSWindow {
        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: PanesView(panes: panes))
        window.setContentSize(Metrics.windowSize)
        window.layoutIfNeeded()
        return window
    }

    private func turn(_ seconds: Double = 0.05) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: Spelling

    func testATitleIsFoundHoweverItsLettersAreTyped() async throws {
        let index = try await demoIndex()
        for query in ["is bankasi", "iş bankası", "İŞ BANKASI", "IS BANKASI", "ış bankası", "  İş   Bankası "] {
            XCTAssertEqual(index.search(query).first?.item.name, "İş Bankası", "typed as \(query)")
        }
        XCTAssertEqual(SearchIndex.folded("İŞ BANKASI"), "is bankasi")
        XCTAssertEqual(SearchIndex.folded("ıIiİ ÇĞÖŞÜ çğöşü Éclair"), "iiii cgosu cgosu eclair")
    }

    func testCicekIsFoundWithAndWithoutItsCedillas() async throws {
        let index = try await demoIndex()
        XCTAssertEqual(index.search("cicek").map(\.item.name), ["Çiçeksepeti"])
        XCTAssertEqual(index.search("ÇİÇEK").map(\.item.name), ["Çiçeksepeti"])
        XCTAssertEqual(index.search("kadikoy").first?.item.name, "Kadıköy Belediyesi")
    }

    // MARK: Order

    func testGitFindsGitHubBeforeDigitalOcean() async throws {
        let index = try await demoIndex()
        let found = index.search("git").map(\.item.name)
        let hub = try XCTUnwrap(found.firstIndex(of: "GitHub"))
        let ocean = try XCTUnwrap(found.firstIndex(of: "Digital Ocean"))
        // A key's title starts with it too, and was changed after GitHub.
        XCTAssertEqual(found, ["Git imza anahtarı", "GitHub", "Digital Ocean"])
        XCTAssertLessThan(hub, ocean)
    }

    func testTheOrderIsTitleStartThenWordThenInsideThenUsernameThenHostThenTheRest() throws {
        // Given newest first where it would be wrong, so that the order
        // found is the search's and not the dates'.
        let entries = [
            try login("Zarf", fields: [(name: "Kargo takibi", value: "x", type: 0)], age: 0),
            try login("Not defteri", notes: "kargo geldi", age: 1),
            try login("Posta", address: "https://kargo.example.com/giris", age: 2),
            try login("Adres", user: "kargo@example.com", age: 3),
            try login("Yurtiçikargo", age: 4),
            try login("Aras Kargo", age: 5),
            try login("Kargo Takip", age: 6),
        ]
        let index = SearchIndex(entries)
        XCTAssertEqual(index.search("kargo").map(\.item.name),
                       ["Kargo Takip", "Aras Kargo", "Yurtiçikargo", "Adres", "Posta", "Zarf", "Not defteri"])
        // A word after a hyphen or a dot starts a word too.
        let marks = SearchIndex([try login("e-Devlet"), try login("Devlet Tiyatrosu", age: 1),
                                 try login("AnaDevlet", age: 2)])
        XCTAssertEqual(marks.search("devlet").map(\.item.name), ["Devlet Tiyatrosu", "e-Devlet", "AnaDevlet"])
    }

    func testATieGoesToTheItemChangedLast() throws {
        let entries = [try login("Banka bir", age: 9), try login("Banka iki", age: 1),
                       try login("Banka üç", age: 4)]
        XCTAssertEqual(SearchIndex(entries).search("banka").map(\.item.name),
                       ["Banka iki", "Banka üç", "Banka bir"])
        let undated = Entry(try Item(json: .object(["id": .string("u"), "type": .int(1),
                                                    "name": .string("Banka sıfır")])))
        XCTAssertEqual(SearchIndex([undated] + entries).search("banka").last?.item.name, "Banka sıfır")
    }

    func testEveryWordHasToBeSomewhereAndAnItemStandsWhereItsWorstWordDoes() throws {
        let entries = [
            try login("İş Bankası", user: "deniz", address: "https://www.isbank.com.tr", age: 0),
            try login("Deniz Bankası", user: "ops", age: 1),
            try login("Bankası İş", age: 2),
        ]
        let index = SearchIndex(entries)
        XCTAssertEqual(index.search("bankasi deniz").map(\.item.name), ["Deniz Bankası", "İş Bankası"])
        XCTAssertEqual(index.search("bankasi zeytin").count, 0)
        // The two words start the first title as they stand, and are only
        // words of the last.
        XCTAssertEqual(index.search("is bankasi").map(\.item.name), ["İş Bankası", "Bankası İş"])
        XCTAssertEqual(index.search("").count, 0)
        XCTAssertEqual(index.search("   ").count, 0)
    }

    func testAWordIsNotFoundAcrossTwoPartsOrTwoItems() throws {
        let index = SearchIndex([try login("abc", user: "def", address: "https://ghi.example.com", notes: "jkl"),
                                 try login("mno")])
        for query in ["abcdef", "cd", "defghi", "comjkl", "klmno", "lm"] {
            XCTAssertEqual(index.search(query).count, 0, query)
        }
        XCTAssertEqual(index.search("abc def ghi jkl").count, 1)
    }

    func testAHostIsFoundAndTheRestOfAnAddressIsNot() throws {
        let index = SearchIndex([
            try login("Panel", address: "https://admin.example.com/oturum?anahtar=gizli"),
            try login("Modem", address: "http://192.168.1.1/"),
        ])
        XCTAssertEqual(index.search("example").map(\.item.name), ["Panel"])
        XCTAssertEqual(index.search("192.168").map(\.item.name), ["Modem"])
        XCTAssertEqual(index.search("oturum").count, 0)
        XCTAssertEqual(index.search("gizli").count, 0)
    }

    // MARK: What is not in it

    func testAQueryEqualToACanaryFindsNothing() async throws {
        let store = await unlocked()
        let index = try XCTUnwrap(store.searchIndex)
        XCTAssertEqual(index.count, store.shelves.all.count)
        // Everything the details hide. A username and a note are indexed on
        // purpose, so the two canaries that stand for those are found.
        let hidden = DemoVault.canaries.filter { $0 != DemoVault.usernameDomain && $0 != DemoVault.note }
        XCTAssertGreaterThan(hidden.count, 40)
        for secret in hidden {
            XCTAssertFalse(secret.contains { $0.isWhitespace })
            XCTAssertEqual(index.search(secret).count, 0, "a hidden value was found by typing it")
            // Nor by its last eight characters, which no title or note has.
            // The demo's identity number is also e-Devlet's username, which
            // is shown and so is found.
            if secret != DemoVault.numbers[0] {
                XCTAssertEqual(index.search(String(secret.suffix(8))).count, 0, "the end of a hidden value was found")
            }
        }
        XCTAssertEqual(index.search(String(DemoVault.numbers[0].suffix(8))).map(\.item.name), ["e-Devlet"])
        XCTAssertFalse(index.search(DemoVault.usernameDomain).isEmpty)
        XCTAssertFalse(index.search(DemoVault.note).isEmpty)
    }

    func testAFieldIsFoundByItsNameAndNeverByItsValue() async throws {
        let index = try await demoIndex()
        XCTAssertEqual(index.search("musteri no").map(\.item.name), ["İş Bankası"])
        XCTAssertEqual(index.search("pin").map(\.item.name), ["İş Bankası"])
        // The value of a field that is not hidden is not in it either.
        XCTAssertEqual(index.search("48213377").count, 0)

        let own = SearchIndex([try login("Kasa", fields: [(name: "Şifre", value: "acik-deger", type: 0),
                                                         (name: "Kod", value: "kapali-deger", type: 1)])])
        XCTAssertEqual(own.search("sifre").count, 1)
        XCTAssertEqual(own.search("kod").count, 1)
        XCTAssertEqual(own.search("acik-deger").count, 0)
        XCTAssertEqual(own.search("kapali-deger").count, 0)
        XCTAssertEqual(own.search("hunter2").count, 0)
    }

    func testAnIndexSaysNothingOfWhatItHolds() async throws {
        let index = try await demoIndex()
        let printed = "\(index) \(String(describing: index)) \(String(reflecting: index))"
        var dumped = ""
        dump(index, to: &dumped)
        for words in [printed, dumped] {
            XCTAssertFalse(words.localizedCaseInsensitiveContains("bankas"), words)
            XCTAssertFalse(words.contains(DemoVault.usernameDomain), words)
        }
    }

    // MARK: The store

    func testTheIndexIsMadeOncePerRevisionAndOffTheMainThread() async throws {
        let backend = backend()
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        XCTAssertNil(store.searchIndex, "the index was made on the main thread, in front of the first row")
        await store.indexing?.value
        let first = try XCTUnwrap(store.searchIndex)
        XCTAssertEqual(store.indexings, 1)
        XCTAssertFalse(first.wasMadeOnMain)

        await store.sync()
        await store.indexing?.value
        XCTAssertEqual(store.indexings, 1, "a sync that changed nothing made an index")
        XCTAssertTrue(store.searchIndex === first)

        var vault = DemoVault.objects()
        let spotify = try XCTUnwrap(vault.items.firstIndex { $0["name"]?.string == "Spotify" })
        vault.items[spotify] = vault.items[spotify].setting(["name"], to: .string("Müzik kutusu"))
        backend.incoming = vault
        await store.sync()
        // The one before it answers until the new one is in.
        XCTAssertTrue(store.searchIndex === first)
        await store.indexing?.value
        XCTAssertEqual(store.indexings, 2)
        XCTAssertEqual(store.searchIndex?.search("muzik").map(\.item.name), ["Müzik kutusu"])
        // Its address is the one it had.
        XCTAssertEqual(store.searchIndex?.search("spotify").map(\.item.name), ["Müzik kutusu"])
    }

    func testArchivedAndDeletedItemsAreNotFound() async throws {
        let store = await unlocked()
        XCTAssertFalse(store.shelves.archive.isEmpty)
        XCTAssertFalse(store.shelves.trash.isEmpty)
        let index = try XCTUnwrap(store.searchIndex)
        for gone in store.shelves.archive + store.shelves.trash {
            XCTAssertFalse(index.search(gone.item.name).contains { $0 === gone }, gone.item.name)
        }
    }

    func testTheIndexIsDroppedOnLock() async throws {
        let store = await unlocked()
        weak var index = store.searchIndex
        XCTAssertNotNil(index)
        XCTAssertEqual(index?.search("github").first?.item.name, "GitHub")
        await store.lock()
        XCTAssertNil(index, "the index outlived the lock")
        XCTAssertNil(store.searchIndex)
        XCTAssertNil(store.indexing)
    }

    func testALockWhileTheIndexIsBeingMadeLeavesNone() async throws {
        let store = VaultStore(backend: backend((ScrollTrace.items(), [])))
        await store.unlock(password: SecretBytes(DemoVault.password))
        let making = try XCTUnwrap(store.indexing)
        await store.lock()
        await making.value
        XCTAssertNil(store.searchIndex)
        XCTAssertEqual(store.indexings, 0)
    }

    func testTheDoorDropsTheIndexAndWhatTheSearchFound() async throws {
        let store = VaultStore(backend: backend())
        let door = Door(store: store, defaults: defaults)
        await door.unlock(with: SecretBytes(DemoVault.password)).value
        await store.indexing?.value
        weak var index = store.searchIndex
        weak var found: Entry?
        do {
            let panes = try XCTUnwrap(door.panes)
            panes.query = "github"
            found = panes.list.entries.first
            panes.submitSearch()
            XCTAssertEqual(panes.selectedItem?.item.name, "GitHub")
        }
        XCTAssertNotNil(index)
        XCTAssertNotNil(found)
        await store.lock()
        try await turn()
        XCTAssertNil(door.panes)
        XCTAssertNil(index, "the index outlived the lock")
        XCTAssertNil(found, "an item the search found outlived the lock")
    }

    // MARK: The window

    func testWhatIsTypedTakesTheListsPlaceUnderAHeadingThatCounts() async throws {
        let panes = Panes(store: await unlocked())
        let whole = panes.list.entries.count
        XCTAssertFalse(panes.isSearching)

        panes.query = "git"
        XCTAssertTrue(panes.isSearching)
        XCTAssertEqual(panes.list.entries.map(\.item.name), ["Git imza anahtarı", "GitHub", "Digital Ocean"])
        XCTAssertEqual(panes.list.sections.map(\.heading), ["3 RESULTS"])
        panes.query = "cicek"
        XCTAssertEqual(panes.list.sections.map(\.heading), ["1 RESULT"])
        panes.query = "zeytinyağı"
        XCTAssertTrue(panes.list.isEmpty)
        XCTAssertTrue(panes.list.sections.isEmpty)

        // Spaces alone are not a search.
        panes.query = "  "
        XCTAssertFalse(panes.isSearching)
        XCTAssertEqual(panes.list.entries.count, whole)
    }

    func testASearchLooksInTheWholeVaultWhateverTheSidebarAndTheCategorySay() async throws {
        let panes = Panes(store: await unlocked())
        panes.select(.favorites)
        panes.choose(.card)
        panes.query = "git"
        XCTAssertEqual(panes.list.entries.map(\.item.name), ["Git imza anahtarı", "GitHub", "Digital Ocean"])
        panes.endSearch()
        XCTAssertEqual(panes.selection, .favorites)
        XCTAssertEqual(panes.category, .card)
    }

    func testTheListIsSearchedOncePerChangeAndNotPerRead() async throws {
        let panes = Panes(store: await unlocked())
        panes.query = "deniz"
        let before = panes.arrangements
        for _ in 0..<50 { _ = panes.list }
        XCTAssertEqual(panes.arrangements, before + 1)
        panes.query = "deniz."
        _ = panes.list
        _ = panes.list
        XCTAssertEqual(panes.arrangements, before + 2)
    }

    func testEscClearsAndChoosingASidebarRowEndsTheSearch() async throws {
        let panes = Panes(store: await unlocked())
        let whole = panes.list.entries.count
        panes.query = "git"
        let keys = panes.keysToList
        XCTAssertTrue(panes.dismiss())
        XCTAssertEqual(panes.query, "")
        XCTAssertEqual(panes.list.entries.count, whole)
        XCTAssertEqual(panes.keysToList, keys + 1, "the list has the keys again")
        XCTAssertFalse(panes.dismiss(), "there was nothing left to clear")

        panes.query = "git"
        panes.select(.favorites)
        XCTAssertEqual(panes.query, "")
        XCTAssertFalse(panes.isSearching)

        // The list's own filter is under the search, and Esc ends the one
        // that can be seen first.
        panes.beginFilter()
        panes.filter = "a"
        panes.query = "git"
        XCTAssertTrue(panes.dismiss())
        XCTAssertTrue(panes.isFiltering)
        XCTAssertEqual(panes.query, "")
        XCTAssertTrue(panes.dismiss())
        XCTAssertFalse(panes.isFiltering)
    }

    func testReturnChoosesTheFirstResultAndTheArrowsMoveAmongThem() async throws {
        let panes = Panes(store: await unlocked())
        panes.query = "git"
        XCTAssertNil(panes.selectedItem)
        let keys = panes.keysToList
        panes.submitSearch()
        XCTAssertEqual(panes.selectedItem?.item.name, "Git imza anahtarı")
        XCTAssertEqual(panes.keysToList, keys + 1)
        panes.moveSelection(by: 1)
        XCTAssertEqual(panes.selectedItem?.item.name, "GitHub")
        // Return again leaves what he chose.
        panes.submitSearch()
        XCTAssertEqual(panes.selectedItem?.item.name, "GitHub")
        // An item that is not among what was found is not selected, and is
        // again when the list has it back.
        panes.query = "digital"
        XCTAssertNil(panes.selectedItem)
        panes.endSearch()
        XCTAssertEqual(panes.selectedItem?.item.name, "GitHub")
    }

    func testASyncBehindASearchKeepsItAndBringsWhatChanged() async throws {
        let backend = backend()
        let store = await unlocked(backend)
        let panes = Panes(store: store)
        panes.query = "muzik"
        XCTAssertTrue(panes.list.isEmpty)

        var vault = DemoVault.objects()
        let spotify = try XCTUnwrap(vault.items.firstIndex { $0["name"]?.string == "Spotify" })
        vault.items[spotify] = vault.items[spotify].setting(["name"], to: .string("Müzik kutusu"))
        backend.incoming = vault
        await store.sync()
        await store.indexing?.value
        XCTAssertEqual(panes.list.entries.map(\.item.name), ["Müzik kutusu"])
        XCTAssertEqual(panes.query, "muzik")
    }

    func testCommandFIsInTheViewMenuAndAsksForTheCaret() async throws {
        let store = VaultStore(backend: backend())
        let door = Door(store: store, defaults: defaults)
        let commands = WindowCommands(door: door)
        let search = commands.searchItem()
        let filter = commands.filterItem()
        XCTAssertEqual(search.keyEquivalent, "f")
        XCTAssertEqual(search.keyEquivalentModifierMask, .command)
        XCTAssertFalse(commands.validateMenuItem(search), "there is nothing to search behind the lock screen")

        await store.unlock(password: SecretBytes(DemoVault.password))
        let panes = try XCTUnwrap(door.panes)
        XCTAssertTrue(commands.validateMenuItem(search))
        let asked = panes.keysToSearch
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(search.action), to: search.target, from: search))
        XCTAssertEqual(panes.keysToSearch, asked + 1)

        // While the search has the list there is no list to find in.
        XCTAssertTrue(commands.validateMenuItem(filter))
        panes.query = "git"
        XCTAssertFalse(commands.validateMenuItem(filter))
        panes.beginFilter()
        XCTAssertFalse(panes.isFiltering)
    }

    func testTheWindowSaysWhatWasFoundAndHowMany() async throws {
        let panes = Panes(store: await unlocked())
        let window = hosted(panes)
        try await turn()
        var words = said(in: window.contentView)
        XCTAssertTrue(words.contains("Search"), "\(words)")
        XCTAssertFalse(words.contains("Clear Search"), "there is nothing to clear yet")
        XCTAssertTrue(words.contains("All Categories"))

        panes.query = "git"
        try await turn()
        words = said(in: window.contentView)
        for word in ["3 RESULTS", "Search Results", "GitHub", "Digital Ocean", "Clear Search", "git"] {
            XCTAssertTrue(words.contains(word), "\(word) is not in \(words)")
        }
        for word in ["Apple Account", "All Categories", "Sort", "Find in List"] {
            XCTAssertFalse(words.contains(word), "\(word) is still drawn")
        }

        panes.query = "zeytinyağı"
        try await turn()
        words = said(in: window.contentView)
        XCTAssertTrue(words.contains("No results"), "\(words)")

        panes.endSearch()
        try await turn()
        words = said(in: window.contentView)
        XCTAssertTrue(words.contains("Apple Account"), "\(words)")
        XCTAssertFalse(words.contains("3 RESULTS"))
    }

    func testASearchTypedBeforeTheIndexIsInSaysItIsStillLooking() async throws {
        let store = VaultStore(backend: backend((ScrollTrace.items(), [])))
        await store.unlock(password: SecretBytes(DemoVault.password))
        let panes = Panes(store: store)
        panes.query = "ilgaz"
        XCTAssertNil(store.searchIndex)
        XCTAssertTrue(panes.list.isEmpty)
        let window = hosted(panes)
        XCTAssertTrue(said(in: window.contentView).contains("Searching…"))
        await store.indexing?.value
        try await turn()
        XCTAssertGreaterThan(panes.list.entries.count, 50)
        XCTAssertFalse(said(in: window.contentView).contains("Searching…"))
    }
}
