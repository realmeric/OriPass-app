import XCTest
@testable import OriPass

/// What a read of the lists may do to what the store holds (OP-84): items
/// leave only when two reads agree, and a change of this app's is never
/// undone by a list read before it (`docs/notes.md`, "When a list comes back
/// short").
@MainActor
final class SyncTests: XCTestCase {
    private var kept: [StandIn] = []

    private func demo(secondRead: TimeInterval = 0.01) -> (FakeBackend, VaultStore) {
        let backend = DemoVault.backend()
        backend.lastSync = Date().addingTimeInterval(-60)
        return (backend, VaultStore(backend: backend, secondRead: secondRead))
    }

    private func open(_ store: VaultStore) async {
        await store.unlock(password: SecretBytes(DemoVault.password))
    }

    private func ids(_ entries: [Entry]) -> Set<String> { Set(entries.map(\.id)) }

    /// The vault as the server has it, without one item.
    private func without(_ id: String) -> (items: [JSONValue], folders: [JSONValue]) {
        var vault = DemoVault.objects()
        vault.items.removeAll { $0["id"]?.string == id }
        return vault
    }

    // MARK: What he sees

    /// The engine answers a list with no rows behind a sync that moved
    /// something, and the next read has them all. The whole list left the
    /// window and Sync Now brought it back.
    func testAnEngineThatAnswersEmptyBehindASyncTakesNothingFromTheList() async throws {
        let standIn = try StandIn(["password": "demo", "emptyAfterSync": 2])
        kept.append(standIn)
        let backend = ServeBackend(preferredPath: standIn.binary.path, runDirectory: standIn.run,
                                   dataDirectory: standIn.data)
        let store = VaultStore(backend: backend, secondRead: 0.01)
        await open(store)
        await store.backgroundSync?.value
        await store.sync()
        XCTAssertEqual(store.state, .unlocked)
        let listed = try Fixture.json("list-items")["data"]?["data"]?.array?.count ?? 0
        XCTAssertGreaterThan(listed, 0)
        XCTAssertEqual(store.shelves.all.count + store.shelves.archive.count, listed)
        await store.lock()
    }

    // MARK: Two reads

    func testAShortReadKeepsTheItemsAndPublishesNothing() async throws {
        let (backend, store) = demo()
        await open(store)
        let before = store.shelves.all
        let revision = store.revision
        let items = backend.count(of: "items")

        backend.readShort([[before[0].id, before[1].id]])
        await store.sync()

        XCTAssertTrue(store.shelves.all.elementsEqual(before, by: ===))
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(backend.count(of: "items"), items + 2, "it was read again")
    }

    func testTwoReadsThatAgreeTakeTheItemOff() async throws {
        let (backend, store) = demo()
        await open(store)
        let before = store.shelves.all
        let target = before[0].id

        backend.readShort([[target], [target]])
        await store.sync()

        XCTAssertNil(store.entry(id: target))
        XCTAssertEqual(store.shelves.all.count, before.count - 1)
        XCTAssertTrue(store.shelves.all.allSatisfy { kept in before.contains { $0 === kept } },
                      "the others are the objects they were")
    }

    func testTwoReadsThatDisagreeTakeNothingOff() async throws {
        let (backend, store) = demo()
        await open(store)
        let before = store.shelves.all

        backend.readShort([[before[0].id], [before[1].id]])
        await store.sync()

        XCTAssertTrue(store.shelves.all.elementsEqual(before, by: ===))
    }

    func testAnEmptyReadOverAVaultWithItemsIsHeldOff() async throws {
        let (backend, store) = demo()
        await open(store)
        let before = store.shelves.all
        let trash = store.shelves.trash
        let revision = store.revision

        backend.readShort([ids(before + trash)])
        await store.sync()

        XCTAssertTrue(store.shelves.all.elementsEqual(before, by: ===))
        XCTAssertTrue(store.shelves.trash.elementsEqual(trash, by: ===))
        XCTAssertEqual(store.revision, revision)
    }

    /// An unlock has nothing held to doubt a list against, and an empty one
    /// is the one kind of read it can doubt.
    func testAnEmptyReadAtTheUnlockIsReadAgain() async throws {
        let (backend, store) = demo()
        let all = Set(DemoVault.objects().items.compactMap { $0["id"]?.string })
        backend.readShort([all])
        await open(store)
        XCTAssertEqual(store.state, .unlocked)
        XCTAssertFalse(store.shelves.all.isEmpty)
    }

