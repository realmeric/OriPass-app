import XCTest
@testable import OriPass

/// A vault is a folder (D9): made, renamed and deleted through the store and
/// through the sidebar's card, over the fake engine.
@MainActor
final class VaultTests: XCTestCase {
    private var backend: FakeBackend!

    override func tearDown() {
        backend = nil
    }

    /// The demo vault, with the first folder holding one item that is in the
    /// trash and one that is archived as well, so that a deleted folder has
    /// something in each place an item can be.
    private func demo(collection: String? = nil) async -> (VaultStore, folder: Folder, inside: Set<String>) {
        var vault = DemoVault.objects()
        let id = vault.folders[0]["id"]?.string ?? ""
        for key in ["deletedDate", "archivedDate"] {
            if let place = vault.items.firstIndex(where: { $0[key]?.string != nil }) {
                vault.items[place] = vault.items[place].setting(["folderId"], to: .string(id))
            }
        }
        let inside = Set(vault.items.filter { $0["folderId"]?.string == id }.compactMap { $0["id"]?.string })
        backend = FakeBackend(items: vault.items, folders: vault.folders, password: DemoVault.password)
        backend.lastSync = Date().addingTimeInterval(-60)
        if let collection {
            backend.collections = [.object(["object": .string("collection"), "id": .string("c-1"),
                                            "name": .string(collection)])]
        }
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        return (store, Folder(id: id, name: DemoVault.folderNames[0]), inside)
    }

    private func names(_ store: VaultStore) -> [String] { store.shelves.vaults.map(\.name) }

    private func everyItem(_ store: VaultStore) -> [Entry] {
        store.shelves.all + store.shelves.archive + store.shelves.trash
    }

    // MARK: The store

    func testAVaultIsMadeAndIsAmongTheVaultsInTheirOrder() async throws {
        let (store, _, _) = await demo()
        let revision = store.revision
        let made = try await store.makeVault(named: "  Okul ")
        XCTAssertEqual(made?.name, "Okul")
        XCTAssertEqual(backend.count(of: "createFolder"), 1)
        XCTAssertEqual(names(store), ["Personal", "Çalışma", "Dükkan", "İş", "Okul"])
        XCTAssertEqual(store.entries(in: try XCTUnwrap(made).id).count, 0)
        XCTAssertEqual(store.revision, revision + 1)

        // What the server holds is what the store holds.
        let before = names(store)
        await store.sync()
        XCTAssertEqual(names(store), before)
    }

    func testAVaultIsRenamedAndItsItemsStayInIt() async throws {
        let (store, folder, inside) = await demo()
        let place = Vault.Place.folder(folder.id)
        let before = store.entries(in: place).map(\.id)
        XCTAssertFalse(before.isEmpty)

        try await store.renameVault(place, to: "Arşiv")
        XCTAssertEqual(backend.count(of: "renameFolder"), 1)
        XCTAssertEqual(names(store), ["Personal", "Arşiv", "Çalışma", "İş"])
        XCTAssertEqual(store.entries(in: place).map(\.id), before)
        XCTAssertEqual(everyItem(store).filter { $0.item.folderID == folder.id }.map(\.id).sorted(),
                       inside.sorted())

        let after = names(store)
        await store.sync()
        XCTAssertEqual(names(store), after)
    }

    func testADeletedVaultsItemsAreInPersonalWhereverTheyWere() async throws {
        let (store, folder, inside) = await demo()
        let place = Vault.Place.folder(folder.id)
        XCTAssertTrue(store.shelves.trash.contains { inside.contains($0.id) }, "the fixture has one in the trash")
        XCTAssertTrue(store.shelves.archive.contains { inside.contains($0.id) }, "and one archived")
        let personal = store.entries(in: .personal).map(\.id)
        let moved = store.entries(in: place).map(\.id)
        XCTAssertFalse(moved.isEmpty)
        let total = everyItem(store).count
        let password = store.shelves.all.first { $0.item.login?.password != nil }
        let level = password?.strength

        try await store.deleteVault(place)
        XCTAssertEqual(backend.count(of: "deleteFolder"), 1)
        XCTAssertEqual(names(store), ["Personal", "Çalışma", "İş"])
        XCTAssertEqual(Set(store.entries(in: .personal).map(\.id)), Set(personal + moved))
        XCTAssertEqual(everyItem(store).count, total, "no item went with the vault")
        XCTAssertFalse(everyItem(store).contains { $0.item.folderID == folder.id })
        XCTAssertTrue(inside.allSatisfy { id in
            store.entry(id: id).map { $0.item.folderID == nil } ?? false
        }, "the trash's and the archive's too")
        XCTAssertEqual(store.entry(id: password?.id ?? "")?.strength, level)
        // Not one item was sent: the engine moves them itself.
        XCTAssertEqual(backend.count(of: "save"), 0)

        // The server agrees with what the store worked out.
        let held = everyItem(store).map { "\($0.id) \($0.item.folderID ?? "-")" }.sorted()
        await store.sync()
        XCTAssertEqual(everyItem(store).map { "\($0.id) \($0.item.folderID ?? "-")" }.sorted(), held)
    }

