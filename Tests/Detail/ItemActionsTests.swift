import AppKit
import SwiftUI
import XCTest
@testable import OriPass

@MainActor
final class ItemActionsTests: XCTestCase {
    private var backend: FakeBackend!
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        suite = "oripass-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        backend = nil
    }

    private func demo() async -> VaultStore {
        let vault = DemoVault.objects()
        backend = FakeBackend(items: vault.items, folders: vault.folders, password: DemoVault.password)
        // Synced a minute ago, so no sync is running behind the panes.
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        return store
    }

    /// The demo as an account without Premium has it: nothing archived,
    /// and an engine that will not archive.
    private func free() async -> VaultStore {
        var vault = DemoVault.objects()
        vault.items.removeAll { $0["archivedDate"]?.string != nil }
        backend = FakeBackend(items: vault.items, folders: vault.folders, password: DemoVault.password)
        backend.lastSync = Date().addingTimeInterval(-60)
        backend.isFree = true
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        return store
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

    private func id(of title: String, in store: VaultStore) throws -> String {
        let shelves = store.shelves
        return try XCTUnwrap((shelves.all + shelves.archive + shelves.trash).first { $0.item.name == title },
                             "no \(title)").id
    }

    @discardableResult
    private func choose(_ title: String, in panes: Panes) throws -> Item {
        let entry = try XCTUnwrap(panes.list.entries.first { $0.item.name == title }, "no \(title)")
        panes.select(item: entry.id)
        return try XCTUnwrap(panes.selectedItem?.item)
    }

    /// What the engine was asked while `change` was made.
    private func calls(for change: ItemChange, to id: String, in store: VaultStore) async throws -> [String] {
        let before = backend.calls.count
        try await store.apply(change, to: id)
        return Array(backend.calls[before...])
    }

    private func ids(_ entries: [Entry]) -> Set<String> { Set(entries.map(\.id)) }

    // MARK: An account that may not archive

    /// What 2026.9.1 said to a free account on 2026-10-11. The sidebar has
    /// no Archive, and the three ways left of asking for one each show the
    /// engine's sentence and move nothing.
    func testAFreeAccountIsToldTheArchiveIsPremiums() async throws {
        let store = await free()
        let panes = Panes(store: store)
        let window = hosted(panes)
        let spotify = try id(of: "Spotify", in: store)
        panes.select(item: spotify)
        XCTAssertFalse(store.mayArchive)
        XCTAssertEqual(panes.lowerRows, [.trash])

        func refusedOnce(_ how: String, line: UInt = #line) async throws {
            await panes.writing?.value
            XCTAssertEqual(panes.refused, FakeBackend.needsPremium, how, line: line)
            XCTAssertEqual(backend.calls.last, "archive", how, line: line)
            XCTAssertEqual(panes.selectedItem?.id, spotify, how, line: line)
            XCTAssertEqual(store.entry(id: spotify)?.item.isArchived, false, how, line: line)
            XCTAssertFalse(store.entry(id: spotify)?.item.isInTrash ?? true, how, line: line)
            try await turn()
            XCTAssertTrue(said(in: window.contentView).contains(FakeBackend.needsPremium), how, line: line)
            XCTAssertTrue(panes.dismiss(), how, line: line)
            XCTAssertNil(panes.refused, how, line: line)
        }

        XCTAssertTrue(panes.itemActs.joined().contains(.archive))
        panes.perform(.archive)
        try await refusedOnce("the menu")

        // Delete: the item is not moved to Recently Deleted in its place.
        panes.focus = .list
        XCTAssertTrue(panes.press(.delete))
        try await refusedOnce("the Delete key")
        XCTAssertTrue(store.shelves.trash.allSatisfy { $0.id != spotify })

        // The row is not drawn, so there is nothing to drop on; a drop that
        // reached it all the same would be answered the same way.
        _ = panes.beginDrag(spotify)
        XCTAssertTrue(panes.drop(on: .archive))
        try await refusedOnce("a drop")
        XCTAssertFalse(store.mayArchive)
    }

    // MARK: One call, and the right list

    func testEachActionIsOneCallAndTheItemIsThenWhereItBelongs() async throws {
        let store = await demo()
        let spotify = try id(of: "Spotify", in: store)
        let count = store.shelves.all.count
        XCTAssertFalse(ids(store.shelves.favourites).contains(spotify))

        var asked = try await calls(for: .favourite(true), to: spotify, in: store)
        XCTAssertEqual(asked, ["save"])
        XCTAssertTrue(ids(store.shelves.favourites).contains(spotify))
        asked = try await calls(for: .favourite(false), to: spotify, in: store)
        XCTAssertEqual(asked, ["save"])
        XCTAssertFalse(ids(store.shelves.favourites).contains(spotify))

        let folder = try XCTUnwrap(store.shelves.vaults.first { $0.id != .personal && $0.takesItems })
        XCTAssertTrue(ids(store.entries(in: .personal)).contains(spotify))
        asked = try await calls(for: .move(folder.id), to: spotify, in: store)
        XCTAssertEqual(asked, ["save"])
        XCTAssertTrue(ids(store.entries(in: folder.id)).contains(spotify))
        XCTAssertFalse(ids(store.entries(in: .personal)).contains(spotify))
        XCTAssertEqual(store.entry(id: spotify).map { store.vault(of: $0.item) }, folder)
        asked = try await calls(for: .move(.personal), to: spotify, in: store)
        XCTAssertEqual(asked, ["save"])
        XCTAssertTrue(ids(store.entries(in: .personal)).contains(spotify))

        let before = backend.calls.count
        let made = try await store.apply(.duplicate, to: spotify)
        let copy = try XCTUnwrap(made)
        XCTAssertEqual(Array(backend.calls[before...]), ["create"])
        XCTAssertEqual(copy.name, "Spotify copy")
        XCTAssertNotEqual(copy.id, spotify)
        XCTAssertEqual(store.shelves.all.count, count + 1)
        XCTAssertTrue(ids(store.shelves.all).isSuperset(of: [spotify, copy.id]))
        XCTAssertEqual(copy.login?.password, store.entry(id: spotify)?.item.login?.password)

        asked = try await calls(for: .archive, to: spotify, in: store)
        XCTAssertEqual(asked, ["archive"])
        XCTAssertTrue(ids(store.shelves.archive).contains(spotify))
        XCTAssertFalse(ids(store.shelves.all).contains(spotify))
        XCTAssertFalse(ids(store.entries(in: .personal)).contains(spotify))
        asked = try await calls(for: .unarchive, to: spotify, in: store)
        XCTAssertEqual(asked, ["unarchive"])
        XCTAssertFalse(ids(store.shelves.archive).contains(spotify))
        XCTAssertTrue(ids(store.shelves.all).contains(spotify))

        asked = try await calls(for: .delete, to: spotify, in: store)
        XCTAssertEqual(asked, ["delete"])
        XCTAssertTrue(ids(store.shelves.trash).contains(spotify))
        XCTAssertFalse(ids(store.shelves.all).contains(spotify))
        asked = try await calls(for: .restore, to: spotify, in: store)
        XCTAssertEqual(asked, ["restore"])
        XCTAssertFalse(ids(store.shelves.trash).contains(spotify))
        XCTAssertTrue(ids(store.shelves.all).contains(spotify))

        asked = try await calls(for: .delete, to: copy.id, in: store)
        XCTAssertEqual(asked, ["delete"])
        asked = try await calls(for: .deleteForGood, to: copy.id, in: store)
        XCTAssertEqual(asked, ["deletePermanently"])
        XCTAssertNil(store.entry(id: copy.id))
        XCTAssertEqual(store.shelves.all.count, count)

        // What the store worked out for itself is what the engine holds.
        let held = (all: ids(store.shelves.all), archive: ids(store.shelves.archive), trash: ids(store.shelves.trash))
        await store.sync()
        XCTAssertEqual(ids(store.shelves.all), held.all)
        XCTAssertEqual(ids(store.shelves.archive), held.archive)
        XCTAssertEqual(ids(store.shelves.trash), held.trash)
    }

    func testAChangeKeepsTheLevelOfAPasswordItDidNotTouch() async throws {
        let store = await demo()
        await store.scoring?.value
        let spotify = try id(of: "Spotify", in: store)
        let level = try XCTUnwrap(store.entry(id: spotify)?.strength)
        try await store.apply(.favourite(true), to: spotify)
        XCTAssertEqual(store.entry(id: spotify)?.strength, level, "with no wait for the scoring behind it")
    }

    func testAnArchivedItemIsCopiedIntoTheOpen() async throws {
        let store = await demo()
        let archived = try XCTUnwrap(store.shelves.archive.first)
        let made = try await store.apply(.duplicate, to: archived.id)
        let copy = try XCTUnwrap(made)
        XCTAssertFalse(copy.isArchived)
        XCTAssertTrue(ids(store.shelves.all).contains(copy.id))
        XCTAssertTrue(ids(store.shelves.archive).contains(archived.id))
    }

    // MARK: The passkey

    func testADuplicatedLoginHasNoPasskeyAndTheOriginalKeepsItsOwn() async throws {
        let store = await demo()
        let github = try id(of: "GitHub", in: store)
        let original = try XCTUnwrap(store.entry(id: github)?.item)
        XCTAssertEqual(original.raw["login"]?["fido2Credentials"]?.array?.count, 1)

        let object = try XCTUnwrap(original.copied())
        XCTAssertNil(object["id"])
        XCTAssertEqual(object["login"]?["fido2Credentials"]?.array?.count, 0)
        XCTAssertEqual(object["login"]?["password"], original.raw["login"]?["password"])
        XCTAssertEqual(object["notes"], original.raw["notes"])

        let made = try await store.apply(.duplicate, to: github)
        let copy = try XCTUnwrap(made)
        XCTAssertEqual(copy.name, "GitHub copy")
        XCTAssertEqual(copy.login?.passkeysCreated.count, 0)
        XCTAssertEqual(copy.raw["login"]?["fido2Credentials"]?.array?.count, 0)
        XCTAssertEqual(store.entry(id: github)?.item.raw, original.raw, "nothing of the original was sent")

        // And in the engine, which is where the next sync reads them from.
        await store.sync()
        let kept = try XCTUnwrap(store.entry(id: github)?.item.raw["login"]?["fido2Credentials"]?.array)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?["keyValue"]?.string, DemoVault.passkey)
        XCTAssertEqual(store.entry(id: copy.id)?.item.raw["login"]?["fido2Credentials"]?.array?.count, 0)
    }

    func testATypeThisAppDoesNotKnowIsPutAwayAndNeverSent() async throws {
        let store = await demo()
        let unknown = try XCTUnwrap(store.shelves.all.first { !$0.item.canBeWritten })
        for change in [ItemChange.favourite(true), .move(.personal), .duplicate] {
            let before = backend.calls.count
            do {
                try await store.apply(change, to: unknown.id)
                XCTFail("\(change) was made to a type nobody here can write")
            } catch {
                XCTAssertEqual(error as? VaultError, .refused(VaultStore.cannotWrite))
            }
            XCTAssertEqual(backend.calls.count, before)
        }
        let asked = try await calls(for: .delete, to: unknown.id, in: store)
        XCTAssertEqual(asked, ["delete"])
        XCTAssertTrue(ids(store.shelves.trash).contains(unknown.id))

        let panes = Panes(store: store)
        panes.select(.trash)
        panes.select(item: unknown.id)
        XCTAssertEqual(panes.itemActs, [[.restore, .deleteForGood]])
    }

    // MARK: Refused

    func testARefusedWriteLeavesTheItemWhereItWasAndSaysWhy() async throws {
        let store = await demo()
        let panes = Panes(store: store)
        let window = hosted(panes)
        let spotify = try choose("Spotify", in: panes)
        let revision = store.revision

        backend.isOffline = true
        for act in [ItemAct.favourite, .duplicate, .archive, .delete] {
            panes.perform(act)
            await panes.writing?.value
            XCTAssertEqual(panes.refused, FakeBackend.offline, "\(act)")
            XCTAssertEqual(panes.selectedItem?.id, spotify.id)
            XCTAssertEqual(store.entry(id: spotify.id)?.item, spotify)
            XCTAssertEqual(store.revision, revision, "nothing was drawn again")
        }
        XCTAssertFalse(ids(store.shelves.trash).contains(spotify.id))
        try await turn()
        XCTAssertTrue(said(in: window.contentView).contains(FakeBackend.offline))

        // The CLI's own sentence, whatever it is.
        backend.isOffline = false
        backend.refusal = .refused("Premium status is required to use this feature.")
        panes.perform(.archive)
        await panes.writing?.value
        XCTAssertEqual(panes.refused, "Premium status is required to use this feature.")
        XCTAssertFalse(ids(store.shelves.archive).contains(spotify.id))

        // Esc takes the sentence away, and so does the next change.
        XCTAssertTrue(panes.dismiss())
        XCTAssertNil(panes.refused)
        panes.perform(.archive)
        await panes.writing?.value
        XCTAssertNotNil(panes.refused)
        backend.refusal = nil
        panes.perform(.favourite)
        XCTAssertNil(panes.refused)
        await panes.writing?.value
        XCTAssertNil(panes.refused)
        XCTAssertTrue(ids(store.shelves.favourites).contains(spotify.id))
        try await turn()
        XCTAssertFalse(said(in: window.contentView).contains(FakeBackend.offline))
    }

    func testALockUnderAChangeLeavesNothingBehind() async throws {
        let store = await demo()
        let door = Door(store: store, defaults: defaults)
        let panes = try XCTUnwrap(door.panes)
        try choose("Spotify", in: panes)
        backend.delay = 0.2
        panes.perform(.delete)
        let writing = try XCTUnwrap(panes.writing)
        await store.lock()
        await writing.value
        XCTAssertNil(door.panes)
        XCTAssertNil(panes.refused, "the lock screen is already saying it")
        XCTAssertEqual(store.state, .locked)
        XCTAssertTrue(store.shelves.all.isEmpty)
        XCTAssertTrue(store.shelves.trash.isEmpty)
    }

    /// The engine takes five seconds over each change, and the lock does
    /// not wait for either: a change that is stopped comes back at once.
    func testALockStopsEveryChangeInFlightAndNotOnlyTheLast() async throws {
        let store = await demo()
        let door = Door(store: store, defaults: defaults)
        let panes = try XCTUnwrap(door.panes)
        backend.delay = 5
        let first = panes.write(.favourite(true), to: try id(of: "Spotify", in: store))
        let second = panes.write(.favourite(true), to: try id(of: "GitHub", in: store))
        XCTAssertEqual(panes.writes.count, 2)
        try await turn()
        XCTAssertEqual(backend.count(of: "save"), 2, "both are with the engine")

        let locked = Date()
        backend.delay = 0
        await store.lock()
        XCTAssertNil(door.panes)
        XCTAssertTrue(panes.writes.isEmpty)
        await second.value
        await first.value
        XCTAssertLessThan(Date().timeIntervalSince(locked), 2, "the first of two was left waiting on the engine")
        XCTAssertNil(panes.refused)
    }

    func testAChangeThatIsAnsweredIsNoLongerHeld() async throws {
        let store = await demo()
        let panes = Panes(store: store)
        let first = panes.write(.favourite(true), to: try id(of: "Spotify", in: store))
        let second = panes.write(.archive, to: try id(of: "GitHub", in: store))
        XCTAssertEqual(panes.writes.count, 2)
        await first.value
        await second.value
        XCTAssertTrue(panes.writes.isEmpty)
        XCTAssertEqual(backend.count(of: "save"), 1)
        XCTAssertEqual(backend.count(of: "archive"), 1)
    }

    /// The engine answers a change after the vault has been locked and
    /// opened again. The fake made the change, as `bw` might have; the store
    /// puts nothing among what it read since from an item it read before.
    func testAChangeAnsweredAfterTheVaultWasReopenedTouchesNothing() async throws {
        let store = await demo()
        let spotify = try id(of: "Spotify", in: store)
        let opening = store.opening
        backend.delay = 0.3
        let stale = Task { try await store.apply(.favourite(true), to: spotify) }
        try await turn()
        XCTAssertEqual(backend.count(of: "save"), 1, "the change is with the engine")

        backend.delay = 0
        await store.lock()
        await store.unlock(password: SecretBytes(DemoVault.password))
        XCTAssertEqual(store.state, .unlocked)
        XCTAssertEqual(store.opening, opening + 1)
        let revision = store.revision
        let held = try XCTUnwrap(store.entry(id: spotify))

        let answer = try await stale.value
        XCTAssertNil(answer)
        XCTAssertEqual(store.revision, revision)
        XCTAssertTrue(store.entry(id: spotify) === held, "the entry read at this opening was replaced")
        XCTAssertFalse(store.shelves.favourites.contains { $0.id == spotify })
    }

    // MARK: The menu

    func testTheMenuIsTheItemsOwn() async throws {
        let store = await demo()
        let panes = Panes(store: store)
        XCTAssertEqual(panes.itemActs, [], "no item, no menu")
        panes.toggle(.item)
        XCTAssertNil(panes.detailMenu)

        try choose("Spotify", in: panes)
        XCTAssertEqual(panes.itemActs, [[.openWindow], [.favourite, .move, .duplicate, .attach], [.archive, .delete]])
        try choose("GitHub", in: panes)
        XCTAssertEqual(panes.itemActs[1], [.unfavourite, .move, .duplicate, .attach])

        let unknown = try XCTUnwrap(panes.list.entries.first { !$0.item.canBeWritten })
        panes.select(item: unknown.id)
        XCTAssertEqual(panes.itemActs, [[.openWindow], [.archive, .delete]])
        XCTAssertFalse(panes.canMove)
        panes.toggle(.move)
        XCTAssertNil(panes.detailMenu)

        panes.select(.archive)
        panes.select(item: panes.list.entries.first?.id)
        XCTAssertEqual(panes.itemActs.last, [.unarchive, .delete])
        XCTAssertFalse(panes.archiveSelected(), "Delete does nothing to what is already there")

        panes.select(.trash)
        panes.select(item: panes.list.entries.first?.id)
        XCTAssertEqual(panes.itemActs, [[.restore, .deleteForGood]])
        XCTAssertFalse(panes.canMove)
        XCTAssertFalse(panes.openWindow())
    }

    func testTheMenuOpensUnderTheEllipsisAndOneMenuAtATime() async throws {
        let store = await demo()
        let panes = Panes(store: store)
        let window = hosted(panes)
        try choose("İş Bankası", in: panes)
        try await turn()
        XCTAssertFalse(said(in: window.contentView).contains("Duplicate"))

        panes.toggle(.item)
        try await turn()
        var words = said(in: window.contentView)
        for act in panes.itemActs.joined() {
            XCTAssertTrue(words.contains(act.name), "\(act.name) in \(words)")
        }
        XCTAssertTrue(words.contains("Remove from Favorites"))

        panes.toggle(.sort)
        XCTAssertNil(panes.detailMenu)
        panes.toggle(.item)
        XCTAssertNil(panes.openMenu)

        // Move is the vault's own menu, under its name.
        panes.perform(.move)
        XCTAssertEqual(panes.detailMenu, .move)
        try await turn()
        words = said(in: window.contentView)
        XCTAssertTrue(words.contains("MOVE TO"))
        XCTAssertFalse(words.contains("Duplicate"))
        let personal = try XCTUnwrap(panes.moveTargets.first)
        XCTAssertEqual(personal.id, .personal)
        panes.move(to: personal.id)
        XCTAssertNil(panes.detailMenu)
        await panes.writing?.value
        XCTAssertEqual(panes.detail?.vault, .personal)
        XCTAssertEqual(backend.count(of: "save"), 1)

        panes.toggle(.item)
        XCTAssertTrue(panes.dismiss())
        XCTAssertNil(panes.detailMenu)
        panes.toggle(.item)
        try choose("GitHub", in: panes)
        XCTAssertNil(panes.detailMenu, "another item, and the menu was the last one's")
    }

    func testTheSelectionFollowsTheItem() async throws {
        let store = await demo()
        let panes = Panes(store: store)
        let spotify = try choose("Spotify", in: panes)
        let place = try XCTUnwrap(panes.list.place(of: spotify.id))
        let next = panes.list.entries[place + 1].id

        // A favourite is where it was, and still chosen.
        panes.perform(.favourite)
        await panes.writing?.value
        XCTAssertEqual(panes.selectedItem?.id, spotify.id)
        XCTAssertEqual(panes.selectedItem?.item.favorite, true)

        // A copy is chosen in its place.
        panes.perform(.duplicate)
        await panes.writing?.value
        XCTAssertEqual(panes.selectedItem?.item.name, "Spotify copy")
        XCTAssertNotNil(panes.list.place(of: spotify.id))

        // What leaves the list hands the selection to the row after it.
        panes.select(item: spotify.id)
        XCTAssertTrue(panes.archiveSelected())
        await panes.writing?.value
        XCTAssertNil(panes.list.place(of: spotify.id))
        XCTAssertEqual(panes.selectedItem?.item.name, "Spotify copy")
        XCTAssertTrue(panes.deleteSelected())
        await panes.writing?.value
        XCTAssertEqual(panes.selectedItem?.id, next)
        XCTAssertEqual(backend.count(of: "items"), 1, "the list was never read again")
        XCTAssertEqual(backend.count(of: "trash"), 1)
    }

    // MARK: For good

    func testDeletingForGoodAsksFirstAndSaysWhatIsCutShort() async throws {
        let store = await demo()
        let panes = Panes(store: store)
        let window = hosted(panes)
        panes.select(.trash)
        let closed = try choose("Kapanan hesap", in: panes)
        let before = backend.calls.count

        XCTAssertTrue(panes.deleteSelected())
        XCTAssertEqual(panes.confirming, closed.id)
        XCTAssertEqual(backend.calls.count, before, "nothing is asked of the engine until he has answered")
        try await turn()
        let words = said(in: window.contentView)
        XCTAssertTrue(words.contains { $0.contains("Kapanan hesap") && $0.contains("permanently") }, "\(words)")
        XCTAssertTrue(words.contains { $0.contains("\(Panes.trashDays) days") }, "\(words)")
        XCTAssertEqual(Panes.trashDays, 30)

        // Esc is no.
        XCTAssertTrue(panes.dismiss())
        XCTAssertNil(panes.confirming)
        panes.confirmDelete()
        XCTAssertEqual(backend.calls.count, before)
        XCTAssertNotNil(store.entry(id: closed.id))

        panes.perform(.deleteForGood)
        panes.confirmDelete()
        XCTAssertNil(panes.confirming)
        await panes.writing?.value
        XCTAssertEqual(Array(backend.calls[before...]), ["deletePermanently"])
        XCTAssertNil(store.entry(id: closed.id))
        XCTAssertTrue(store.shelves.trash.isEmpty)

        // Restore, on one deleted a moment ago.
        panes.select(.allItems)
        let spotify = try choose("Spotify", in: panes)
        panes.perform(.delete)
        await panes.writing?.value
        panes.select(.trash)
        panes.select(item: spotify.id)
        panes.perform(.restore)
        await panes.writing?.value
        XCTAssertTrue(store.shelves.trash.isEmpty)
        XCTAssertTrue(ids(store.shelves.all).contains(spotify.id))
        XCTAssertNil(panes.confirming)
    }

    // MARK: Dragging

    func testARowDroppedOnAVaultMovesAndOnArchiveArchives() async throws {
        let store = await demo()
        backend.collections = [.object(["id": .string("org-1"), "name": .string("Ortak")])]
        await store.sync()
        let panes = Panes(store: store)
        let spotify = try id(of: "Spotify", in: store)
        let folder = try XCTUnwrap(panes.moveTargets.first { $0.id != .personal })
        XCTAssertFalse(panes.moveTargets.contains { $0.id == .collection("org-1") })

        XCTAssertNil(panes.change(droppingOn: .vault(folder.id)), "nothing is being dragged")
        let provider = panes.beginDrag(spotify)
        XCTAssertEqual(provider.registeredTypeIdentifiers, [Panes.dragType.identifier])
        XCTAssertNil(panes.change(droppingOn: .vault(.personal)), "it is there already")
        XCTAssertNil(panes.change(droppingOn: .vault(.collection("org-1"))), "an organisation places its own (D9)")
        XCTAssertNil(panes.change(droppingOn: .favorites))
        XCTAssertNil(panes.change(droppingOn: .allItems))
        XCTAssertNil(panes.change(droppingOn: .trash))
        XCTAssertEqual(panes.change(droppingOn: .vault(folder.id)), .move(folder.id))
        XCTAssertEqual(panes.change(droppingOn: .archive), .archive)

        panes.dropTarget = .vault(folder.id)
        XCTAssertTrue(panes.drop(on: .vault(folder.id)))
        XCTAssertNil(panes.dropTarget)
        XCTAssertNil(panes.dragged)
        await panes.writing?.value
        XCTAssertTrue(ids(store.entries(in: folder.id)).contains(spotify))
        XCTAssertEqual(backend.count(of: "save"), 1)
        XCTAssertFalse(panes.drop(on: .archive), "the drag has ended")

        _ = panes.beginDrag(spotify)
        XCTAssertTrue(panes.drop(on: .archive))
        await panes.writing?.value
        XCTAssertTrue(ids(store.shelves.archive).contains(spotify))
        XCTAssertEqual(backend.count(of: "archive"), 1)

        // Out of the archive and into a vault in one drop is a move, which
        // leaves it archived; the menu's Unarchive is the way out.
        _ = panes.beginDrag(spotify)
        XCTAssertNil(panes.change(droppingOn: .archive))
        XCTAssertEqual(panes.change(droppingOn: .vault(.personal)), .move(.personal))

        let deleted = try XCTUnwrap(store.shelves.trash.first)
        _ = panes.beginDrag(deleted.id)
        XCTAssertNil(panes.change(droppingOn: .vault(folder.id)))
        XCTAssertNil(panes.change(droppingOn: .archive))
    }

    /// An item in an organisation's collection. A copy made from its
    /// object would carry the organisation's id and its collections, and
    /// be the organisation's, where every member who can see them sees it.
    func testAnOrganisationsItemIsNotDuplicated() async throws {
        var vault = DemoVault.objects()
        let place = try XCTUnwrap(vault.items.firstIndex { $0["name"]?.string == "Spotify" })
        vault.items[place] = vault.items[place].setting(["organizationId"], to: .string("org-1"))
            .setting(["collectionIds"], to: .array([.string("c-1")]))
        backend = FakeBackend(items: vault.items, folders: vault.folders, password: DemoVault.password)
        backend.lastSync = Date().addingTimeInterval(-60)
        backend.collections = [.object(["object": .string("collection"), "id": .string("c-1"),
                                        "organizationId": .string("org-1"), "name": .string("Ortak")])]
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        let panes = Panes(store: store)
        let spotify = try choose("Spotify", in: panes)
        XCTAssertEqual(spotify.organizationID, "org-1")

        XCTAssertFalse(panes.itemActs.joined().contains(.duplicate), "the menu offers a copy it cannot keep his")
        XCTAssertTrue(panes.itemActs.joined().contains(.favourite), "the rest of the menu is as it was")
        do {
            try await store.apply(.duplicate, to: spotify.id)
            XCTFail("a copy was made")
        } catch {
            XCTAssertEqual(error as? VaultError, .refused(VaultStore.cannotCopyShared))
        }
        XCTAssertEqual(backend.count(of: "create"), 0)
        XCTAssertNil(backend.lastCreated?["organizationId"]?.string, "the organisation's id was sent in a new item")

        // His own item is copied as before.
        let github = try choose("GitHub", in: panes)
        XCTAssertTrue(panes.itemActs.joined().contains(.duplicate))
        let made = try await store.apply(.duplicate, to: github.id)
        XCTAssertEqual(made?.name, "GitHub copy")
    }

    // MARK: The keys

    private func key(_ characters: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                       windowNumber: 0, context: nil, characters: characters,
                                       charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 51))
    }

    private func catcher(in view: NSView?) -> ListKeys.Catcher? {
        guard let view else { return nil }
        if let found = view as? ListKeys.Catcher { return found }
        return view.subviews.lazy.compactMap(catcher(in:)).first
    }

    func testDeleteAtTheListArchives() async throws {
        let store = await demo()
        let panes = Panes(store: store)
        let window = hosted(panes)
        let spotify = try choose("Spotify", in: panes)
        try await turn()
        let keys = try XCTUnwrap(catcher(in: window.contentView))

        // With ⌘ it is the menu's.
        keys.keyDown(with: try key("\u{7F}", modifiers: .command))
        XCTAssertNil(panes.writing)

        keys.keyDown(with: try key("\u{7F}"))
        await panes.writing?.value
        XCTAssertTrue(ids(store.shelves.archive).contains(spotify.id))
        XCTAssertEqual(backend.count(of: "archive"), 1)
        XCTAssertEqual(backend.count(of: "delete"), 0)
    }

    func testCommandOAndCommandDeleteAreInTheItemMenu() async throws {
        let store = await demo()
        let door = Door(store: store, defaults: defaults)
        var isTyping = false
        let commands = ItemCommands(door: door) { isTyping }
        let items = commands.menu().items
        let window = try XCTUnwrap(items.first { $0.keyEquivalent == "o" })
        let delete = try XCTUnwrap(items.first { $0.keyEquivalent == "\u{8}" })
        XCTAssertEqual(window.keyEquivalentModifierMask, .command)
        XCTAssertEqual(window.title, "Open in New Window")
        XCTAssertEqual(delete.keyEquivalentModifierMask, .command)
        XCTAssertEqual(items.filter { !$0.isSeparatorItem }.count, 10, "and none for Delete alone")
        let panes = try XCTUnwrap(door.panes)

        XCTAssertEqual([window, delete].map(commands.validateMenuItem), [false, false], "no item")
        let spotify = try choose("Spotify", in: panes)
        XCTAssertEqual([window, delete].map(commands.validateMenuItem), [true, true])
        XCTAssertEqual(delete.title, "Delete")

        // In a field ⌘Delete rubs out the line.
        isTyping = true
        XCTAssertFalse(commands.validateMenuItem(delete))
        isTyping = false

        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(window.action), to: window.target, from: window))
        XCTAssertEqual(panes.windows?.windows.count, 1)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(delete.action), to: delete.target, from: delete))
        await panes.writing?.value
        XCTAssertTrue(ids(store.shelves.trash).contains(spotify.id))
        XCTAssertEqual(backend.count(of: "delete"), 1)

        panes.select(.trash)
        panes.select(item: spotify.id)
        XCTAssertEqual([window, delete].map(commands.validateMenuItem), [false, true])
        XCTAssertEqual(delete.title, "Delete Permanently")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(delete.action), to: delete.target, from: delete))
        XCTAssertEqual(panes.confirming, spotify.id)
        XCTAssertEqual(backend.count(of: "deletePermanently"), 0)

        await store.lock()
        XCTAssertEqual([window, delete].map(commands.validateMenuItem), [false, false])
    }

    /// The settings window has the keys, or a preview, or nothing does
    /// because the main window is closed and the app is in the menu bar.
    func testWithTheKeysInAWindowThatIsNotTheVaultsTheItemMenuDoesNothing() async throws {
        let store = await demo()
        let door = Door(store: store, defaults: defaults)
        var mainHasKeys = true
        let commands = ItemCommands(door: door, mainHasKeys: { mainHasKeys }, isTyping: { false })
        let items = commands.menu().items
        let delete = try XCTUnwrap(items.first { $0.keyEquivalent == "\u{8}" })
        let panes = try XCTUnwrap(door.panes)
        let spotify = try choose("Spotify", in: panes)
        XCTAssertTrue(commands.validateMenuItem(delete))

        mainHasKeys = false
        let stillOn = items.filter { !$0.isSeparatorItem && commands.validateMenuItem($0) }.map(\.title)
        XCTAssertEqual(stillOn, ["New Item…", "Password Generator…", "Open in New Window"],
                       "the three that are the main window's whichever window has the keys")
        XCTAssertFalse(commands.delete())
        XCTAssertFalse(commands.edit())
        XCTAssertFalse(commands.copyPassword())
        XCTAssertFalse(commands.canCopy)
        XCTAssertNil(panes.writing)
        XCTAssertNil(panes.editor)
        XCTAssertEqual(backend.count(of: "delete"), 0, "an item went to the trash from a window that does not show it")
        XCTAssertFalse(ids(store.shelves.trash).contains(spotify.id))

        mainHasKeys = true
        XCTAssertTrue(commands.delete())
        await panes.writing?.value
        XCTAssertTrue(ids(store.shelves.trash).contains(spotify.id))
    }

    /// A question about something else stands over the window, or the
    /// details are a form: the item lit in the list is not what a key is
    /// about.
    func testDeleteAndCommandDeleteDoNothingToTheItemUnderAQuestionOrAForm() async throws {
        let store = await demo()
        let door = Door(store: store, defaults: defaults)
        let commands = ItemCommands(door: door) { false }
        let delete = try XCTUnwrap(commands.menu().items.first { $0.keyEquivalent == "\u{8}" })
        let panes = try XCTUnwrap(door.panes)
        let folder = try XCTUnwrap(panes.vaults.first { $0.id != .personal })
        let spotify = try choose("Spotify", in: panes)
        panes.focus = .list

        let standing: [(String, () -> Void, () -> Void)] = [
            ("a vault's deletion", { panes.deletingVault = folder }, { panes.deletingVault = nil }),
            ("a vault's name", { XCTAssertTrue(panes.beginNewVault()) }, { panes.naming = nil }),
            ("the discard question", { panes.isAskingToDiscard = true }, { panes.isAskingToDiscard = false }),
            ("the form", { XCTAssertTrue(panes.beginEdit()) }, { panes.editor = nil }),
        ]
        for (name, raise, lower) in standing {
            raise()
            XCTAssertFalse(commands.validateMenuItem(delete), "⌘Delete is lit under \(name)")
            XCTAssertFalse(commands.delete(), name)
            XCTAssertTrue(panes.press(.delete), "the key is still the window's and not a beep")
            XCTAssertFalse(panes.archiveSelected(), name)
            XCTAssertNil(panes.writing, "something was sent under \(name)")
            lower()
        }
        // The question before an item is deleted for good is about that
        // item, and Delete under it archives nothing either.
        XCTAssertEqual(backend.calls.filter { ["delete", "archive", "deletePermanently"].contains($0) }, [])
        XCTAssertEqual(panes.selectedItem?.id, spotify.id)

        XCTAssertTrue(commands.validateMenuItem(delete), "and with nothing over the window the key is back")
        XCTAssertTrue(commands.delete())
        await panes.writing?.value
        XCTAssertTrue(ids(store.shelves.trash).contains(spotify.id))
    }

    // MARK: A window of its own

    func testAWindowOfOneItemShowsItAndClosesOnLock() async throws {
        let store = await demo()
        var presented: [NSWindow] = []
        let door = Door(store: store, defaults: defaults, present: { presented.append($0) })
        let panes = try XCTUnwrap(door.panes)
        let bank = try choose("İş Bankası", in: panes)
        let password = try XCTUnwrap(bank.login?.password)

        XCTAssertTrue(panes.openWindow())
        XCTAssertTrue(panes.openWindow(), "a second ⌘O brings the first forward")
        let windows = try XCTUnwrap(panes.windows)
        XCTAssertEqual(windows.windows.count, 1)
        XCTAssertEqual(presented.count, 2)
        XCTAssertTrue(presented[0] === presented[1])
        let window = presented[0]
        XCTAssertFalse(window.isVisible, "a test's window is made and never shown")
        XCTAssertFalse(window.isRestorable)
        XCTAssertEqual(window.title, "İş Bankası")
        window.layoutIfNeeded()
        try await turn()
        var words = said(in: window.contentView)
        XCTAssertTrue(words.contains("İş Bankası"))
        XCTAssertFalse(words.contains(password))

        // Revealed there is not revealed here, and the main window's list
        // moves on without it.
        let own = try XCTUnwrap(windows.panes(showing: bank.id))
        XCTAssertFalse(own.itemActs.joined().contains(.openWindow))
        own.toggleRevealed()
        try await turn()
        words = said(in: window.contentView)
        XCTAssertTrue(words.contains(password))
        XCTAssertTrue(panes.reading.revealed.isEmpty)
        try choose("GitHub", in: panes)
        XCTAssertEqual(own.selectedItem?.id, bank.id)
        XCTAssertFalse(own.reading.revealed.isEmpty)
        XCTAssertTrue(panes.openWindow())
        XCTAssertEqual(windows.windows.count, 2)

        // A change made in it is made, and it goes on showing the item.
        own.perform(.delete)
        await own.writing?.value
        try await turn()
        XCTAssertTrue(ids(store.shelves.trash).contains(bank.id))
        XCTAssertEqual(windows.windows.count, 2)
        XCTAssertEqual(own.itemActs, [[.restore, .deleteForGood]])

        await store.lock()
        XCTAssertNil(door.panes)
        XCTAssertTrue(windows.windows.isEmpty)
        for window in presented {
            XCTAssertNil(window.contentView, "nothing of the item is left in it")
            XCTAssertEqual(window.title, "")
            XCTAssertFalse(window.isVisible)
        }
        XCTAssertTrue(own.reading.revealed.isEmpty)
        XCTAssertTrue(said(in: window.contentView).isEmpty)
    }

    func testAWindowWhoseItemIsGoneForGoodClosesByItself() async throws {
        let store = await demo()
        var presented: [NSWindow] = []
        let panes = Panes(store: store, present: { presented.append($0) })
        panes.select(.trash)
        let closed = try choose("Kapanan hesap", in: panes)
        // Not from the menu, where a deleted item has no such row.
        let windows = try XCTUnwrap(panes.windows)
        windows.open(closed.id, from: panes)
        panes.select(.allItems)
        try choose("Spotify", in: panes)
        XCTAssertTrue(panes.openWindow())
        XCTAssertEqual(windows.windows.count, 2)

        let own = try XCTUnwrap(windows.panes(showing: closed.id))
        own.perform(.deleteForGood)
        XCTAssertEqual(own.confirming, closed.id, "the question is asked in the window it was asked from")
        XCTAssertNil(panes.confirming)
        own.confirmDelete()
        await own.writing?.value
        try await turn()
        XCTAssertEqual(windows.windows.count, 1)
        XCTAssertNil(presented[0].contentView)
        XCTAssertEqual(presented[0].title, "")
        XCTAssertNotNil(presented[1].contentView)

        // He closes the other himself.
        presented[1].close()
        XCTAssertTrue(windows.windows.isEmpty)
        XCTAssertNil(presented[1].contentView)
        panes.end()
    }
}