    func testADeleteElsewhereStillLandsAMomentLater() async throws {
        let (backend, store) = demo()
        await open(store)
        let target = store.shelves.all[0].id
        let items = backend.count(of: "items")

        backend.incoming = without(target)
        await store.sync()

        XCTAssertNil(store.entry(id: target))
        XCTAssertEqual(backend.count(of: "items"), items + 2)
    }

    func testAMoveToTheTrashLandsAtOnce() async throws {
        let (backend, store) = demo()
        await open(store)
        let target = store.shelves.all[0].id
        let items = backend.count(of: "items")

        var vault = DemoVault.objects()
        let place = try XCTUnwrap(vault.items.firstIndex { $0["id"]?.string == target })
        vault.items[place] = vault.items[place].setting(["deletedDate"], to: .string(VaultDate.string(Date())))
        backend.incoming = vault
        await store.sync()

        XCTAssertEqual(backend.count(of: "items"), items + 1, "a read that explains itself is believed")
        XCTAssertTrue(store.shelves.trash.contains { $0.id == target })
        XCTAssertFalse(store.shelves.all.contains { $0.id == target })

        let other = store.shelves.all[0].id
        try await store.apply(.delete, to: other)
        XCTAssertTrue(store.shelves.trash.contains { $0.id == other })
    }

    func testALockWhileAReadIsDoubtedFillsNothing() async throws {
        let (backend, store) = demo(secondRead: 0.2)
        await open(store)
        backend.readShort([[store.shelves.all[0].id]])
        let syncing = Task { await store.sync() }
        try await Task.sleep(nanoseconds: 50_000_000)
        await store.lock()
        await syncing.value
        XCTAssertEqual(store.state, .locked)
        XCTAssertTrue(store.shelves.all.isEmpty)
    }

    func testTheSelectionAndTheScrollSurviveAShortRead() async throws {
        let (backend, store) = demo()
        let panes = Panes(store: store)
        await open(store)
        let list = panes.list
        let chosen = list.entries[3]
        panes.select(item: chosen.id)
        let arrangements = panes.arrangements

        backend.readShort([ids(store.shelves.all)])
        await store.sync()
        await Task.yield()

        XCTAssertTrue(panes.selectedItem === chosen)
        XCTAssertTrue(panes.list.entries.elementsEqual(list.entries, by: ===))
        XCTAssertEqual(panes.arrangements, arrangements, "the list was not made again, so nothing moved")

        let other = try XCTUnwrap(list.entries.first { $0 !== chosen })
        backend.incoming = without(other.id)
        await store.sync()
        XCTAssertTrue(panes.selectedItem === chosen)
        XCTAssertFalse(panes.list.entries.contains { $0 === other })
    }

    // MARK: A change landing among the reads

    /// A list read before a change was made has not heard of it. Put in
    /// the store's place it takes back what was just done: a new item
    /// leaves, a restored one goes back to the trash, an edit is undone.
    func testANewItemMadeWhileTheListsAreReadStays() async throws {
        let (backend, store) = demo()
        await open(store)
        let template = try await store.blank(.secureNote)
        var edited = template
        edited.name = "Made while the lists were read"
        var made: Item?
        backend.onItemsRead = {
            backend.onItemsRead = nil
            made = try? await store.create(edited, from: template)
        }
        await store.sync()
        let id = try XCTUnwrap(made?.id)
        XCTAssertNotNil(store.entry(id: id))
        XCTAssertTrue(store.shelves.all.contains { $0.id == id })
    }

    func testAnItemRestoredWhileTheListsAreReadStaysOutOfTheTrash() async throws {
        let (backend, store) = demo()
        await open(store)
        let target = try XCTUnwrap(store.shelves.trash.first).id
        backend.onItemsRead = {
            backend.onItemsRead = nil
            _ = try? await store.apply(.restore, to: target)
        }
        await store.sync()
        XCTAssertTrue(store.shelves.all.contains { $0.id == target })
        XCTAssertFalse(store.shelves.trash.contains { $0.id == target })
    }