    func testANameInUseIsRefusedBeforeTheEngineIsAsked() async throws {
        let (store, folder, _) = await demo(collection: "Ortak")
        let taken = ["Personal", "personal", "  PERSONAL ", "Dükkan", "dükkan", "iş", "İŞ", "ortak"]
        for name in taken {
            do {
                _ = try await store.makeVault(named: name)
                XCTFail("\(name) was taken")
            } catch VaultError.refused(let sentence) {
                XCTAssertEqual(sentence, VaultStore.taken(name.trimmingCharacters(in: .whitespaces)))
            }
        }
        for name in ["", "   \n"] {
            do {
                _ = try await store.makeVault(named: name)
                XCTFail("nothing is a name")
            } catch VaultError.refused(let sentence) {
                XCTAssertEqual(sentence, VaultStore.nameless)
            }
        }
        do {
            try await store.renameVault(.folder(folder.id), to: "İş")
            XCTFail("another vault's name")
        } catch VaultError.refused {}

        XCTAssertEqual(backend.count(of: "createFolder"), 0)
        XCTAssertEqual(backend.count(of: "renameFolder"), 0)
        XCTAssertEqual(names(store).count, 5)
    }

    func testAVaultMayChangeTheCaseOfItsOwnNameAndKeepingItSendsNothing() async throws {
        let (store, folder, _) = await demo()
        let place = Vault.Place.folder(folder.id)
        try await store.renameVault(place, to: "dükkan")
        XCTAssertEqual(backend.count(of: "renameFolder"), 1)
        XCTAssertTrue(names(store).contains("dükkan"))
        try await store.renameVault(place, to: " dükkan ")
        XCTAssertEqual(backend.count(of: "renameFolder"), 1)
    }

    func testOnlyAFolderCanBeRenamedOrDeleted() async throws {
        let (store, _, _) = await demo(collection: "Ortak")
        for place in [Vault.Place.personal, .collection("c-1"), .folder("no-such-folder")] {
            do {
                try await store.renameVault(place, to: "Başka")
                XCTFail("renamed \(place)")
            } catch VaultError.refused {}
            do {
                try await store.deleteVault(place)
                XCTFail("deleted \(place)")
            } catch VaultError.refused {}
        }
        XCTAssertEqual(backend.count(of: "renameFolder") + backend.count(of: "deleteFolder"), 0)
        XCTAssertEqual(names(store).count, 5)
    }

    func testARefusedWriteLeavesTheVaultsAsTheyWere() async throws {
        let (store, folder, _) = await demo()
        let before = names(store)
        let revision = store.revision
        backend.isOffline = true
        do {
            _ = try await store.makeVault(named: "Okul")
            XCTFail("offline")
        } catch VaultError.refused(let sentence) {
            XCTAssertEqual(sentence, FakeBackend.offline)
        }
        do {
            try await store.renameVault(.folder(folder.id), to: "Okul")
            XCTFail("offline")
        } catch VaultError.refused {}
        do {
            try await store.deleteVault(.folder(folder.id))
            XCTFail("offline")
        } catch VaultError.refused {}
        XCTAssertEqual(names(store), before)
        XCTAssertEqual(store.revision, revision)
    }

