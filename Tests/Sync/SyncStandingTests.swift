import AppKit
import SwiftUI
import XCTest
@testable import OriPass

/// What the foot of the sidebar says, and that it is the store's standing
/// read when the sidebar is drawn.
@MainActor
final class SyncStandingTests: XCTestCase {
    private final class Clock {
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    }

    private func demo(synced ago: TimeInterval?) -> (FakeBackend, VaultStore, Clock) {
        let clock = Clock()
        let backend = DemoVault.backend()
        backend.now = { clock.now }
        backend.lastSync = ago.map { clock.now.addingTimeInterval(-$0) }
        return (backend, VaultStore(backend: backend, now: { clock.now }), clock)
    }

    private func unlock(_ store: VaultStore) async {
        await store.unlock(password: SecretBytes(DemoVault.password))
        await store.backgroundSync?.value
    }

    func testAnAgeIsSaidInTheLargestUnitItFillsAndNeverRoundedUp() {
        let said: [(TimeInterval, String)] = [
            (0, "Synced just now"), (59, "Synced just now"), (-30, "Synced just now"),
            (60, "Synced 1 min ago"), (119, "Synced 1 min ago"), (120, "Synced 2 min ago"),
            (59 * 60 + 59, "Synced 59 min ago"), (3600, "Synced 1 hr ago"), (2 * 3600 - 1, "Synced 1 hr ago"),
            (23 * 3600, "Synced 23 hr ago"), (24 * 3600, "Synced 1 day ago"), (48 * 3600, "Synced 2 days ago"),
            (9 * 24 * 3600, "Synced 9 days ago"),
        ]
        for (age, sentence) in said {
            XCTAssertEqual(SyncStanding.synced(age).sentence, sentence, "\(age)")
        }
        XCTAssertEqual(SyncStanding.offline.sentence, "Offline, showing what this Mac last saw")
        XCTAssertEqual(SyncStanding.syncing.sentence, "Syncing…")
        XCTAssertEqual(SyncStanding.never.sentence, "Not synced yet")
    }

    func testTheAgeIsReadAgainstTheStoresClockWhenItIsAsked() async {
        let (_, store, clock) = demo(synced: 2 * 60)
        await unlock(store)
        XCTAssertEqual(store.standing, .synced(120))

        // Nothing is published as the time goes by: no clock ticks for it.
        var published = 0
        let watching = store.objectWillChange.sink { published += 1 }
        clock.now += 60
        XCTAssertEqual(store.standing, .synced(180))
        XCTAssertEqual(published, 0)

        store.restate()
        watching.cancel()
        XCTAssertEqual(published, 1)
    }

    func testAnAttemptThatFailedIsOfflineUntilOneAnswers() async {
        let (backend, store, clock) = demo(synced: 60)
        await unlock(store)
        let unlocked = clock.now

        backend.isOffline = true
        clock.now += 600
        await store.sync()
        XCTAssertEqual(store.standing, .offline)
        XCTAssertEqual(store.lastAttempt, clock.now)
        XCTAssertEqual(store.lastSync, unlocked.addingTimeInterval(-60), "the last answer is still the old one")

        backend.isOffline = false
        clock.now += 60
        await store.sync()
        XCTAssertEqual(store.standing, .synced(0))
        XCTAssertEqual(store.lastAttempt, clock.now)
    }

    func testAVaultThatBwNeverSyncedAndCannotNowIsOffline() async {
        let (backend, store, _) = demo(synced: nil)
        backend.isOffline = true
        await unlock(store)
        XCTAssertEqual(store.state, .unlocked)
        XCTAssertEqual(store.standing, .offline)
    }

    func testWhileTheServerIsBeingAskedItSaysSoAndTwoAtOnceAreStillOne() async {
        let (backend, store, _) = demo(synced: 60)
        await unlock(store)
        backend.delay = 0.03

        async let first: Void = store.sync()
        async let second: Void = store.sync()
        for _ in 0..<100 where !store.isSyncing { await Task.yield() }
        XCTAssertEqual(store.standing, .syncing)
        _ = await (first, second)

        XCTAssertFalse(store.isSyncing)
        XCTAssertEqual(store.standing, .synced(0))
    }

    func testTheFootIsSaidInTheWindowAndFollowsTheStore() async throws {
        let (backend, store, clock) = demo(synced: 2 * 60)
        await unlock(store)
        // The levels and the index arrive behind the items and draw the
        // window again when they do.
        await store.scoring?.value
        await store.indexing?.value
        let panes = Panes(store: store)
        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: PanesView(panes: panes))
        window.setContentSize(Metrics.windowSize)
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(said(in: window.contentView).contains("Synced 2 min ago"), "\(said(in: window.contentView))")

        // Time alone changes nothing on screen, and a window that comes to
        // the front is drawn again.
        clock.now += 60
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(said(in: window.contentView).contains("Synced 2 min ago"))
        store.restate()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(said(in: window.contentView).contains("Synced 3 min ago"))

        backend.isOffline = true
        await store.sync()
        try await Task.sleep(nanoseconds: 50_000_000)
        let offline = said(in: window.contentView)
        XCTAssertTrue(offline.contains(SyncStanding.offlineSentence), "\(offline)")
        XCTAssertFalse(offline.contains { $0.hasPrefix("Synced") })

        await store.lock()
    }
}
