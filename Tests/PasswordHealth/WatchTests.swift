import XCTest
@testable import OriPass

@MainActor
final class WatchTests: XCTestCase {
    /// Twenty characters nobody chose.
    private let random = "v9#Kq2mT!x7RbW4pZs8L"

    private func backend(_ vault: (items: [JSONValue], folders: [JSONValue]) = DemoVault.objects()) -> FakeBackend {
        let backend = FakeBackend(items: vault.items, folders: vault.folders, password: DemoVault.password)
        // Synced a minute ago, so no sync is running behind the count.
        backend.lastSync = Date().addingTimeInterval(-60)
        return backend
    }

    /// The vault open, with Password Health's lists in.
    private func unlocked(_ backend: FakeBackend? = nil) async -> VaultStore {
        let store = VaultStore(backend: backend ?? self.backend())
        await store.unlock(password: SecretBytes(DemoVault.password))
        await store.counting?.value
        return store
    }

    private func item(_ n: Int, type: Int64, _ name: String, _ more: [String: JSONValue]) -> JSONValue {
        let common: [String: JSONValue] = [
            "object": .string("item"), "id": .string("watch-\(n)"), "type": .int(type), "name": .string(name),
            "favorite": .bool(false), "reprompt": .int(0), "notes": .null, "fields": .array([]),
            "creationDate": .string("2025-01-05T09:30:00.000Z"), "revisionDate": .string("2025-03-12T16:41:03.000Z"),
            "deletedDate": .null, "archivedDate": .null,
        ]
        return .object(common.merging(more) { $1 })
    }

    private func login(_ n: Int, _ name: String, password: String?, address: String? = nil,
                       _ more: [String: JSONValue] = [:]) -> JSONValue {
        item(n, type: 1, name, more.merging(["login": .object([
            "username": .string("deniz"), "password": JSONValue(password), "totp": .null,
            "uris": .array(address.map { [.object(["match": .null, "uri": .string($0)])] } ?? []),
        ])]) { $1 })
    }

    private func card(_ n: Int, _ name: String, month: String?, year: String?,
                      _ more: [String: JSONValue] = [:]) -> JSONValue {
        item(n, type: 3, name, more.merging(["card": .object([
            "cardholderName": .string("Deniz Yılmaz"), "brand": .string("Visa"),
            "number": .string(DemoVault.cardNumbers[0]), "expMonth": JSONValue(month),
            "expYear": JSONValue(year), "code": .string(DemoVault.cardCode),
        ])]) { $1 })
    }

    /// Noon on a day of this Mac's own calendar, which is the one a card's
    /// month is read against.
    private func noon(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        let parts = DateComponents(year: year, month: month, day: day, hour: 12)
        return try XCTUnwrap(Calendar(identifier: .gregorian).date(from: parts))
    }

    // MARK: The four lists

    func testTheDemoVaultHasTwoThatShareThreeWeakOneInTheClearAndACard() async throws {
        let store = await unlocked()
        let watch = try XCTUnwrap(store.watch)
        XCTAssertEqual(watch.reused.map(\.item.name), ["Trendyol", "Hepsiburada"])
        XCTAssertEqual(watch.weak.map(\.item.name), ["Eski forum", "Çiçeksepeti", "Yemeksepeti"])
        XCTAssertEqual(watch.unsecured.map(\.item.name), ["Eski forum"])
        XCTAssertEqual(watch.expiring.map(\.item.name), ["Bonus Kart"])
        // They are the store's own items and not copies of them.
        for listed in watch.reused + watch.weak + watch.unsecured + watch.expiring {
            XCTAssertTrue(store.entry(id: listed.id) === listed, listed.item.name)
        }
    }