    func testTheLockOvertakingTheEngineLeavesNothingAmongTheVaults() async throws {
        let (store, folder, _) = await demo()
        backend.delay = 0.2
        let making = Task { try await store.makeVault(named: "Okul") }
        try await Task.sleep(nanoseconds: 50_000_000)
        await store.lock()
        // Answered nothing, or locked: either way it is among nothing.
        let made = try? await making.value
        XCTAssertNil(made.flatMap { $0 })
        XCTAssertTrue(store.folders.isEmpty)
        XCTAssertEqual(names(store), ["Personal"])

        backend.delay = 0
        await store.unlock(password: SecretBytes(DemoVault.password))
        backend.delay = 0.2
        let deleting = Task { try await store.deleteVault(.folder(folder.id)) }
        try await Task.sleep(nanoseconds: 50_000_000)
        await store.lock()
        _ = try? await deleting.value
        XCTAssertTrue(store.shelves.all.isEmpty)
        XCTAssertTrue(store.folders.isEmpty)
    }

    // MARK: The sidebar

    private func panes(_ store: VaultStore) -> Panes { Panes(store: store) }

    func testPersonalAndACollectionHaveNoMenuAndAFolderHasTwoActs() async throws {
        let (store, _, _) = await demo(collection: "Ortak")
        let panes = panes(store)
        let acts = panes.vaults.map { ($0.name, panes.acts(for: $0)) }
        XCTAssertEqual(acts.map(\.0), ["Personal", "Çalışma", "Dükkan", "İş", "Ortak"])
        XCTAssertEqual(acts.map(\.1), [[], [.rename, .delete], [.rename, .delete], [.rename, .delete], []])
        XCTAssertEqual(VaultAct.rename.name, "Rename…")
        XCTAssertEqual(VaultAct.delete.name, "Delete…")

        XCTAssertFalse(panes.beginRename(.personal))
        XCTAssertFalse(panes.beginDelete(.personal))
        XCTAssertFalse(panes.beginRename(.collection("c-1")))
        XCTAssertFalse(panes.beginDelete(.collection("c-1")))
        XCTAssertNil(panes.naming)
        XCTAssertNil(panes.deletingVault)

        // A window of one item has no sidebar.
        let pinned = panes.pinned(to: store.shelves.all[0].id)
        XCTAssertFalse(pinned.beginNewVault())
        XCTAssertTrue(pinned.vaults.allSatisfy { pinned.acts(for: $0).isEmpty })
    }

    func testThePlusAsksForANameMakesTheVaultAndOpensIt() async throws {
        let (store, _, _) = await demo()
        let panes = panes(store)
        panes.toggleVaults()
        XCTAssertTrue(panes.vaultsFolded)
        XCTAssertTrue(panes.beginNewVault())
        XCTAssertEqual(panes.naming?.title, "New Vault")
        XCTAssertEqual(panes.naming?.button, "Create")
        XCTAssertFalse(panes.naming?.canSend ?? true, "nothing is typed")
        XCTAssertNil(panes.submitNaming())
        XCTAssertEqual(backend.count(of: "createFolder"), 0)

        panes.naming?.name = "Okul"
        await panes.submitNaming()?.value
        XCTAssertNil(panes.naming)
        XCTAssertEqual(backend.count(of: "createFolder"), 1)
        let made = try XCTUnwrap(panes.vaults.first { $0.name == "Okul" })
        XCTAssertEqual(panes.selection, .vault(made.id))
        XCTAssertFalse(panes.vaultsFolded, "its row is shown")
        XCTAssertTrue(panes.listed.isEmpty)
        XCTAssertTrue(panes.writes.isEmpty)
    }

    func testANameInUseIsSaidUnderTheFieldAndWhatWasTypedStays() async throws {
        let (store, _, _) = await demo()
        let panes = panes(store)
        panes.beginNewVault()
        panes.naming?.name = "Personal"
        XCTAssertNil(panes.submitNaming())
        XCTAssertEqual(panes.naming?.problem, VaultStore.taken("Personal"))
        XCTAssertEqual(panes.naming?.name, "Personal")
        XCTAssertEqual(backend.count(of: "createFolder"), 0)

        // The next keystroke is about another name.
        panes.naming?.name = "Personal 2"
        XCTAssertNil(panes.naming?.problem)
        await panes.submitNaming()?.value
        XCTAssertNil(panes.naming)
        XCTAssertEqual(backend.count(of: "createFolder"), 1)
    }

    func testTheEnginesRefusalIsSaidOnTheCardAndTheCardStaysOpen() async throws {
        let (store, _, _) = await demo()
        let panes = panes(store)
        backend.isOffline = true
        panes.beginNewVault()
        panes.naming?.name = "Okul"
        await panes.submitNaming()?.value
        XCTAssertEqual(panes.naming?.name, "Okul")
        XCTAssertEqual(panes.naming?.problem, FakeBackend.offline)
        XCTAssertEqual(panes.naming?.isSending, false)
        XCTAssertEqual(names(store).count, 4)

        backend.isOffline = false
        await panes.submitNaming()?.value
        XCTAssertNil(panes.naming)
        XCTAssertEqual(names(store).count, 5)
    }

