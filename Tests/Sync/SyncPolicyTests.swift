import AppKit
import SwiftUI
import XCTest
@testable import OriPass

/// When the server is asked without anybody pressing Sync Now, driven
/// through a clock, a notification centre and a list of windows that belong
/// to the test. No window here is ever shown and no half hour is waited.
@MainActor
final class SyncPolicyTests: XCTestCase {
    private final class Clock {
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func pass(_ seconds: TimeInterval) { now += seconds }
    }

    /// The windows the test says can be seen.
    private final class Screen {
        var shown: [NSWindow] = []
    }

    @MainActor
    private struct Rig {
        let backend: FakeBackend
        let store: VaultStore
        let clock: Clock
        let centre: NotificationCenter
        let screen: Screen
        /// One of the vault's, on screen from the start.
        let window: NSWindow
        var policy: SyncPolicy

        var syncs: Int { backend.count(of: "sync") }
    }

    /// Unlocked, with a window on screen, and `bw` last synced `ago`.
    private func rig(synced ago: TimeInterval, every: TimeInterval = SyncPolicy.whileShown,
                     unlocks: Bool = true) async -> Rig {
        let clock = Clock()
        let backend = DemoVault.backend()
        backend.now = { clock.now }
        backend.lastSync = clock.now.addingTimeInterval(-ago)
        let store = VaultStore(backend: backend, now: { clock.now })
        let centre = NotificationCenter()
        let screen = Screen()
        let window = MainWindow.make()
        screen.shown = [window]
        let policy = SyncPolicy(store: store, centre: centre, every: every) { closing in
            screen.shown.contains { $0 !== closing }
        }
        if unlocks {
            await store.unlock(password: SecretBytes(DemoVault.password))
            await store.backgroundSync?.value
        }
        return Rig(backend: backend, store: store, clock: clock, centre: centre, screen: screen,
                   window: window, policy: policy)
    }

    private func comesToFront(_ rig: Rig, _ window: NSWindow? = nil) {
        rig.centre.post(name: NSWindow.didBecomeKeyNotification, object: window ?? rig.window)
    }

    private func occlusionChanges(_ rig: Rig) {
        rig.centre.post(name: NSWindow.didChangeOcclusionStateNotification, object: rig.window)
    }

    private var live: [String] { Instruments.live.filter { $0.owner == "Sync" }.map(\.name) }

    // MARK: A window coming to the front

    func testTenActivationsInAMinuteAreOneSyncAtMost() async {
        // The list was a minute old at the unlock, which asked nothing.
        let rig = await rig(synced: 60)
        XCTAssertEqual(rig.syncs, 0)

        for _ in 0..<10 {
            rig.clock.pass(6)
            comesToFront(rig)
            await rig.policy.asking?.value
        }
        XCTAssertEqual(rig.syncs, 0, "two minutes old is not old")

        rig.clock.pass(4 * 60)
        for _ in 0..<10 {
            rig.clock.pass(6)
            comesToFront(rig)
            await rig.policy.asking?.value
        }
        XCTAssertEqual(rig.syncs, 1)
        XCTAssertEqual(rig.store.standing, .synced(54))
    }

    func testTenActivationsInOneTurnAreOneSync() async {
        let rig = await rig(synced: 60)
        rig.clock.pass(10 * 60)

        for _ in 0..<10 { comesToFront(rig) }
        await rig.policy.asking?.value

        XCTAssertEqual(rig.syncs, 1)
    }

    func testTheUnlocksOwnSyncIsTheOneAndActivationsAddNone() async {
        let rig = await rig(synced: 3600)
        XCTAssertEqual(rig.syncs, 1, "the unlock asked, and the policy did not ask beside it")

        for _ in 0..<10 {
            rig.clock.pass(6)
            comesToFront(rig)
            await rig.policy.asking?.value
        }
        XCTAssertEqual(rig.syncs, 1)
    }

    func testAnActivationThatAsksNothingHasTheFootReadItsAgeAgain() async {
        let rig = await rig(synced: 0)
        var drawn = 0
        let watching = rig.store.objectWillChange.sink { drawn += 1 }
        rig.clock.pass(2 * 60)

        comesToFront(rig)
        await rig.policy.asking?.value
        watching.cancel()

        XCTAssertEqual(rig.syncs, 0)
        XCTAssertEqual(drawn, 1)
        XCTAssertEqual(rig.store.standing.sentence, "Synced 2 min ago")
    }

