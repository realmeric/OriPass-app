import Combine
import XCTest
@testable import OriPass

@MainActor
final class VaultStoreTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_790_000_000)

    private func demo() -> (FakeBackend, VaultStore) {
        let backend = DemoVault.backend(now: now)
        backend.now = { [unowned self] in self.now }
        // Synced a minute ago, so no test meets a background sync it did not
        // ask for.
        backend.lastSync = now.addingTimeInterval(-60)
        return (backend, VaultStore(backend: backend, now: { [unowned self] in self.now }))
    }

    private func password() -> SecretBytes { SecretBytes(DemoVault.password) }

    func testLockedToUnlockedToLockedAndNothingIsLeft() async throws {
        let (backend, store) = demo()
        await store.refresh()
        XCTAssertEqual(store.state, .locked)
        XCTAssertEqual(store.email, backend.email)

        let opened = await store.unlock(password: password())
        XCTAssertTrue(opened)
        XCTAssertEqual(store.state, .unlocked)
        XCTAssertEqual(store.shelves.all.count + store.shelves.archive.count + store.shelves.trash.count, 42)
        XCTAssertEqual(store.folders.count, 3)

        weak let taken = store.shelves.all.first
        XCTAssertNotNil(taken)
        let locked = expectation(forNotification: VaultStore.didLock, object: store)
        await store.lock()
        await fulfillment(of: [locked], timeout: 1)

        XCTAssertNil(taken, "an item outlived the lock")
        XCTAssertEqual(store.state, .locked)
        XCTAssertTrue(store.shelves.all.isEmpty)
        XCTAssertTrue(store.shelves.trash.isEmpty)
        XCTAssertTrue(store.folders.isEmpty)
        XCTAssertFalse(backend.isOpen)

        // And the password opens it again, which is the only way in.
        let reopened = await store.unlock(password: password())
        XCTAssertTrue(reopened)
        XCTAssertEqual(store.state, .unlocked)
    }

    // MARK: A lock while the vault is opening

    /// The Lock key, Lock and Forget, a sleep: whatever locks while the
    /// engine is still starting or the lists are still being read is the
    /// last word, and the unlock under it opens nothing.
    func testALockWhileTheVaultIsOpeningIsNotUndoneByTheOpening() async throws {
        // In the engine's start, and in the reading of the lists.
        for moment in [0.05, 0.3] {
            let (backend, store) = demo()
            backend.delay = 0.2
            var locks = 0
            let watching = NotificationCenter.default.publisher(for: VaultStore.didLock, object: store)
                .sink { _ in locks += 1 }
            let typed = password()
            let opening = Task { await store.unlock(password: typed) }
            try await Task.sleep(nanoseconds: UInt64(moment * 1_000_000_000))
            XCTAssertEqual(store.state, .unlocking, "\(moment)")

            await store.lock()
            XCTAssertEqual(store.state, .locked)
            let opened = await opening.value
            try await Task.sleep(nanoseconds: 300_000_000)

            XCTAssertFalse(opened, "the unlock said it opened the vault, \(moment) s in")
            XCTAssertEqual(store.state, .locked, "the vault opened behind the lock, \(moment) s in")
            XCTAssertTrue(store.shelves.all.isEmpty)
            XCTAssertFalse(backend.isOpen, "the engine was left open")
            XCTAssertNil(store.refusal, "a lock of his own says nothing")
            XCTAssertEqual(locks, 1)
            XCTAssertTrue(typed.isWiped)
            watching.cancel()

            backend.delay = 0
            let again = await store.unlock(password: password())
            XCTAssertTrue(again, "and the password opens it afterwards")
            await store.lock()
        }
    }

    /// Asked at launch with no child serving, the status is a whole `bw`
    /// run, and may come back after a password has opened the vault.
    func testAStatusThatComesBackAfterTheVaultOpenedDoesNotShutTheDoorOnIt() async throws {
        let (backend, store) = demo()
        backend.statusDelays = [0.3]
        let asking = Task { await store.refresh() }
        try await Task.sleep(nanoseconds: 50_000_000)
        let opened = await store.unlock(password: password())
        XCTAssertTrue(opened)
        await asking.value

        XCTAssertEqual(store.state, .unlocked, "a late status wrote locked over an open vault")
        XCTAssertFalse(store.shelves.all.isEmpty)
        await store.lock()
    }

    // MARK: A lock while the engine is answering

    /// Lock and Forget asks the engine to end its session, and that
    /// request waits behind a save already sent. The save's answer comes
    /// first, to a store that has been emptied.
    func testAnAnswerThatComesWhileTheEngineIsStillGoingIsFiledNowhere() async throws {
        let (backend, store) = demo()
        await store.unlock(password: password())
        await store.indexing?.value
        let id = try XCTUnwrap(store.shelves.all.first { !$0.item.favorite }?.id)
        backend.delay = 0.1
        backend.goingTakes = 0.5
        let saving = Task { try? await store.apply(.favourite(true), to: id) }
        try await Task.sleep(nanoseconds: 30_000_000)
        let locking = Task { await store.lock(forget: true) }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(backend.count(of: "save"), 1)
        XCTAssertEqual(store.state, .locked, "the lock was not said until the engine had gone")
        XCTAssertTrue(store.shelves.all.isEmpty, "a saved item was put into the emptied store")
        await locking.value
        _ = await saving.value
        await store.indexing?.value
        await store.counting?.value
        XCTAssertTrue(store.shelves.all.isEmpty, "the store is locked and holds an item")
        XCTAssertNil(store.searchIndex, "an index was made over it")
        XCTAssertNil(store.watch)
    }

    /// The same for a sync whose lists were already asked for.
    func testASyncAnsweredWhileTheEngineIsStillGoingFillsNothing() async throws {
        let (backend, store) = demo()
        await store.unlock(password: password())
        await store.backgroundSync?.value
        backend.delay = 0.05
        backend.goingTakes = 0.6
        let syncing = Task { await store.sync() }
        try await Task.sleep(nanoseconds: 20_000_000)
        await store.lock(forget: true)
        await syncing.value
        await store.indexing?.value

        XCTAssertEqual(store.state, .locked)
        XCTAssertTrue(store.shelves.all.isEmpty, "a sync filled the locked store")
        XCTAssertNil(store.searchIndex)
    }

    /// A save that was out when the vault locked went with the engine, and
    /// may or may not have reached the server. The lock screen says so.
    func testALockThatCutsASaveSaysSoOnTheLockScreen() async throws {
        let (backend, store) = demo()
        await store.unlock(password: password())
        let id = try XCTUnwrap(store.shelves.all.first { !$0.item.favorite }?.id)
        backend.delay = 0.2
        let saving = Task { try? await store.apply(.favourite(true), to: id) }
        try await Task.sleep(nanoseconds: 50_000_000)
        await store.lock()
        let saved = await saving.value

        XCTAssertNil(saved ?? nil)
        XCTAssertEqual(store.state, .locked)
        XCTAssertEqual(store.refusal, VaultStore.cutShort, "a change was cut and nothing says so")

        backend.delay = 0
        await store.unlock(password: password())
        XCTAssertNil(store.refusal)
        await store.lock()
        XCTAssertNil(store.refusal, "a lock with nothing out says nothing")
    }

    func testAWrongPasswordLeavesTheDoorShutWithTheSentence() async {
        let (_, store) = demo()
        let wrong = SecretBytes("nope")
        let opened = await store.unlock(password: wrong)
        XCTAssertFalse(opened)
        XCTAssertEqual(store.state, .locked)
        XCTAssertEqual(store.refusal, VaultStore.notThePassword)
        XCTAssertTrue(wrong.isWiped)
    }

    /// A password nobody typed, out of the seal, is refused in a sentence
    /// of its own, and one the engine could not judge is not refused at all.
    func testAKeptPasswordTheEngineRefusesSaysSoAndAnyOtherFailureSaysItsOwn() async {
        let (backend, store) = demo()
        let kept = SecretBytes("the-one-before-it-was-changed")
        let opened = await store.unlock(password: kept, kept: true)
        XCTAssertFalse(opened)
        XCTAssertEqual(store.state, .locked)
        XCTAssertEqual(store.refusal, VaultStore.keptPasswordRefused)
        XCTAssertTrue(kept.isWiped)

        backend.refusal = .timeout
        let failed = await store.unlock(password: password(), kept: true)
        XCTAssertFalse(failed)
        XCTAssertNil(store.refusal)
        guard case .failed = store.state else { return XCTFail("a timeout was drawn as \(store.state)") }
    }

    func testTheOtherStates() async {
        let (backend, store) = demo()
        backend.isLoggedIn = false
        await store.refresh()
        XCTAssertEqual(store.state, .loggedOut)
        await store.unlock(password: password())
        XCTAssertEqual(store.state, .loggedOut)

        backend.isLoggedIn = true
        backend.refusal = .transport
        await store.unlock(password: password())
        XCTAssertEqual(store.state, .failed("The engine stopped answering."))
    }

    func testASyncThatChangesOneItemPublishesOnceAndKeepsTheOthers() async throws {
        let (backend, store) = demo()
        await store.unlock(password: password())
        let before = store.shelves.all
        let target = try XCTUnwrap(before.first { $0.item.name == "Spotify" })

        var vault = DemoVault.objects(now: now)
        let index = try XCTUnwrap(vault.items.firstIndex { $0["id"]?.string == target.id })
        vault.items[index] = vault.items[index].setting(["name"], to: .string("Spotify Family"))
            .setting(["revisionDate"], to: .string(VaultDate.string(now)))
        backend.incoming = vault

        var published = 0
        let watching = store.$revision.dropFirst().sink { _ in published += 1 }
        await store.sync()
        watching.cancel()

        XCTAssertEqual(published, 1)
        let after = store.shelves.all
        XCTAssertEqual(after.count, before.count)
        XCTAssertEqual(zip(before, after).filter { $0 !== $1 }.count, 1)
        XCTAssertEqual(store.entry(id: target.id)?.item.name, "Spotify Family")
        XCTAssertFalse(store.lastSyncFailed)
        XCTAssertEqual(store.lastSync, now)
    }

    func testASyncThatChangesNothingPublishesNothing() async {
        let (_, store) = demo()
        await store.unlock(password: password())
        var published = 0
        let watching = store.$revision.dropFirst().sink { _ in published += 1 }
        await store.sync()
        await store.sync()
        watching.cancel()
        XCTAssertEqual(published, 0)
    }

    func testASyncThatFailsLeavesTheListAndSaysSo() async {
        let (backend, store) = demo()
        await store.unlock(password: password())
        let before = store.shelves.all
        let revision = store.revision

        backend.isOffline = true
        await store.sync()
        XCTAssertTrue(store.lastSyncFailed)
        XCTAssertEqual(store.revision, revision)
        XCTAssertTrue(store.shelves.all.elementsEqual(before, by: ===))

        backend.isOffline = false
        await store.sync()
        XCTAssertFalse(store.lastSyncFailed)
    }

    func testTheShelvesAreComputedOncePerRevision() async {
        let (_, store) = demo()
        // From before the unlock, since the search's index reads the
        // shelves as soon as the items are in.
        let start = store.derivations
        await store.unlock(password: password())
        for _ in 0..<50 {
            _ = store.shelves.all
            _ = store.shelves.favourites
            _ = store.shelves.byFolder[nil]
        }
        XCTAssertEqual(store.derivations - start, 1)

        let shelves = store.shelves
        XCTAssertEqual(shelves.archive.map(\.item.name), ["Arşiv: üniversite"])
        XCTAssertEqual(shelves.trash.map(\.item.name), ["Kapanan hesap"])
        XCTAssertFalse(shelves.all.contains { $0.item.isArchived || $0.item.isInTrash })
        XCTAssertEqual(shelves.favourites.count, 4)
        XCTAssertEqual(shelves.byType[.card]?.count, 3)
        XCTAssertEqual(shelves.byType[.unknown(9)]?.count, 1)
        XCTAssertEqual(shelves.byFolder.values.map(\.count).reduce(0, +), shelves.all.count)
        XCTAssertNotNil(shelves.byFolder[nil])
    }

    func testAnOldSyncIsRefreshedBehindTheUnlockAndAFreshOneIsNot() async {
        let (stale, staleStore) = demo()
        stale.lastSync = now.addingTimeInterval(-6 * 60)
        await staleStore.unlock(password: password())
        XCTAssertEqual(staleStore.state, .unlocked, "the list does not wait for the server")
        await staleStore.backgroundSync?.value
        XCTAssertEqual(stale.count(of: "sync"), 1)

        let (fresh, freshStore) = demo()
        fresh.lastSync = now.addingTimeInterval(-4 * 60)
        await freshStore.unlock(password: password())
        XCTAssertNil(freshStore.backgroundSync)
        XCTAssertEqual(fresh.count(of: "sync"), 0)
    }

    func testTheEngineDyingLocksTheStore() async {
        let (backend, store) = demo()
        await store.unlock(password: password())
        let locked = expectation(forNotification: VaultStore.didLock, object: store)
        backend.die()
        await fulfillment(of: [locked], timeout: 1)
        XCTAssertEqual(store.state, .locked)
        XCTAssertTrue(store.shelves.all.isEmpty)
    }

    func testLockAndForgetHasTheEngineDropItsSession() async throws {
        let (backend, store) = demo()
        await store.unlock(password: password())
        await store.lock(forget: true)
        XCTAssertEqual(backend.count(of: "endSession"), 1)
        XCTAssertFalse(backend.isOpen)
        XCTAssertEqual(store.state, .locked)
    }
}