    func testRenameStartsFromTheNameItHasAndReplacesIt() async throws {
        let (store, folder, _) = await demo()
        let panes = panes(store)
        let place = Vault.Place.folder(folder.id)
        panes.select(.vault(place))
        XCTAssertTrue(panes.beginRename(place))
        XCTAssertEqual(panes.naming?.title, "Rename “Dükkan”")
        XCTAssertEqual(panes.naming?.name, "Dükkan")
        XCTAssertEqual(panes.naming?.button, "Rename")

        // Its own name is not another vault's; nothing is sent for it.
        await panes.submitNaming()?.value
        XCTAssertNil(panes.naming)
        XCTAssertEqual(backend.count(of: "renameFolder"), 0)

        panes.beginRename(place)
        panes.naming?.name = "Ev"
        await panes.submitNaming()?.value
        XCTAssertNil(panes.naming)
        XCTAssertEqual(backend.count(of: "renameFolder"), 1)
        XCTAssertEqual(panes.selection, .vault(place), "the row stays selected under its new name")
        XCTAssertEqual(panes.vaults.map(\.name), ["Personal", "Çalışma", "Ev", "İş"])
    }

    func testDeleteAsksFirstAndTheSelectedRowGoesToAllItems() async throws {
        let (store, folder, inside) = await demo()
        let panes = panes(store)
        let place = Vault.Place.folder(folder.id)
        panes.select(.vault(place))
        let count = store.entries(in: place).count
        let personal = store.entries(in: .personal).count

        XCTAssertTrue(panes.beginDelete(place))
        XCTAssertEqual(panes.deletingVault?.name, "Dükkan")
        XCTAssertEqual(backend.count(of: "deleteFolder"), 0, "nothing is sent by the question")
        XCTAssertTrue(panes.dismiss())
        XCTAssertNil(panes.deletingVault)
        XCTAssertEqual(backend.count(of: "deleteFolder"), 0)
        XCTAssertEqual(panes.vaults.count, 4)

        panes.beginDelete(place)
        await panes.confirmDeleteVault()?.value
        XCTAssertNil(panes.deletingVault)
        XCTAssertEqual(backend.count(of: "deleteFolder"), 1)
        XCTAssertEqual(panes.selection, .allItems)
        XCTAssertEqual(panes.vaults.map(\.name), ["Personal", "Çalışma", "İş"])
        XCTAssertEqual(store.entries(in: .personal).count, personal + count)
        panes.select(.vault(.personal))
        XCTAssertEqual(panes.listed.count, personal + count)
        XCTAssertFalse(inside.isEmpty)
    }

    func testARefusedDeleteIsSaidAtTheFootAndTheVaultStays() async throws {
        let (store, folder, _) = await demo()
        let panes = panes(store)
        backend.isOffline = true
        panes.beginDelete(.folder(folder.id))
        await panes.confirmDeleteVault()?.value
        XCTAssertEqual(panes.refused, FakeBackend.offline)
        XCTAssertEqual(panes.vaults.count, 4)
    }

    func testEscPutsEachCardAwayAndTheLockTakesThemAndWhatTheyAsked() async throws {
        let (store, folder, _) = await demo()
        let door = Door(store: store)
        var panes = try XCTUnwrap(door.panes)
        panes.beginNewVault()
        XCTAssertTrue(panes.dismiss())
        XCTAssertNil(panes.naming)
        XCTAssertFalse(panes.dismiss())

        // A card up, and a create the lock overtakes.
        panes.beginNewVault()
        panes.naming?.name = "Okul"
        backend.delay = 0.2
        let sending = try XCTUnwrap(panes.submitNaming())
        await store.lock()
        await sending.value
        XCTAssertNil(panes.naming)
        XCTAssertNil(panes.refused)
        XCTAssertNil(door.panes)

        backend.delay = 0
        await store.unlock(password: SecretBytes(DemoVault.password))
        panes = try XCTUnwrap(door.panes)
        panes.beginDelete(.folder(folder.id))
        await store.lock()
        XCTAssertNil(panes.deletingVault)
        XCTAssertEqual(backend.count(of: "deleteFolder"), 0)
    }
}
