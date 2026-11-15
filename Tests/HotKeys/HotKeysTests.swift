import AppKit
import Carbon.HIToolbox
import XCTest
@testable import OriPass

/// These go to the real Carbon, for the length of a test, with the keys the
/// app takes. A key that something else on this Mac holds fails the first of
/// them, and the sentence says which.
@MainActor
final class HotKeysTests: XCTestCase {
    private var made: [HotKeys] = []
    private var quicks: [QuickAccess] = []

    override func tearDown() async throws {
        made.forEach { $0.unregisterAll() }
        made = []
        quicks.forEach { $0.end() }
        quicks = []
    }

    private func keys() -> HotKeys {
        let keys = HotKeys()
        made.append(keys)
        return keys
    }

    /// All four, the one with no default on a combination nobody has a
    /// board for.
    private var four: [HotKeyAction: HotKey] {
        var wanted = ShortcutChoices().all
        wanted[.showApp] = HotKey(key: UInt32(kVK_F18), carbon: UInt32(controlKey | optionKey | shiftKey | cmdKey))
        return wanted
    }

    private func hotKeyExists() -> HotKeyRefusal { .systemRefused(OSStatus(eventHotKeyExistsErr)) }

    // MARK: Carbon

    func testTheFourRegisterAndUnregisterAgain() {
        let wanted = four
        XCTAssertEqual(wanted.count, 4)
        let first = keys()
        let refused = first.apply(wanted)
        XCTAssertEqual(refused, [:], HotKeys.report(refused, asked: wanted) ?? "")
        XCTAssertEqual(first.bound, wanted)
        XCTAssertEqual(Instruments.live.filter { $0.owner == "HotKeys" }.map(\.name), ["hot-keys"])

        // Carbon holds them: a second registration, anywhere, is refused.
        let second = keys()
        XCTAssertEqual(second.apply(wanted), Dictionary(uniqueKeysWithValues: wanted.keys.map { ($0, hotKeyExists()) }))
        XCTAssertEqual(second.bound, [:])

        first.unregisterAll()
        XCTAssertEqual(first.bound, [:])
        XCTAssertEqual(Instruments.live.filter { $0.owner == "HotKeys" }.count, 1, "the second's handler, and not the first's")

        // And they are free again, which is what unregistering was for.
        XCTAssertEqual(second.apply(wanted), [:])
        XCTAssertEqual(second.bound, wanted)
        second.unregisterAll()
        XCTAssertEqual(Instruments.live.filter { $0.owner == "HotKeys" }.count, 0)
    }

    func testRegisteringTheSameKeyTwiceReplacesTheFirst() {
        let wanted = four
        let keys = keys()
        XCTAssertEqual(keys.apply(wanted), [:])
        XCTAssertEqual(keys.apply(wanted), [:], "the same key again is not a clash with itself")
        XCTAssertEqual(keys.bound, wanted)

        // One registration stands, not two: letting go once frees the key.
        let moved = HotKey(key: UInt32(kVK_F19), carbon: UInt32(controlKey | optionKey | shiftKey | cmdKey))
        var changed = wanted
        changed[.showApp] = moved
        XCTAssertEqual(keys.apply(changed), [:])
        XCTAssertEqual(keys.bound[.showApp], moved)
        let other = self.keys()
        XCTAssertEqual(other.apply([.showApp: wanted[.showApp]!]), [:], "the key it left is free")
        XCTAssertEqual(other.apply([.showApp: moved]), [.showApp: hotKeyExists()], "the key it moved to is not")
    }

    func testAKeyAnotherAppHoldsIsReportedAndNotLost() {
        // Another registration stands for another app: Carbon cannot tell.
        let holder = keys()
        XCTAssertEqual(holder.apply([.quickAccess: HotKeyAction.quickAccess.fallback!]), [:])
        let app = keys()
        let wanted = ShortcutChoices().all
        let refused = app.apply(wanted)
        XCTAssertEqual(refused, [.quickAccess: hotKeyExists()])
        XCTAssertEqual(app.refused, refused)
        XCTAssertEqual(app.bound.keys.sorted { $0.rawValue < $1.rawValue }, [.fill, .lock],
                       "the others are still taken")
        let sentence = HotKeys.report(refused, asked: wanted)
        XCTAssertEqual(sentence, "⌥⌘\\ for open quick access: Another app has it.")
        XCTAssertNil(HotKeys.report([:], asked: wanted))
    }

    func testAKeyPressedReachesWhoeverWasToldAndSaysHowLateItWas() {
        let keys = keys()
        keys.apply(four)
        var heard: [HotKeyAction] = []
        keys.onFire = { heard.append($0) }
        for action in HotKeyAction.allCases {
            XCTAssertEqual(HotKeys.press(action), noErr)
        }
        XCTAssertEqual(heard, HotKeyAction.allCases)
        let delay = keys.lastDelay
        XCTAssertNotNil(delay)
        XCTAssertLessThan(delay ?? 9, 1, "an event made now is not a second old")
    }