    func testWhatIsInTheArchiveAndTheTrashIsNotCounted() async throws {
        let archived: [String: JSONValue] = ["archivedDate": .string("2026-01-05T09:30:00.000Z")]
        let deleted: [String: JSONValue] = ["deletedDate": .string("2026-01-05T09:30:00.000Z")]
        let items = [
            login(1, "Kept", password: random),
            login(2, "Archived twin", password: random, archived),
            login(3, "Deleted twin", password: random, deleted),
            login(4, "Archived and weak", password: "password", address: "http://old.example.org", archived),
            login(5, "Deleted and weak", password: "qwerty", address: "http://gone.example.org", deleted),
            card(6, "Archived card", month: "1", year: "2020", archived),
            card(7, "Deleted card", month: "1", year: "2020", deleted),
        ]
        let store = await unlocked(backend((items, [])))
        XCTAssertEqual(store.shelves.archive.count, 3)
        XCTAssertEqual(store.shelves.trash.count, 3)
        let watch = try XCTUnwrap(store.watch)
        XCTAssertEqual(watch.reused.count, 0, "a password shared only with the archive and the trash")
        XCTAssertEqual(watch.weak.count, 0)
        XCTAssertEqual(watch.unsecured.count, 0)
        XCTAssertEqual(watch.expiring.count, 0)

        // Out of the archive, it is counted, and so is the one it shares
        // with.
        try await store.apply(.unarchive, to: "watch-2")
        await store.counting?.value
        XCTAssertEqual(store.watch?.reused.map(\.item.name), ["Kept", "Archived twin"])
    }

    func testThreeThatShareAreAllListedAndALoginWithNoPasswordSharesWithNobody() async throws {
        let items = [
            login(1, "One", password: "Ortak-" + random), login(2, "Alone", password: random),
            login(3, "Two", password: "Ortak-" + random), login(4, "None", password: nil),
            login(5, "Empty", password: ""), login(6, "Three", password: "Ortak-" + random),
            login(7, "Empty too", password: ""), login(8, "Nearly", password: "ortak-" + random),
        ]
        let store = await unlocked(backend((items, [])))
        XCTAssertEqual(store.watch?.reused.map(\.item.name), ["One", "Two", "Three"])
        XCTAssertEqual(store.watch?.weak.count, 0)
    }

    func testOnlyTheBottomTwoLevelsAreWeak() async throws {
        let passwords = ["password", "qwerty123", "Meric2026!", "correct horse battery staple", random]
        let items = passwords.enumerated().map { login($0.offset, "Row \($0.offset)", password: $0.element) }
        let store = await unlocked(backend((items, [])))
        let levels = store.shelves.all.compactMap(\.strength)
        XCTAssertEqual(levels.count, passwords.count)
        let weak = try XCTUnwrap(store.watch?.weak)
        XCTAssertFalse(weak.isEmpty)
        XCTAssertEqual(weak.map(\.id), store.shelves.all.filter { ($0.strength ?? .strong) <= .weak }.map(\.id))
        XCTAssertEqual(Set(weak.compactMap(\.strength)), [.guessable, .weak])
        XCTAssertTrue(levels.contains { $0 > .weak })
    }

    func testAnAddressInTheClearIsFoundAmongOthersAndInAnySpelling() async throws {
        XCTAssertTrue(Watch.isUnsecured("http://forum.example.org/login"))
        XCTAssertTrue(Watch.isUnsecured(" HTTP://Forum.example.org"))
        XCTAssertFalse(Watch.isUnsecured("https://forum.example.org"))
        XCTAssertFalse(Watch.isUnsecured("forum.example.org"))
        XCTAssertFalse(Watch.isUnsecured("httpbin.org"))
        XCTAssertFalse(Watch.isUnsecured("androidapp://org.example.http"))
        XCTAssertFalse(Watch.isUnsecured(""))

        let second = login(1, "Second address", password: random, address: "https://example.org").setting(
            ["login", "uris"], to: .array([
                .object(["match": .null, "uri": .string("https://example.org")]),
                .object(["match": .null, "uri": .string("http://intranet.example.org")]),
            ]))
        let store = await unlocked(backend(([second, login(2, "No address", password: random)], [])))
        XCTAssertEqual(store.watch?.unsecured.map(\.item.name), ["Second address"])
    }

