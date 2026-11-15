import AppKit
import XCTest
@testable import OriPass

/// Each reason the vault shuts by itself, driven through notification centres
/// and an idle clock that belong to the test, so nothing here sleeps the Mac.
@MainActor
final class LockPolicyTests: XCTestCase {
    private final class Idle {
        var seconds: TimeInterval = 0
    }

    private struct Rig {
        let backend: FakeBackend
        let store: VaultStore
        let centres: LockPolicy.Centres
        let idle: Idle
        var policy: LockPolicy
        let preferences: Preferences
    }

    private func unlockedRig(_ choices: LockChoices = LockChoices(),
                             checkEvery: TimeInterval = 60) async -> Rig {
        let backend = DemoVault.backend()
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        let centres = LockPolicy.Centres(workspace: NotificationCenter(), distributed: NotificationCenter())
        let idle = Idle()
        let preferences = Preferences()
        preferences.settings.lock = choices
        let policy = LockPolicy(store: store, preferences: preferences, centres: centres,
                                idleSeconds: { idle.seconds }, idleCheckInterval: checkEvery)
        await store.unlock(password: SecretBytes(DemoVault.password))
        return Rig(backend: backend, store: store, centres: centres, idle: idle, policy: policy,
                   preferences: preferences)
    }

    private func settled(_ rig: Rig) async throws {
        for _ in 0..<100 where rig.store.state != .locked {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func sleeps(_ centres: LockPolicy.Centres) {
        centres.workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
    }

    private let conditions: [(LockPolicy.Condition, (LockPolicy.Centres) -> Void)] = [
        (.sleep, { $0.workspace.post(name: NSWorkspace.willSleepNotification, object: nil) }),
        (.screenLocked, { $0.distributed.post(name: .init("com.apple.screenIsLocked"), object: nil) }),
        (.screenSaver, { $0.distributed.post(name: .init("com.apple.screensaver.didstart"), object: nil) }),
        (.userSwitched, { $0.workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil) }),
    ]

    // MARK: Each condition

    func testEachNoticeLocksTheVaultExactlyOnce() async throws {
        for (condition, post) in conditions {
            let rig = await unlockedRig()
            var locks = 0
            let watching = NotificationCenter.default.publisher(for: VaultStore.didLock, object: rig.store)
                .sink { _ in locks += 1 }

            // Twice, because the second can arrive before the first has
            // finished shutting the engine.
            post(rig.centres)
            post(rig.centres)
            try await settled(rig)

            XCTAssertEqual(rig.store.state, .locked, "\(condition) did not lock")
            XCTAssertEqual(locks, 1, "\(condition) locked more than once")
            XCTAssertEqual(rig.backend.count(of: "close"), 1, "\(condition)")
            watching.cancel()
        }
    }

    /// A finger on the sensor and the lid shut straight after: the notice
    /// comes once, while the vault is still opening.
    func testANoticeThatComesWhileTheVaultIsOpeningLocksIt() async throws {
        for (condition, post) in conditions {
            let backend = DemoVault.backend()
            backend.lastSync = Date().addingTimeInterval(-60)
            backend.delay = 0.2
            let store = VaultStore(backend: backend)
            let centres = LockPolicy.Centres(workspace: NotificationCenter(), distributed: NotificationCenter())
            let policy = LockPolicy(store: store, preferences: Preferences(), centres: centres,
                                    idleSeconds: { 0 }, idleCheckInterval: 60)
            let opening = Task { await store.unlock(password: SecretBytes(DemoVault.password)) }
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(store.state, .unlocking)

            post(centres)
            let opened = await opening.value
            try await Task.sleep(nanoseconds: 300_000_000)

            XCTAssertFalse(opened, "\(condition)")
            XCTAssertEqual(store.state, .locked, "\(condition) was heard by nobody and the vault is open")
            XCTAssertFalse(backend.isOpen, "\(condition)")
            XCTAssertFalse(policy.isWatching)
            XCTAssertEqual(Instruments.live.map { "\($0.owner)/\($0.name)" }, [])
        }
    }

    func testASwitchedOffConditionDoesNothing() async throws {
        for (condition, post) in conditions {
            var choices = LockChoices()
            choices.set(condition, to: false)
            let rig = await unlockedRig(choices)

            post(rig.centres)
            try await Task.sleep(nanoseconds: 50_000_000)

            XCTAssertEqual(rig.store.state, .unlocked, "\(condition) locked while switched off")
        }
    }

    func testQuittingLocksAndShutsTheEngine() async {
        let rig = await unlockedRig()

        await rig.policy.willQuit()

        XCTAssertEqual(rig.store.state, .locked)
        XCTAssertEqual(rig.backend.count(of: "close"), 1)
    }

    func testQuittingWithTheSwitchOffLeavesTheVaultAlone() async {
        var choices = LockChoices()
        choices.onQuit = false
        let rig = await unlockedRig(choices)

        await rig.policy.willQuit()

        XCTAssertEqual(rig.store.state, .unlocked)
    }

    // MARK: Idle

    func testNineMinutesIdleDoesNothingAndTenLocks() async throws {
        let rig = await unlockedRig()

        rig.idle.seconds = 9 * 60
        rig.policy.checkIdle()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(rig.store.state, .unlocked)

        rig.idle.seconds = 10 * 60
        rig.policy.checkIdle()
        try await settled(rig)
        XCTAssertEqual(rig.store.state, .locked)
    }

    func testTheMinutesAreANumber() async throws {
        var choices = LockChoices()
        choices.idleMinutes = 2
        let rig = await unlockedRig(choices)
        rig.idle.seconds = 2 * 60

        rig.policy.checkIdle()
        try await settled(rig)

        XCTAssertEqual(rig.store.state, .locked)
    }

    func testIdleSwitchedOffNeverLocksAndHasNoTimer() async throws {
        var choices = LockChoices()
        choices.whenIdle = false
        let rig = await unlockedRig(choices)
        rig.idle.seconds = 3600

        rig.policy.checkIdle()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(rig.store.state, .unlocked)
        XCTAssertTrue(Instruments.live.filter(\.kind.firesByItself).isEmpty)
    }

    /// The timer itself, on a short interval, so the wiring is not only a
    /// method a test calls.
    func testTheTimerAsksTheClockAndLocks() async throws {
        let rig = await unlockedRig(checkEvery: 0.05)
        rig.idle.seconds = 11 * 60

        try await settled(rig)

        XCTAssertEqual(rig.store.state, .locked)
    }

    // MARK: A switch thrown while the vault is open

    func testAConditionSwitchedOffWhileUnlockedStopsLockingAtOnce() async throws {
        for (condition, post) in conditions {
            let rig = await unlockedRig()
            let before = Instruments.live.filter { $0.owner == "Lock" }.count

            rig.preferences.settings.lock.set(condition, to: false)

            XCTAssertEqual(Instruments.live.filter { $0.owner == "Lock" }.count, before - 1, "\(condition)")
            post(rig.centres)
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(rig.store.state, .unlocked, "\(condition) locked after it was switched off")

            rig.preferences.settings.lock.set(condition, to: true)
            post(rig.centres)
            try await settled(rig)
            XCTAssertEqual(rig.store.state, .locked, "\(condition) did not lock after it was switched back on")
        }
    }

    func testTheIdleSwitchAndItsMinutesAreFollowedWhileUnlocked() async throws {
        let rig = await unlockedRig()
        rig.idle.seconds = 3 * 60

        rig.preferences.settings.lock.whenIdle = false
        XCTAssertTrue(Instruments.live.filter(\.kind.firesByItself).isEmpty, "the timer went with the switch")
        rig.preferences.settings.lock.idleMinutes = 2
        rig.policy.checkIdle()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(rig.store.state, .unlocked)

        rig.preferences.settings.lock.whenIdle = true
        XCTAssertEqual(Instruments.live.filter(\.kind.firesByItself).map(\.name), ["idle"])
        rig.policy.checkIdle()
        try await settled(rig)
        XCTAssertEqual(rig.store.state, .locked)
    }

    func testAChoiceMadeWhileLockedStartsNothingAndIsTheOneTheNextUnlockHas() async throws {
        let rig = await unlockedRig()
        await rig.store.lock()

        rig.preferences.settings.lock.onSleep = false
        XCTAssertEqual(Instruments.live.map { "\($0.owner)/\($0.name)" }, [])

        await rig.store.unlock(password: SecretBytes(DemoVault.password))
        sleeps(rig.centres)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(rig.store.state, .unlocked)
    }

    func testQuittingReadsTheSwitchAsItStandsNow() async {
        let rig = await unlockedRig()
        rig.preferences.settings.lock.onQuit = false

        await rig.policy.willQuit()

        XCTAssertEqual(rig.store.state, .unlocked)
    }

    /// The switch decides whether the engine is told to go. What was copied
    /// and what a preview was reading go at every quit, since the ninety
    /// seconds and the lock that would have taken them die with the process.
    func testQuittingWithTheSwitchOffStillTakesTheCopyAndThePreviewsFile() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("oripass-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oripass-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let preview = RememberingPreview()
        let desk = AttachmentDesk(copies: OpenCopies(directory: directory), stage: preview)

        let backend = DemoVault.backend()
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        let preferences = Preferences()
        preferences.settings.lock.onQuit = false
        let door = Door(store: store, preferences: preferences, clipboard: Clipboard(pasteboard: pasteboard),
                        desk: desk)
        let policy = LockPolicy(store: store, preferences: preferences,
                                centres: .init(workspace: NotificationCenter(), distributed: NotificationCenter()))
        await store.unlock(password: SecretBytes(DemoVault.password))

        door.clipboard.copy("CANARY-1")
        let copy = try desk.copies.place(for: "licence.txt")
        try Data("CANARY-2".utf8).write(to: copy)
        preview.show(copy, named: "licence.txt", closed: {})

        await door.quit(under: policy)

        XCTAssertNil(pasteboard.string(forType: .string), "the copy outlived the app")
        XCTAssertEqual(desk.copies.held, [], "a decrypted file outlived the app")
        XCTAssertNil(preview.showing)
        XCTAssertEqual(store.state, .unlocked, "the switch is off, so the engine was not told to go")
        XCTAssertEqual(backend.count(of: "close"), 0)
    }

    /// ⌘S and then ⌘Q with the key still held: the save is on its way to
    /// the engine when the quit comes. The quit waits for the answer.
    func testQuittingWaitsForASaveThatIsStillOut() async throws {
        let backend = DemoVault.backend()
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        let preferences = Preferences()
        let door = Door(store: store, preferences: preferences)
        let policy = LockPolicy(store: store, preferences: preferences,
                                centres: .init(workspace: NotificationCenter(), distributed: NotificationCenter()))
        await store.unlock(password: SecretBytes(DemoVault.password))
        let id = try XCTUnwrap(store.shelves.all.first { !$0.item.favorite }?.id)
        backend.delay = 0.2
        let saving = Task { try? await store.apply(.favourite(true), to: id) }
        try await Task.sleep(nanoseconds: 50_000_000)

        await door.quit(under: policy)
        let saved = await saving.value

        XCTAssertEqual((saved ?? nil)?.favorite, true, "the quit killed the engine under the save")
        XCTAssertEqual(store.state, .locked)
        XCTAssertNil(store.refusal)
    }

    // MARK: Nothing while locked (D18)

    func testNothingOfTheAppsIsLiveWhileLocked() async throws {
        let rig = await unlockedRig()
        let whileOpen = Instruments.live.filter { $0.owner == "Lock" }
        XCTAssertEqual(whileOpen.filter(\.kind.firesByItself).map(\.name), ["idle"],
                       "the one timer an unlocked app has is the auto-lock's")
        XCTAssertEqual(whileOpen.count, 5, "the idle timer and the four notices")

        await rig.store.lock()

        XCTAssertEqual(Instruments.live.map { "\($0.owner)/\($0.name)" }, [])
        XCTAssertFalse(rig.policy.isWatching)
    }

    func testNothingIsLiveBeforeTheFirstUnlockEither() {
        let backend = DemoVault.backend()
        let store = VaultStore(backend: backend)
        let policy = LockPolicy(store: store, centres: .init(workspace: NotificationCenter(),
                                                             distributed: NotificationCenter()))

        XCTAssertTrue(Instruments.live.isEmpty)
        XCTAssertFalse(policy.isWatching)
    }

    func testItWatchesAgainAfterTheNextUnlock() async throws {
        let rig = await unlockedRig()
        await rig.store.lock()
        XCTAssertFalse(rig.policy.isWatching)

        await rig.store.unlock(password: SecretBytes(DemoVault.password))
        XCTAssertTrue(rig.policy.isWatching)
        sleeps(rig.centres)
        try await settled(rig)

        XCTAssertEqual(rig.store.state, .locked)
    }

    func testDroppingThePolicyTakesItsTimerAndObserversWithIt() async {
        var rig: Rig? = await unlockedRig()
        XCTAssertFalse(Instruments.live.isEmpty)

        rig = nil

        XCTAssertTrue(Instruments.live.isEmpty)
        XCTAssertNil(rig)
    }
}

/// The menu items, which are the only part of locking that a person reaches
/// by hand until OP-19 draws the sidebar's menu.
@MainActor
final class LockCommandsTests: XCTestCase {
    private func rig() -> (FakeBackend, VaultStore, Door, LockCommands) {
        let backend = DemoVault.backend()
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        let door = Door(store: store)
        return (backend, store, door, LockCommands(door: door))
    }