    func testAKeyOfAnotherSignatureIsIgnored() {
        let keys = keys()
        var heard = 0
        keys.onFire = { _ in heard += 1 }
        keys.fire(EventHotKeyID(signature: 1, id: 0))
        keys.fire(EventHotKeyID(signature: 0x4F50_4B59, id: 99))
        XCTAssertEqual(heard, 0)
    }

    // MARK: The rules

    func testTheDefaultsAreTheTwoTheCardNamesAndShowOriPassIsUnset() {
        XCTAssertEqual(ShortcutChoices().all[.quickAccess]?.words, "⌥⌘\\")
        XCTAssertEqual(ShortcutChoices().all[.lock]?.words, "⇧⌘L")
        XCTAssertEqual(ShortcutChoices().all[.fill]?.words, "⌘\\")
        XCTAssertNil(ShortcutChoices().all[.showApp])
        XCTAssertEqual(ShortcutChoices().all.count, 3)
        for (action, key) in ShortcutChoices().all {
            XCTAssertNil(HotKeyRules.refusal(for: key, taken: ShortcutChoices().all, by: action), "\(action)")
        }
    }

    func testTheKeyboardTableAndTheDefaultsAreTheSameKeys() {
        for action in HotKeyAction.allCases {
            guard let command = action.command else {
                XCTAssertNil(action.fallback, "an action with no row of the table has no default")
                continue
            }
            XCTAssertEqual(KeyTable[command].strokes.first?.symbols, action.fallback?.words)
            XCTAssertNil(KeyTable[command].waits)
        }
        XCTAssertEqual(KeyTable[.quickAccess].bound, .hotKey)
    }

    func testACombinationThatWouldBreakTheKeyboardIsRefusedBeforeCarbonIsAsked() {
        func refusal(_ key: Int, _ flags: UInt32, taken: [HotKeyAction: HotKey] = [:]) -> HotKeyRefusal? {
            HotKeyRules.refusal(for: HotKey(key: UInt32(key), carbon: flags), taken: taken, by: .showApp)
        }
        XCTAssertEqual(refusal(kVK_ANSI_J, 0), .notEnoughModifiers)
        XCTAssertEqual(refusal(kVK_ANSI_J, UInt32(cmdKey)), .notEnoughModifiers)
        XCTAssertEqual(refusal(kVK_ANSI_J, UInt32(shiftKey)), .notEnoughModifiers)
        XCTAssertEqual(refusal(kVK_ANSI_C, UInt32(cmdKey)), .reserved("⌘C"))
        XCTAssertEqual(refusal(kVK_ANSI_3, UInt32(cmdKey | shiftKey)), .reserved("⇧⌘3"))
        XCTAssertNil(refusal(kVK_ANSI_J, UInt32(cmdKey | shiftKey)), "command and shift together are enough")
        XCTAssertNil(refusal(kVK_ANSI_J, UInt32(optionKey)))
        XCTAssertNil(refusal(kVK_ANSI_C, UInt32(cmdKey | optionKey)), "⌥⌘C is the one-time code, in this app only")
        let lock = HotKeyAction.lock.fallback!
        XCTAssertEqual(HotKeyRules.refusal(for: lock, taken: [.lock: lock], by: .showApp), .taken(.lock))
        XCTAssertFalse(HotKeyRefusal.notEnoughModifiers.words.isEmpty)
        XCTAssertEqual(HotKeys().apply([.showApp: HotKey(key: UInt32(kVK_ANSI_J), carbon: 0)]),
                       [.showApp: .notEnoughModifiers], "and Carbon is not asked")
    }

    func testAKeyIsWrittenWithItsModifiersInTheMenuBarsOrder() {
        let all = HotKey(key: UInt32(kVK_ANSI_K), carbon: UInt32(cmdKey | shiftKey | optionKey | controlKey))
        XCTAssertEqual(all.words, "⌃⌥⇧⌘K")
        XCTAssertEqual(all.flags, [.command, .shift, .option, .control])
        XCTAssertEqual(HotKey.carbonModifiers(from: all.flags), all.carbon)
        XCTAssertEqual(HotKey(key: 200, carbon: 0).words, "#200")
    }

    // MARK: What each does

    private func demo() async -> VaultStore {
        let backend = DemoVault.backend()
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        return store
    }