    func testAnEditMadeWhileTheListsAreReadIsNotUndone() async throws {
        let (backend, store) = demo()
        await open(store)
        let target = try XCTUnwrap(store.shelves.all.first { !$0.item.favorite }).id
        backend.onItemsRead = {
            backend.onItemsRead = nil
            _ = try? await store.apply(.favourite(true), to: target)
        }
        await store.sync()
        XCTAssertEqual(store.entry(id: target)?.item.favorite, true)
    }

    // MARK: The view's side

    /// The panes' list is what the store holds, after every kind of change.
    func testTheListIsWhatTheStoreHoldsAfterEveryKindOfChange() async throws {
        let (backend, store) = demo()
        let panes = Panes(store: store)
        await open(store)
        func agrees(_ change: String, line: UInt = #line) {
            XCTAssertEqual(ids(panes.list.entries), ids(panes.listed), change, line: line)
            let rows: Set<String>
            switch panes.selection {
            case .trash: rows = ids(store.shelves.trash)
            case .archive: rows = ids(store.shelves.archive)
            default: rows = ids(store.shelves.all)
            }
            XCTAssertEqual(ids(panes.list.entries), rows, change, line: line)
        }
        agrees("the unlock")

        let first = store.shelves.all[0].id
        let second = store.shelves.all[1].id
        try await store.apply(.favourite(true), to: first)
        agrees("a favourite")
        try await store.apply(.duplicate, to: first)
        agrees("a duplicate")
        try await store.apply(.archive, to: first)
        agrees("an archive")
        panes.select(.archive)
        agrees("the archive's row")
        try await store.apply(.unarchive, to: first)
        agrees("out of the archive")
        panes.select(.allItems)
        try await store.apply(.delete, to: first)
        agrees("to the trash")
        panes.select(.trash)
        agrees("the trash's row")
        try await store.apply(.restore, to: first)
        agrees("out of the trash")
        panes.select(.allItems)
        try await store.apply(.deleteForGood, to: second)
        agrees("gone for good")

        let vault = try await store.makeVault(named: "OP-84")
        try await store.apply(.move(try XCTUnwrap(vault?.id)), to: first)
        agrees("moved to a vault")
        panes.select(.vault(try XCTUnwrap(vault?.id)))
        XCTAssertEqual(ids(panes.list.entries), [first])
        try await store.deleteVault(try XCTUnwrap(vault?.id))
        XCTAssertEqual(panes.selection, .allItems)
        agrees("its vault deleted")

        let blank = try await store.blank(.secureNote)
        var edited = blank
        edited.name = "New"
        let made = try await store.create(edited, from: blank)
        agrees("a new item")
        XCTAssertTrue(panes.list.place(of: try XCTUnwrap(made?.id)) != nil)

        backend.incoming = without(first)
        await store.sync()
        agrees("a sync that took one away")
        XCTAssertNil(panes.list.place(of: first))

        panes.choose(.login)
        let logins = ids(store.shelves.all.filter { $0.item.type == .login })
        XCTAssertEqual(ids(panes.list.entries), logins)
        panes.choose(.all)
        panes.beginFilter()
        panes.filter = "zzzz-matches-nothing"
        XCTAssertTrue(panes.list.isEmpty)
        panes.endFilter()
        agrees("the filter put away")

        await store.counting?.value
        panes.show(.weak)
        let listed = ids(store.watch?.entries(of: .weak) ?? [])
        XCTAssertEqual(ids(panes.list.entries), listed)
        panes.select(.allItems)
        agrees("back from a card")

        panes.query = store.shelves.all[0].item.name
        await store.indexing?.value
        XCTAssertFalse(panes.list.isEmpty, "a search over what the store holds found it")
        panes.query = ""
        agrees("the search put away")
    }

    // MARK: The log

    /// A line for each read is what the next time is read from, and it
    /// holds counts.
    func testEveryReadHasALineOfCountsOnly() {
        XCTAssertEqual(VaultStore.readLine("sync", items: 412, trash: 3, folders: 12, heldItems: 412, heldTrash: 3,
                                           missing: 0),
                       "sync read 412 items, 3 in the trash, 12 folders, over 412 and 3 held, 0 missing")
    }
}