    func testLockIsShiftCommandL() throws {
        let (_, _, _, commands) = rig()
        let item = try XCTUnwrap(commands.menu().items.first { $0.title == "Lock" })

        XCTAssertEqual(item.keyEquivalent, "l")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
    }

    func testTheMenuItemLocksAndOnlyWhileUnlocked() async throws {
        let (backend, store, _, commands) = rig()
        let item = try XCTUnwrap(commands.menu().items.first { $0.title == "Lock" })
        XCTAssertFalse(commands.validateMenuItem(item))

        await store.unlock(password: SecretBytes(DemoVault.password))
        XCTAssertTrue(commands.validateMenuItem(item))
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
        for _ in 0..<100 where store.state != .locked { try await Task.sleep(nanoseconds: 10_000_000) }

        XCTAssertEqual(store.state, .locked)
        XCTAssertEqual(backend.count(of: "close"), 1)
        XCTAssertEqual(backend.count(of: "endSession"), 0, "a plain lock only shuts the engine")
    }

    func testLockAndForgetHasTheEngineDropItsSession() async throws {
        let (backend, store, _, commands) = rig()
        await store.unlock(password: SecretBytes(DemoVault.password))
        let item = try XCTUnwrap(commands.menu().items.first { $0.title == "Lock and Forget" })
        XCTAssertTrue(commands.validateMenuItem(item))

        await commands.lockAndForget().value

        XCTAssertEqual(store.state, .locked)
        XCTAssertEqual(backend.count(of: "endSession"), 1)
        XCTAssertFalse(commands.validateMenuItem(item), "nothing to forget once it is done")
    }

    func testTheMenuIsAddedBeforeTheWindowMenu() {
        let (_, _, _, commands) = rig()
        let main = NSMenu()
        for title in ["App", "Edit", "Window", "Help"] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            main.addItem(item)
        }

        commands.install(in: main, before: main.items[2].submenu)

        XCTAssertEqual(main.items.map(\.title), ["App", "Edit", "Vault", "Window", "Help"])
    }
}