    func testQuickAccessOpensAndClosesOnItsKeyAndTheVaultLocksOnItsOwn() async throws {
        let store = await demo()
        let door = Door(store: store)
        let quick = QuickAccess(door: door, present: { _ in })
        quicks.append(quick)
        var shown = 0
        let actions = HotKeyActions(quick: quick, door: door, lock: LockCommands(door: door)) { shown += 1 }

        XCTAssertFalse(quick.isUp)
        actions.perform(.quickAccess)
        XCTAssertTrue(quick.isUp)
        actions.perform(.quickAccess)
        XCTAssertFalse(quick.isUp)

        actions.perform(.showApp)
        XCTAssertEqual(shown, 1)

        XCTAssertEqual(store.state, .unlocked)
        let task = try XCTUnwrap(actions.perform(.lock))
        await task.value
        XCTAssertEqual(store.state, .locked)
        // Locked, the key has nothing to do.
        XCTAssertNil(actions.perform(.lock))
        XCTAssertEqual(store.state, .locked)
    }

    func testTheKeyThroughCarbonOpensTheSamePanel() async {
        let store = await demo()
        let door = Door(store: store)
        let quick = QuickAccess(door: door, present: { _ in })
        quicks.append(quick)
        let actions = HotKeyActions(quick: quick, door: door, lock: LockCommands(door: door)) {}
        let keys = keys()
        keys.onFire = { actions.perform($0) }
        keys.apply(four)
        XCTAssertEqual(HotKeys.press(.quickAccess), noErr)
        XCTAssertTrue(quick.isUp)
        XCTAssertEqual(HotKeys.press(.quickAccess), noErr)
        XCTAssertFalse(quick.isUp)
    }

    // MARK: Locked (D18)

    /// The app as the delegate puts it together, short of its window: the
    /// keys from the real Carbon, the auto-lock, Quick Access and a door.
    func testLockedTheAppKeepsItsHotKeysAndNothingElse() async throws {
        let store = await demo()
        let door = Door(store: store)
        let policy = LockPolicy(store: store, centres: .init(workspace: NotificationCenter(),
                                                             distributed: NotificationCenter()))
        let quick = QuickAccess(door: door, present: { _ in })
        quicks.append(quick)
        let actions = HotKeyActions(quick: quick, door: door, lock: LockCommands(door: door)) {}
        let keys = keys()
        keys.onFire = { actions.perform($0) }
        XCTAssertEqual(keys.apply(four), [:])
        let live = { Instruments.live.map { "\($0.owner)/\($0.name)" } }

        XCTAssertTrue(live().contains("HotKeys/hot-keys"))
        XCTAssertTrue(live().contains("Lock/idle"), "open, the auto-lock's timer is there too")
        XCTAssertEqual(HotKeys.press(.quickAccess), noErr)
        XCTAssertTrue(quick.isUp)

        await store.lock()
        XCTAssertFalse(quick.isUp)
        XCTAssertNil(door.panes)
        XCTAssertEqual(live(), ["HotKeys/hot-keys"], "locked: no timer, and no listener but the keys")
        XCTAssertEqual(keys.bound.count, 4, "and the keys are still held, or none could open it")
        XCTAssertFalse(policy.isWatching)
    }
}

@MainActor
final class HotKeyRecorderTests: XCTestCase {
    private func key(_ code: Int, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                       windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                       isARepeat: false, keyCode: UInt16(code)))
    }

    private func click() throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    func testAClickListensAndTheNextCombinationIsWhatIsRecorded() throws {
        let view = HotKeyRecorderView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        var recorded: [HotKey] = []
        view.onRecord = { recorded.append($0) }
        XCTAssertFalse(view.performKeyEquivalent(with: try key(kVK_ANSI_J, .command)), "not listening, not its key")
        XCTAssertEqual(recorded, [])

        view.mouseDown(with: try click())
        XCTAssertTrue(view.isRecording)
        XCTAssertTrue(view.performKeyEquivalent(with: try key(kVK_ANSI_Backslash, [.command, .option, .capsLock])))
        XCTAssertEqual(recorded, [HotKeyAction.quickAccess.fallback!], "caps lock is not part of a combination")
        XCTAssertFalse(view.isRecording)
    }

    func testEscapeGivesUpAndIsNotRecorded() throws {
        let view = HotKeyRecorderView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        var recorded = 0
        var cancelled = 0
        view.onRecord = { _ in recorded += 1 }
        view.onCancel = { cancelled += 1 }
        view.mouseDown(with: try click())
        view.keyDown(with: try key(kVK_Escape, []))
        XCTAssertEqual(recorded, 0)
        XCTAssertEqual(cancelled, 1)
        XCTAssertFalse(view.isRecording)

        // A second click while listening is also a change of mind.
        view.mouseDown(with: try click())
        view.mouseDown(with: try click())
        XCTAssertEqual(cancelled, 2)
        XCTAssertFalse(view.isRecording)
    }

    func testItDrawsWhatItHoldsAndWhatItIsListeningFor() throws {
        let view = HotKeyRecorderView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        view.words = "⌥⌘\\"
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let at = { (rep: NSBitmapImageRep) in rep.colorAt(x: 4, y: 12) }
        let idle = at(rep)
        view.mouseDown(with: try click())
        let rep2 = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep2)
        XCTAssertNotEqual(idle, at(rep2), "listening is drawn differently")
    }
}