    func testAPanelComingToTheFrontAsksNothing() async {
        let rig = await rig(synced: 60)
        rig.clock.pass(3600)
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .nonactivatingPanel], backing: .buffered,
                            defer: true)
        let bare = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)

        comesToFront(rig, panel)
        comesToFront(rig, bare)
        await rig.policy.asking?.value

        XCTAssertEqual(rig.syncs, 0)
    }

    // MARK: A window left on screen

    func testThirtyOneMinutesOnScreenAreTwo() async {
        let rig = await rig(synced: 3600)
        let unlocked = rig.clock.now
        XCTAssertEqual(rig.syncs, 1)
        XCTAssertEqual(rig.policy.nextCheck, unlocked.addingTimeInterval(30 * 60))

        rig.clock.pass(29 * 60)
        rig.policy.check()
        await rig.policy.asking?.value
        XCTAssertEqual(rig.syncs, 1, "a timer that fires early asks nothing")
        XCTAssertEqual(rig.policy.nextCheck, unlocked.addingTimeInterval(30 * 60))

        rig.clock.pass(2 * 60)
        rig.policy.check()
        await rig.policy.asking?.value
        XCTAssertEqual(rig.syncs, 2)
        XCTAssertEqual(rig.policy.nextCheck, rig.clock.now.addingTimeInterval(30 * 60))
        XCTAssertEqual(live.filter { $0 == "next" }.count, 1, "one timer, set again and not added to")
    }

    func testSyncNowPutsTheTimerOff() async {
        let rig = await rig(synced: 3600)
        rig.clock.pass(20 * 60)

        await rig.store.sync()

        XCTAssertEqual(rig.policy.nextCheck, rig.clock.now.addingTimeInterval(30 * 60))
        XCTAssertEqual(live.filter { $0 == "next" }.count, 1)
    }

    func testWithNoWindowOnScreenThereIsNoTimerAndNothingIsAsked() async {
        let rig = await rig(synced: 3600)
        XCTAssertTrue(live.contains("next"))

        rig.screen.shown = []
        occlusionChanges(rig)
        XCTAssertNil(rig.policy.nextCheck)
        XCTAssertFalse(live.contains("next"))
        XCTAssertFalse(Instruments.live.contains { $0.owner == "Sync" && $0.kind.firesByItself })

        rig.clock.pass(2 * 3600)
        rig.policy.check()
        await rig.policy.asking?.value
        XCTAssertEqual(rig.syncs, 1)

        // Back on screen behind another app's window, with the half hour
        // long gone.
        rig.screen.shown = [rig.window]
        occlusionChanges(rig)
        await rig.policy.asking?.value
        XCTAssertEqual(rig.syncs, 2)
        XCTAssertEqual(rig.policy.nextCheck, rig.clock.now.addingTimeInterval(30 * 60))
    }

    func testTheTimerDoesNotOutliveTheLastWindowClosing() async {
        let rig = await rig(synced: 3600)
        let other = MainWindow.make()
        rig.screen.shown.append(other)

        // AppKit says it before the window has gone.
        rig.centre.post(name: NSWindow.willCloseNotification, object: other)
        XCTAssertNotNil(rig.policy.nextCheck, "one of two")

        rig.screen.shown = [rig.window]
        rig.centre.post(name: NSWindow.willCloseNotification, object: rig.window)
        XCTAssertNil(rig.policy.nextCheck)
        XCTAssertFalse(live.contains("next"))
    }

    /// The timer itself, on a short interval, so the wiring is not only a
    /// method a test calls.
    func testTheTimerAsksTheClockAndSyncs() async throws {
        let rig = await rig(synced: 0, every: 0.05)
        XCTAssertEqual(rig.syncs, 0)
        rig.clock.pass(0.06)

        for _ in 0..<200 where rig.syncs == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await rig.policy.asking?.value

        XCTAssertEqual(rig.syncs, 1)
    }

    // MARK: Offline

    func testAnAttemptThatFailedCountsAsAnAttempt() async {
        let rig = await rig(synced: 60)
        rig.backend.isOffline = true
        rig.clock.pass(10 * 60)

        for _ in 0..<10 {
            rig.clock.pass(6)
            comesToFront(rig)
            await rig.policy.asking?.value
        }

        XCTAssertEqual(rig.syncs, 1, "a Mac with no network asks as seldom as one with it")
        XCTAssertEqual(rig.store.standing, .offline)
        XCTAssertEqual(rig.policy.nextCheck, rig.clock.now.addingTimeInterval(30 * 60 - 54))

        rig.backend.isOffline = false
        rig.clock.pass(5 * 60)
        comesToFront(rig)
        await rig.policy.asking?.value
        XCTAssertEqual(rig.syncs, 2)
        XCTAssertEqual(rig.store.standing, .synced(0))
    }

    // MARK: Locked (D18)

    func testLockedIsNone() async {
        let rig = await rig(synced: 3600)
        XCTAssertEqual(rig.syncs, 1)
        XCTAssertEqual(Set(live), ["key", "shown", "closing", "next"])

        await rig.store.lock()
        XCTAssertEqual(live, [])
        XCTAssertFalse(rig.policy.isWatching)
        XCTAssertNil(rig.policy.nextCheck)

        rig.clock.pass(2 * 3600)
        for _ in 0..<10 { comesToFront(rig) }
        occlusionChanges(rig)
        rig.policy.check()
        await rig.policy.asking?.value
        rig.store.restate()
        await rig.store.sync()

        XCTAssertEqual(rig.syncs, 1)
        XCTAssertEqual(live, [])
    }

    func testNothingIsLiveBeforeTheFirstUnlockEither() async {
        let rig = await rig(synced: 3600, unlocks: false)

        comesToFront(rig)
        rig.policy.check()
        await rig.policy.asking?.value

        XCTAssertEqual(rig.syncs, 0)
        XCTAssertEqual(live, [])
        XCTAssertNil(rig.policy.nextCheck)
    }

    func testALockWhileTheServerIsBeingAskedLeavesNothing() async throws {
        let rig = await rig(synced: 60)
        rig.clock.pass(10 * 60)
        rig.backend.delay = 0.05

        comesToFront(rig)
        for _ in 0..<100 where !rig.store.isSyncing { await Task.yield() }
        XCTAssertEqual(rig.store.standing, .syncing)
        await rig.store.lock()
        await rig.policy.asking?.value

        XCTAssertEqual(rig.store.state, .locked)
        XCTAssertFalse(rig.store.isSyncing)
        XCTAssertEqual(live, [])
        XCTAssertNil(rig.policy.nextCheck)
    }

    func testItWatchesAgainAfterTheNextUnlock() async {
        let rig = await rig(synced: 60)
        await rig.store.lock()
        rig.clock.pass(2 * 60)

        await rig.store.unlock(password: SecretBytes(DemoVault.password))
        await rig.store.backgroundSync?.value
        XCTAssertTrue(rig.policy.isWatching)
        XCTAssertEqual(rig.syncs, 0)
        XCTAssertEqual(rig.policy.nextCheck, rig.clock.now.addingTimeInterval(27 * 60))

        rig.clock.pass(3 * 60)
        comesToFront(rig)
        await rig.policy.asking?.value
        XCTAssertEqual(rig.syncs, 1)
    }

    func testDroppingThePolicyTakesItsTimerAndObserversWithIt() async {
        var rig: Rig? = await rig(synced: 3600)
        XCTAssertEqual(live.count, 4)

        rig = nil

        XCTAssertEqual(live, [])
        XCTAssertNil(rig)
    }

    // MARK: Which windows

    func testOnlyAWindowWithATitleBarThatIsNoPanelIsTheVaults() {
        XCTAssertTrue(SyncPolicy.isTheVaults(MainWindow.make()))
        XCTAssertFalse(SyncPolicy.isTheVaults(NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered,
                                                      defer: true)))
        XCTAssertFalse(SyncPolicy.isTheVaults(NSWindow(contentRect: .zero, styleMask: .borderless,
                                                       backing: .buffered, defer: true)))
    }

    func testAWindowThatWasNeverShownIsNotOnScreen() {
        let window = MainWindow.make()
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(SyncPolicy.aWindowIsOnScreen(besides: nil))
        _ = window
    }
}
