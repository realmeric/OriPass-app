import AppKit
import Carbon.HIToolbox
import XCTest
@testable import OriPass

/// The mark's menu, what a click on it is, and what the app is in the Dock
/// when no window is open. The real mark in the real bar is the tour's
/// (`scripts/canary.sh`): a test that put one there would flash on the
/// screen of whoever ran it.
@MainActor
final class MenuBarTests: XCTestCase {
    private var up: [QuickAccess] = []
    private var kept: [StandIn] = []
    private var suites: [String] = []

    override func tearDown() async throws {
        up.forEach { $0.end() }
        up = []
        suites.forEach { UserDefaults().removePersistentDomain(forName: $0) }
        suites = []
        kept = []
    }

    private func suite() throws -> UserDefaults {
        let name = "com.meric.oripass.tests.\(UUID().uuidString)"
        suites.append(name)
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    private struct Rig {
        let store: VaultStore
        let quick: QuickAccess
        let menu: MarkMenu
        let shown: () -> Int
    }

    private func rig(unlocked: Bool = true, quickKey: HotKey? = HotKeyAction.quickAccess.fallback) async -> Rig {
        let store = VaultStore(backend: DemoVault.backend())
        if unlocked { await store.unlock(password: SecretBytes(DemoVault.password)) }
        let door = Door(store: store)
        let quick = QuickAccess(door: door, present: { _ in })
        up.append(quick)
        var shown = 0
        let menu = MarkMenu(door: door, quick: quick, lock: LockCommands(door: door),
                               showApp: { shown += 1 }, quickKey: { quickKey })
        return Rig(store: store, quick: quick, menu: menu, shown: { shown })
    }

    // MARK: The menu

    func testTheMenuHoldsTheFiveInTheStillsOrder() async {
        let rig = await rig()
        let menu = rig.menu.menu()

        XCTAssertEqual(menu.items.map(\.title), ["Open OriPass", "Open Quick Access", "", "Lock", "Settings", "Quit"])
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertEqual(rig.menu.rows().map(\.title), menu.items.map(\.title), "the shot and the menu are one list")
    }

    func testQuickAccessHasItsKeyBesideItAndOnlyWhileItHasOne() async {
        let held = await rig()
        let item = held.menu.menu().items[1]
        XCTAssertEqual(item.keyEquivalent, "\\")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.option, .command])
        XCTAssertEqual(held.menu.rows()[1].caps, ["⌥", "⌘", "\\"])

