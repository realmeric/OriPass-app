import AppKit
import SwiftUI
import XCTest
@testable import OriPass

@MainActor
final class SidebarTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "oripass-sidebar-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    /// The demo vault, with one more folder that nothing is in and, when
    /// asked, a collection that two of its items are in.
    private func backend(emptyFolder: String? = nil, collection: String? = nil) -> FakeBackend {
        var vault = DemoVault.objects()
        if let emptyFolder {
            vault.folders.append(.object(["object": .string("folder"), "id": .string("f-empty"),
                                          "name": .string(emptyFolder)]))
        }
        if collection != nil {
            for index in 0..<2 {
                vault.items[index] = vault.items[index].setting(["collectionIds"], to: .array([.string("c-1")]))
            }
        }
        let backend = FakeBackend(items: vault.items, folders: vault.folders, password: DemoVault.password)
        if let collection {
            backend.collections = [.object(["object": .string("collection"), "id": .string("c-1"),
                                            "name": .string(collection)])]
        }
        // Synced a minute ago, so no sync is running behind the panes.
        backend.lastSync = Date().addingTimeInterval(-60)
        return backend
    }

    private func unlocked(_ backend: FakeBackend) async -> VaultStore {
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        return store
    }

    private func turn(_ seconds: Double = 0.05) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: The vaults

    /// A real account as `bw` listed it: one row in the folder list, "No
    /// Folder" with an empty id, and no item in any folder.
    func testAnAccountWithNoFolderOfItsOwnDrawsPersonalAndNoEmptyVault() async throws {
        var vault = DemoVault.objects()
        vault.items = try vault.items.map { item in
            var members = try XCTUnwrap(item.object)
            members["folderId"] = nil
            return .object(members)
        }
        vault.folders = [.object(["object": .string("folder"), "id": .string(""), "name": .string("No Folder")])]
        let backend = FakeBackend(items: vault.items, folders: vault.folders, password: DemoVault.password)
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = await unlocked(backend)
        let panes = Panes(store: store)
        XCTAssertEqual(panes.vaults, [.personal])
        XCTAssertEqual(store.entries(in: .personal).count, store.shelves.all.count, "every item is in Personal")

        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: SidebarView(panes: panes))
        window.layoutIfNeeded()
        try await turn()
        let words = said(in: window.contentView)
        XCTAssertTrue(words.contains("Personal"), "the sidebar says \(words)")
        XCTAssertFalse(words.contains { $0.contains("No Folder") })
        window.close()
    }

    func testTheDemosVaultsArePersonalAndThenItsFoldersAsATurkishReaderFilesThem() async {
        let store = await unlocked(backend())
        XCTAssertEqual(DemoVault.folderNames, ["Dükkan", "İş", "Çalışma"], "the demo lists them out of order")
        XCTAssertEqual(Panes(store: store).vaults.map(\.name), ["Personal", "Çalışma", "Dükkan", "İş"])
    }

    func testTheOrderIsTurkishWhateverTheMacIsSetTo() {
        let names = ["Zeytin", "İş", "ilk", "Şirket", "Ilgaz", "Dükkan", "Özel", "Sanat", "çay", "Cam", "Okul", "Vault 10", "Vault 9"]
        let vaults = Vault.ordered(folders: names.enumerated().map { Folder(id: "\($0)", name: $1) }, collections: [])
        XCTAssertEqual(vaults.map(\.name), [
            "Personal", "Cam", "çay", "Dükkan", "Ilgaz", "ilk", "İş", "Okul", "Özel", "Sanat", "Şirket",
            "Vault 9", "Vault 10", "Zeytin",
        ])
    }

    func testACollectionComesAfterTheFoldersAndTakesNothing() async {
        let store = await unlocked(backend(collection: "Aile"))
        let vaults = Panes(store: store).vaults
        XCTAssertEqual(vaults.map(\.name), ["Personal", "Çalışma", "Dükkan", "İş", "Aile"])
        XCTAssertEqual(vaults.map(\.takesItems), [true, true, true, true, false])
        XCTAssertEqual(store.entries(in: .collection("c-1")).count, 2)
    }

    // MARK: The selection

    func testSelectingAVaultPublishesItsItemsAndNothingElse() async throws {
        let store = await unlocked(backend())
        let panes = Panes(store: store)
        XCTAssertEqual(panes.selection, .allItems)
        XCTAssertEqual(panes.listed.count, store.shelves.all.count)

        var seen = 0
        for vault in panes.vaults {
            var published = 0
            let watching = panes.objectWillChange.sink { published += 1 }
            panes.select(.vault(vault.id))
            watching.cancel()
            XCTAssertEqual(published, 1)

            let folder: String?
            switch vault.id {
            case .folder(let id): folder = id
            default: folder = nil
            }
            XCTAssertFalse(panes.listed.isEmpty, vault.name)
            XCTAssertTrue(panes.listed.allSatisfy { $0.item.folderID == folder && !$0.item.isArchived }, vault.name)
            XCTAssertEqual(panes.listed.count, store.shelves.all.filter { $0.item.folderID == folder }.count)
            seen += panes.listed.count
        }
        // An item is in one vault or in none, and none is Personal (D9).
        XCTAssertEqual(seen, store.shelves.all.count)
    }

    func testTheOtherRowsListTheirOwnShelves() async {
        let store = await unlocked(backend())
        let panes = Panes(store: store)
        XCTAssertEqual(panes.upperRows, [.allItems, .favorites, .passwordHealth])
        XCTAssertEqual(panes.lowerRows, [.archive, .trash])

        panes.select(.favorites)
        XCTAssertFalse(panes.listed.isEmpty)
        XCTAssertTrue(panes.listed.allSatisfy(\.item.favorite))
        panes.select(.archive)
        XCTAssertFalse(panes.listed.isEmpty)
        XCTAssertTrue(panes.listed.allSatisfy(\.item.isArchived))
        panes.select(.trash)
        XCTAssertFalse(panes.listed.isEmpty)
        XCTAssertTrue(panes.listed.allSatisfy { $0.item.deleted != nil })
        // Password Health is a page, and lists nothing until a card is asked for.
        panes.select(.passwordHealth)
        XCTAssertTrue(panes.listed.isEmpty)
        XCTAssertTrue(panes.showsDashboard)
    }

    func testAnEmptyVaultShowsTheListsEmptyState() async throws {
        let store = await unlocked(backend(emptyFolder: "Arşiv"))
        let panes = Panes(store: store)
        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: PanesView(panes: panes))
        window.setContentSize(Metrics.windowSize)
        window.layoutIfNeeded()
        try await turn()

        let full = said(in: window.contentView)
        XCTAssertTrue(full.contains("Apple Account"), "\(full)")
        XCTAssertFalse(full.contains("No items"))
        XCTAssertTrue(full.contains("Arşiv"))

        let empty = try XCTUnwrap(panes.vaults.first { $0.name == "Arşiv" })
        panes.select(.vault(empty.id))
        try await turn()
        XCTAssertEqual(panes.listed.count, 0)
        XCTAssertTrue(said(in: window.contentView).contains("No items"))
    }

    func testAVaultThatASyncTookAwayLeavesAllItemsSelected() async {
        let fake = backend(emptyFolder: "Arşiv")
        let store = await unlocked(fake)
        let panes = Panes(store: store)
        panes.select(.vault(.folder("f-empty")))
        XCTAssertEqual(panes.selection, .vault(.folder("f-empty")))

        fake.incoming = DemoVault.objects()
        await store.sync()
        XCTAssertEqual(panes.selection, .allItems)
        XCTAssertEqual(panes.listed.count, store.shelves.all.count)
    }

    func testArchiveIsDrawnOnlyForAnAccountThatHasOne() async {
        var vault = DemoVault.objects()
        vault.items.removeAll { $0["archivedDate"]?.string != nil }
        let store = await unlocked(FakeBackend(items: vault.items, folders: vault.folders,
                                               password: DemoVault.password))
        let panes = Panes(store: store)
        XCTAssertEqual(panes.lowerRows, [.trash])
        panes.select(.archive)
        XCTAssertEqual(panes.selection, .allItems)
    }

    // MARK: The keys

    func testCommandOneIsAllItemsAndTwoToNineAreTheVaultsInOrder() async throws {
        let store = VaultStore(backend: backend())
        let door = Door(store: store, defaults: defaults)
        let commands = WindowCommands(door: door)
        XCTAssertEqual(commands.rowItems.map(\.keyEquivalent), (1...9).map(String.init))
        XCTAssertTrue(commands.rowItems.allSatisfy { $0.keyEquivalentModifierMask == .command })
        XCTAssertFalse(commands.validateMenuItem(commands.rowItems[0]), "there are no rows behind the lock screen")
        XCTAssertFalse(commands.selectRow(2))

        await store.unlock(password: SecretBytes(DemoVault.password))
        try await turn()
        let panes = try XCTUnwrap(door.panes)
        XCTAssertEqual(commands.rowItems.map(\.title),
                       ["All Items", "Personal", "Çalışma", "Dükkan", "İş", "", "", "", ""])
        XCTAssertEqual(commands.rowItems.map(\.isHidden),
                       [false, false, false, false, false, true, true, true, true])

        for (digit, name) in zip(2...5, ["Personal", "Çalışma", "Dükkan", "İş"]) {
            let item = commands.rowItems[digit - 1]
            XCTAssertTrue(commands.validateMenuItem(item))
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            XCTAssertEqual(panes.selection, .vault(try XCTUnwrap(panes.vaults.first { $0.name == name }).id))
        }
        XCTAssertFalse(commands.validateMenuItem(commands.rowItems[5]))
        XCTAssertFalse(commands.selectRow(6))
        XCTAssertTrue(commands.selectRow(1))
        XCTAssertEqual(panes.selection, .allItems)

        // The names leave the menu with the vault, and not a turn of the
        // main queue after it: whoever hears that it is locked finds them
        // gone, and so does the line after the lock.
        var heard: [String]?
        let listening = NotificationCenter.default.addObserver(
            forName: VaultStore.didLock, object: store, queue: nil) { _ in
            MainActor.assumeIsolated { heard = commands.rowItems.dropFirst().map(\.title) }
        }
        defer { NotificationCenter.default.removeObserver(listening) }
        await store.lock()
        XCTAssertEqual(commands.rowItems.map(\.title), ["All Items", "", "", "", "", "", "", "", ""])
        XCTAssertEqual(heard, Array(repeating: "", count: 8))
        try await turn()
        XCTAssertEqual(commands.rowItems.map(\.title), ["All Items", "", "", "", "", "", "", "", ""])
        XCTAssertTrue(commands.rowItems.dropFirst().allSatisfy(\.isHidden))
    }

    // MARK: The fold

    func testTheSectionFoldsAndTheNextWindowRemembersThatItDid() async {
        let store = VaultStore(backend: backend())
        let door = Door(store: store, defaults: defaults)
        await store.unlock(password: SecretBytes(DemoVault.password))
        XCTAssertEqual(door.panes?.vaultsFolded, false)
        door.panes?.selectVault(at: 1)
        door.panes?.toggleVaults()
        XCTAssertEqual(door.panes?.vaultsFolded, true)
        // Folded shut over its own selected row, which stays selected.
        XCTAssertEqual(door.panes?.listed.isEmpty, false)

        await store.lock()
        await store.unlock(password: SecretBytes(DemoVault.password))
        XCTAssertEqual(door.panes?.vaultsFolded, true)
        XCTAssertEqual(door.panes?.selection, .allItems)
        // One Bool and no name.
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?.keys.sorted(), [Panes.vaultsFoldedKey])

        door.panes?.toggleVaults()
        XCTAssertEqual(Panes(store: store, defaults: defaults).vaultsFolded, false)
    }

    func testFoldingTheSidebarAwayKeepsItsRowAndItsFold() async throws {
        let store = await unlocked(backend())
        let panes = Panes(store: store)
        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: PanesView(panes: panes))
        window.setContentSize(Metrics.windowSize)
        panes.selectVault(at: 3)
        panes.toggleVaults()
        try await turn()
        XCTAssertFalse(said(in: window.contentView).contains("Dükkan"), "a folded section still draws its vaults")

        panes.toggleSidebar()
        try await turn(Motion.slide.duration * 3)
        panes.toggleSidebar()
        try await turn(Motion.slide.duration * 3)
        XCTAssertEqual(panes.selection, .vault(panes.vaults[3].id))
        XCTAssertTrue(panes.vaultsFolded)
        XCTAssertFalse(said(in: window.contentView).contains("Dükkan"))
        XCTAssertTrue(said(in: window.contentView).contains("Recently Deleted"))
    }

    // MARK: The account's menu

    func testTheMenusSyncAsksTheEngineAndItsLockShutsTheVault() async {
        let fake = backend()
        let store = await unlocked(fake)
        let panes = Panes(store: store)
        XCTAssertEqual(fake.count(of: "sync"), 0)
        await panes.syncNow().value
        XCTAssertEqual(fake.count(of: "sync"), 1)
        await panes.lock().value
        XCTAssertEqual(store.state, .locked)
        XCTAssertFalse(fake.isOpen)
    }
}