    func testACardIsListedFromTwoMonthsBeforeItsMonthEnds() async throws {
        let items = [
            card(1, "Long gone", month: "4", year: "2023"),
            card(2, "This month", month: "10", year: "2026"),
            card(3, "Next month", month: "11", year: "2026"),
            card(4, "In three months", month: "12", year: "2026"),
            card(5, "Two digits", month: "09", year: "26"),
            card(6, "Two digits, later", month: "09", year: "29"),
            card(7, "No month, this year", month: nil, year: "2026"),
            card(8, "No month, last year", month: nil, year: "2025"),
            card(9, "No year", month: "3", year: nil),
            card(10, "Not a year", month: "3", year: "soon"),
            card(11, "Not a month", month: "13", year: "2025"),
            login(12, "Not a card", password: random),
        ]
        let now = try noon(2026, 10, 9)
        let backend = backend((items, []))
        let store = VaultStore(backend: backend, now: { now })
        backend.lastSync = now.addingTimeInterval(-60)
        await store.unlock(password: SecretBytes(DemoVault.password))
        await store.counting?.value
        XCTAssertEqual(store.watch?.expiring.map(\.item.name),
                       ["Long gone", "This month", "Next month", "Two digits", "No month, last year", "Not a month"])

        // The month after its own is where a card stops, to the day.
        let lapse = try XCTUnwrap(Watch.lapse(month: "12", year: "2026"))
        XCTAssertEqual(Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour], from: lapse),
                       DateComponents(year: 2027, month: 1, day: 1, hour: 0))
        func expiring(on day: Date) -> [String] {
            let listed = store.shelves.all.map { (entry: $0, strength: $0.strength) }
            return Watch(listed, now: day).expiring.map(\.item.name)
        }
        XCTAssertFalse(expiring(on: try noon(2026, 10, 31)).contains("In three months"))
        XCTAssertTrue(expiring(on: try noon(2026, 11, 1)).contains("In three months"))
    }

    func testAWatchSaysNothingOfWhatItHolds() async throws {
        let store = await unlocked()
        let watch = try XCTUnwrap(store.watch)
        XCTAssertEqual("\(watch)", "Watch(2 reused, 3 weak, 1 unsecured, 1 expiring)")
        var dumped = ""
        dump(watch, to: &dumped)
        for words in ["\(watch)", String(describing: watch), String(reflecting: watch), dumped] {
            for canary in DemoVault.canaries + ["Trendyol", "forum.example.org", DemoVault.usernameDomain] {
                XCTAssertFalse(words.contains(canary), words)
            }
        }
    }

    // MARK: The store

    func testTheListsAreMadeOncePerRevisionAndOffTheMainThread() async throws {
        let backend = backend()
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        XCTAssertNil(store.watch, "the lists were made on the main thread, in front of the first row")
        XCTAssertEqual(store.countings, 0)
        await store.counting?.value
        let first = try XCTUnwrap(store.watch)
        XCTAssertEqual(store.countings, 1)
        XCTAssertFalse(first.wasMadeOnMain)
        var revision = store.revision

        // Read as often as anyone likes, they are the ones that were made.
        for _ in 0..<5 { _ = store.watch?.reused.count }
        XCTAssertEqual(store.countings, 1)

        await store.sync()
        await store.counting?.value
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(store.countings, 1, "a sync that changed nothing counted again")

        // One of the two that share is given a password of its own.
        var vault = DemoVault.objects()
        let trendyol = try XCTUnwrap(vault.items.firstIndex { $0["name"]?.string == "Trendyol" })
        vault.items[trendyol] = vault.items[trendyol].setting(["login", "password"], to: .string("password"))
        backend.incoming = vault
        await store.sync()
        XCTAssertEqual(store.revision, revision + 1)
        // The ones before it answer until the new ones are in.
        XCTAssertEqual(store.watch?.reused.count, 2)
        await store.counting?.value
        XCTAssertEqual(store.countings, 2)
        XCTAssertEqual(store.watch?.reused.count, 0)
        // Its new password had its level before it was counted.
        XCTAssertEqual(store.watch?.weak.map(\.item.name), ["Trendyol", "Eski forum", "Çiçeksepeti", "Yemeksepeti"])
        revision = store.revision

        // A change made here is one revision and one count.
        let forum = try XCTUnwrap(store.watch?.unsecured.first)
        try await store.apply(.delete, to: forum.id)
        XCTAssertEqual(store.revision, revision + 1)
        await store.counting?.value
        XCTAssertEqual(store.countings, 3)
        XCTAssertEqual(store.watch?.unsecured.count, 0)
        XCTAssertEqual(store.watch?.weak.map(\.item.name), ["Trendyol", "Çiçeksepeti", "Yemeksepeti"])
    }

    func testNothingIsCountedWhileLockedAndTheListsGoAtTheLock() async throws {
        let backend = backend()
        let store = VaultStore(backend: backend)
        await store.refresh()
        XCTAssertNil(store.counting)
        XCTAssertEqual(store.countings, 0)

        await store.unlock(password: SecretBytes(DemoVault.password))
        await store.counting?.value
        XCTAssertEqual(store.countings, 1)
        weak var held = store.watch?.reused.first
        XCTAssertNotNil(held)

        await store.lock()
        XCTAssertNil(store.watch)
        XCTAssertNil(store.counting)
        XCTAssertNil(held, "Password Health's lists kept an item past the lock")

        // Locked, nothing that would have moved the vault counts anything.
        backend.incoming = DemoVault.objects()
        await store.sync()
        await store.refresh()
        _ = try? await store.apply(.delete, to: "anything")
        XCTAssertNil(store.counting)
        XCTAssertNil(store.watch)
        XCTAssertEqual(store.countings, 1)

        // A wrong password opens nothing and counts nothing.
        await store.unlock(password: SecretBytes("not the password"))
        XCTAssertEqual(store.state, .locked)
        XCTAssertNil(store.counting)
        XCTAssertEqual(store.countings, 1)

        await store.unlock(password: SecretBytes(DemoVault.password))
        await store.counting?.value
        XCTAssertEqual(store.countings, 2)
    }

    func testALockWhileTheListsAreBeingMadeLeavesNone() async throws {
        let store = VaultStore(backend: backend((ScrollTrace.items(), [])))
        await store.unlock(password: SecretBytes(DemoVault.password))
        let making = try XCTUnwrap(store.counting)
        weak var held = store.shelves.all.first
        XCTAssertNotNil(held)
        await store.lock()
        await making.value
        XCTAssertNil(store.watch)
        XCTAssertEqual(store.countings, 0)
        XCTAssertNil(held, "the count kept an item past the lock")
    }

    func testAVaultDeletedLeavesTheListsHoldingTheItemsThatAreThereNow() async throws {
        let store = await unlocked()
        let study = try XCTUnwrap(store.shelves.vaults.first { $0.name == "Çalışma" })
        let work = try XCTUnwrap(store.shelves.vaults.first { $0.name == "İş" })
        // A weak one in each of two folders, so each delete moves one.
        let weak = try XCTUnwrap(store.watch?.weak.map(\.id))
        guard weak.count == 3 else { return XCTFail("the demo vault has \(weak.count) weak passwords") }
        try await store.apply(.move(study.id), to: weak[0])
        try await store.apply(.move(work.id), to: weak[1])
        await store.counting?.value
        let before = store.countings

        try await store.deleteVault(study.id)
        await store.counting?.value
        XCTAssertEqual(store.countings, before + 1)
        let watch = try XCTUnwrap(store.watch)
        XCTAssertEqual(watch.weak.map(\.id), weak)
        for listed in watch.reused + watch.weak + watch.unsecured + watch.expiring {
            XCTAssertTrue(store.entry(id: listed.id) === listed, listed.item.name)
            XCTAssertNotEqual(listed.item.folderID.map(Vault.Place.folder), study.id)
        }
    }
}