        let refused = await rig(quickKey: nil)
        let bare = refused.menu.menu().items[1]
        XCTAssertEqual(bare.keyEquivalent, "")
        XCTAssertEqual(refused.menu.rows()[1].caps, [])
    }

    func testAKeyWithNoLetterIsDrawnAndNotMadeIntoAnEquivalent() {
        let every = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        let function = HotKey(key: UInt32(kVK_F17), carbon: every)
        XCTAssertNil(MarkMenu.stroke(for: function))
        XCTAssertEqual(function.caps, ["⌃", "⌥", "⇧", "⌘", "F17"])
        XCTAssertEqual(function.words, "⌃⌥⇧⌘F17")
        XCTAssertEqual(MarkMenu.stroke(for: HotKeyAction.quickAccess.fallback!),
                       Stroke("\\", [.command, .option]))
    }

    func testLockIsGreyOverAShutVaultAndSettingsIsGreyOnlyWithNoWindowToRaise() async {
        let shut = await rig(unlocked: false)
        XCTAssertFalse(shut.menu.menu().items[3].isEnabled)
        XCTAssertFalse(shut.menu.menu().items[4].isEnabled, "this rig was given nothing to raise")

        let open = await rig()
        XCTAssertTrue(open.menu.menu().items[3].isEnabled)
        // With a window behind it the row is live, locked or not
        // (`SettingsRoomTests`).
    }

    func testEachRowDoesWhatItSays() async {
        let rig = await rig()
        let menu = rig.menu.menu()

        menu.performActionForItem(at: 0)
        XCTAssertEqual(rig.shown(), 1, "Open OriPass shows the window")

        menu.performActionForItem(at: 1)
        XCTAssertTrue(rig.quick.isUp, "Open Quick Access raises the panel")
        menu.performActionForItem(at: 1)
        XCTAssertTrue(rig.quick.isUp, "and a second one does not put it away")

        XCTAssertEqual(rig.store.state, .unlocked)
        menu.performActionForItem(at: 3)
        let locked = await eventually(within: 2) { rig.store.state == .locked }
        XCTAssertTrue(locked, "Lock locks the vault")
    }

    func testAClickOnTheMarkRaisesQuickAccessAndTheNextPutsItAway() async {
        let rig = await rig()
        rig.menu.clickOnMark()
        XCTAssertTrue(rig.quick.isUp)
        rig.menu.clickOnMark()
        XCTAssertFalse(rig.quick.isUp)
    }

    // MARK: Which click

    func testTheRightButtonAndControlOpenTheMenuAndNothingElseDoes() {
        XCTAssertTrue(StatusItem.opensMenu(.rightMouseUp, []))
        XCTAssertTrue(StatusItem.opensMenu(.leftMouseUp, .control))
        XCTAssertTrue(StatusItem.opensMenu(.leftMouseUp, [.control, .shift]))
        XCTAssertFalse(StatusItem.opensMenu(.leftMouseUp, []))
        XCTAssertFalse(StatusItem.opensMenu(.leftMouseUp, [.command, .option]))
        XCTAssertFalse(StatusItem.opensMenu(nil, []), "a click made by code is a plain one")
    }

    func testTheMarkIsATemplateWithHolesWhereTheDotsAre() throws {
        let image = StatusItem.glyph
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: Metrics.menuBarMark, height: Metrics.menuBarMark))

        let scale = 8
        let pixels = Int(Metrics.menuBarMark) * scale
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()

        func alpha(_ x: Double, _ y: Double) -> CGFloat {
            bitmap.colorAt(x: Int(x * Double(pixels)), y: Int(y * Double(pixels)))?.alphaComponent ?? -1
        }
        XCTAssertEqual(alpha(0.1, 0.5), 1, "the pass")
        XCTAssertEqual(alpha(0.5, 0.54), 0, "the middle dot is a hole")
        XCTAssertEqual(alpha(0.5 + 0.22, 0.54), 0, "and so is the one beside it")
        XCTAssertEqual(alpha(0.5, 0.05), 0, "and nothing is drawn outside the pass")
    }

    // MARK: The two switches

    func testBothSwitchesAreOnUntilTheyAreTurnedOff() throws {
        XCTAssertEqual(MenuBarChoices(), MenuBarChoices(showsMark: true, keepsDock: true))
        let defaults = try suite()
        XCTAssertEqual(Preferences(defaults: defaults).settings.menuBar, MenuBarChoices(),
                       "nothing written is the default")

        Preferences(defaults: defaults).settings.menuBar = MenuBarChoices(showsMark: false, keepsDock: false)
        XCTAssertEqual(Preferences(defaults: defaults).settings.menuBar,
                       MenuBarChoices(showsMark: false, keepsDock: false))
        Preferences(defaults: defaults).settings.menuBar.showsMark = true
        XCTAssertEqual(Preferences(defaults: defaults).settings.menuBar,
                       MenuBarChoices(showsMark: true, keepsDock: false))
    }

    func testTheDockIconGoesOnlyWithNoWindowAndTheSwitchOffAndAMarkToReachTheAppBy() {
        let off = MenuBarChoices(showsMark: true, keepsDock: false)
        XCTAssertEqual(Presence.wanted(off, hasWindow: false), .accessory)
        XCTAssertEqual(Presence.wanted(off, hasWindow: true), .regular)
        XCTAssertEqual(Presence.wanted(MenuBarChoices(), hasWindow: false), .regular)
        XCTAssertEqual(Presence.wanted(MenuBarChoices(showsMark: false, keepsDock: false), hasWindow: false),
                       .regular, "no mark and no Dock icon would leave nothing to click")
    }

    func testPresenceAsksTheApplicationOnlyWhenTheAnswerChanges() async throws {
        var choices = MenuBarChoices(showsMark: true, keepsDock: false)
        var open = true
        var asked: [NSApplication.ActivationPolicy] = []
        let presence = Presence(choices: { choices }, hasWindow: { open }, setPolicy: { asked.append($0) })

        presence.update()
        XCTAssertEqual(asked, [], "a window is open and the app is already in the Dock")

        open = false
        presence.update()
        presence.update()
        XCTAssertEqual(asked, [.accessory])

        presence.willShowWindow()
        XCTAssertEqual(asked, [.accessory, .regular])
        open = true
        presence.update()
        XCTAssertEqual(asked.count, 2)

        open = false
        choices.keepsDock = true
        presence.update()
        XCTAssertEqual(asked, [.accessory, .regular], "turning the switch on keeps it")
    }

    func testAWindowThatClosesIsCountedOnceItIsGone() async {
        var open = true
        var asked: [NSApplication.ActivationPolicy] = []
        let presence = Presence(choices: { MenuBarChoices(showsMark: true, keepsDock: false) },
                                hasWindow: { open }, setPolicy: { asked.append($0) })

        presence.windowClosed()
        open = false
        let went = await eventually(within: 1) { asked == [.accessory] }
        XCTAssertTrue(went)

        presence.lastWindowClosed()
        XCTAssertEqual(presence.lastWindowClosings, 1)
    }

    // MARK: Quit

    func testQuitIsTheApplicationsOwnSoItGoesWhereEveryQuitGoes() async {
        let item = await rig().menu.menu().items[5]
        XCTAssertEqual(item.action, #selector(NSApplication.terminate(_:)))
        XCTAssertTrue(item.target === NSApp)
    }

    /// What `AppDelegate.applicationShouldTerminate` waits for when the
    /// application is told to terminate: the child of a vault that is open
    /// is gone when it replies, and not by the watchdog after the process.
    func testQuittingWithTheVaultOpenLeavesNoChildBehind() async throws {
        let standIn = try StandIn(["password": "demo"])
        kept.append(standIn)
        let backend = ServeBackend(preferredPath: standIn.binary.path, runDirectory: standIn.run,
                                   dataDirectory: standIn.data)
        let store = VaultStore(backend: backend)
        let policy = LockPolicy(store: store, centres: .init(workspace: NotificationCenter(),
                                                             distributed: NotificationCenter()))
        await store.unlock(password: SecretBytes("demo"))
        XCTAssertEqual(store.state, .unlocked)
        let pidFile = standIn.run.appendingPathComponent("child.pid")
        let pid = try XCTUnwrap(pid_t(String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertTrue(isAlive(pid), "there is a child to leave behind")

        await policy.willQuit()

        let gone = await eventually(within: 2) { !isAlive(pid) }
        XCTAssertTrue(gone)
        XCTAssertEqual(standIn.left, [], "and nothing is left where it ran")
        XCTAssertEqual(store.state, .locked)
    }
}
