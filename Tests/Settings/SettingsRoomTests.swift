import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import OriPass

/// The settings window: that every field of `Settings` has a room and a
/// control drawn in it, and what the rows that are not a field do. Nothing
/// here asks the system anything: the login item, the two grants and the
/// engine are stand-ins, and Sign Out is done to a fake vault and to
/// folders under the temporary directory.
@MainActor
final class SettingsRoomTests: XCTestCase {
    private var kept: [StandIn] = []
    private var up: [QuickAccess] = []
    private var directories: [URL] = []

    override func tearDown() async throws {
        up.forEach { $0.end() }
        up = []
        kept = []
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
    }

    private func directory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oripass-rooms-\(UUID().uuidString)")
        directories.append(directory)
        return directory
    }

    private struct Rig {
        let backend: FakeBackend
        let store: VaultStore
        let door: Door
        let seal: PasswordSeal
        let enclave: FakeEnclave
        let login: FakeLoginItem
        let access: FakeAccessibility
        let automation: FakeAutomation
        let rooms: Rooms
        let opened: () -> [URL]
    }

    private func rig(accountFiles: [URL] = [], refused: [HotKeyAction: HotKeyRefusal] = [:],
                     engine: BwBinary? = nil) async -> Rig {
        let backend = DemoVault.backend()
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        let enclave = FakeEnclave()
        let seal = PasswordSeal(directory: directory(), enclave: enclave)
        let door = Door(store: store, seal: seal, accountFiles: accountFiles)
        let login = FakeLoginItem()
        let access = FakeAccessibility(isTrusted: false)
        let automation = FakeAutomation([.safari: .allowed, .brave: .refused])
        var opened: [URL] = []
        let rooms = Rooms(door: door, hands: .init(loginItem: login, access: access, automation: automation,
                                                   refusedKeys: { refused }, engine: { engine },
                                                   open: { opened.append($0) }))
        return Rig(backend: backend, store: store, door: door, seal: seal, enclave: enclave, login: login,
                   access: access, automation: automation, rooms: rooms, opened: { opened })
    }

    private func host(_ rooms: Rooms) -> NSWindow {
        let window = SettingsWindow.make()
        window.contentView = NSHostingView(rootView: RoomsView(rooms: rooms))
        window.setContentSize(CGSize(width: Metrics.settingsWindow.width, height: Metrics.settingsWindow.height * 3))
        window.layoutIfNeeded()
        return window
    }

    private func turn() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    // MARK: Every field

    func testEveryFieldHasARoom() async throws {
        let fields = SettingsTests.fields()
        XCTAssertEqual(fields.count, 34)
        let roomed = Room.allCases.flatMap(\.fields)
        XCTAssertEqual(Set(roomed).count, roomed.count, "a field is in two rooms")
        XCTAssertEqual(Set(roomed + Room.setInTheList + Room.setOnTheCard), Set(fields),
                       "a field with no room, or a room for a field there is not")
        XCTAssertEqual(Room.setInTheList, ["list.sort", "list.isReversed", "list.category"],
                       "only the item list's own three are chosen somewhere else")
        XCTAssertEqual(Room.setOnTheCard, ["browser.allowed", "browser.denied", "browser.neverSave"],
                       "only what the card and the toast write is written anywhere but a control")

        // And the room draws a control under each name it gives.
        let rig = await rig()
        await rig.store.unlock(password: SecretBytes(DemoVault.password))
        for room in Room.allCases {
            rig.rooms.room = room
            let window = host(rig.rooms)
            let drawn = Set(said(in: window.contentView, keys: ["accessibilityIdentifier"]))
            for field in room.fields {
                XCTAssertTrue(drawn.contains(field), "\(room.title) draws nothing for \(field)")
            }
            let others = Set(fields).subtracting(room.fields)
            XCTAssertTrue(drawn.isDisjoint(with: others), "\(room.title) draws \(drawn.intersection(others))")
            XCTAssertTrue(said(in: window.contentView).contains(room.title))
        }
    }

    func testWhatASegmentOffersIncludesTheDefault() {
        let fresh = Settings()
        XCTAssertTrue(Room.fingerDays.contains(fresh.lock.fingerDays))
        XCTAssertTrue(Room.idleMinutes.contains(fresh.lock.idleMinutes))
        XCTAssertTrue(Room.clearSeconds.contains(fresh.clipboard.clearSeconds))
        XCTAssertEqual(LockPolicy.Condition.rooms.map(\.condition), LockPolicy.Condition.allCases)
        for row in LockPolicy.Condition.rooms {
            XCTAssertTrue(Room.security.fields.contains(row.field))
        }
    }

    // MARK: General

    func testOpenAtLoginAsksTheSystemAndSaysSoWhenItWillNot() async {
        let rig = await rig()
        XCTAssertFalse(rig.rooms.startsAtLogin)

        rig.rooms.setStartsAtLogin(true)
        XCTAssertEqual(rig.login.asked, [true])
        XCTAssertTrue(rig.rooms.startsAtLogin)
        XCTAssertNil(rig.rooms.loginProblem)

        rig.login.refuses = true
        rig.rooms.setStartsAtLogin(false)
        XCTAssertTrue(rig.rooms.startsAtLogin, "the switch says what the system holds, not what was asked")
        XCTAssertNotNil(rig.rooms.loginProblem)
        XCTAssertFalse(SettingsTests.fields().contains { $0.localizedCaseInsensitiveContains("login") },
                       "the system keeps it, and the settings do not")
    }

    func testAKeyTheRulesRefuseIsSaidAndNotWritten() async {
        let rig = await rig()
        let before = rig.rooms.preferences.settings.shortcuts

        rig.rooms.record(HotKey(key: UInt32(kVK_ANSI_C), carbon: UInt32(cmdKey)), for: .showApp)
        XCTAssertEqual(rig.rooms.keyProblems[.showApp], HotKeyRefusal.reserved("⌘C").words)
        XCTAssertEqual(rig.rooms.preferences.settings.shortcuts, before)

        // Lock's own key, for another action.
        rig.rooms.record(HotKeyAction.lock.fallback!, for: .showApp)
        XCTAssertEqual(rig.rooms.keyProblems[.showApp], HotKeyRefusal.taken(.lock).words)
        XCTAssertNil(rig.rooms.key(for: .showApp))
    }

    func testAKeyThatIsTakenIsWrittenAndCanBeTakenAwayAndPutBack() async {
        let rig = await rig()
        let key = HotKey(key: UInt32(kVK_ANSI_O), carbon: UInt32(controlKey | optionKey))

        rig.rooms.record(HotKeyAction.lock.fallback!, for: .showApp)
        rig.rooms.record(key, for: .showApp)
        XCTAssertNil(rig.rooms.keyProblems[.showApp], "a key that was taken clears what was said of the last")
        XCTAssertEqual(rig.rooms.key(for: .showApp), key)
        XCTAssertEqual(rig.rooms.preferences.settings.shortcuts.all[.showApp], key)
        XCTAssertTrue(rig.rooms.isChanged(.showApp))

        rig.rooms.clear(.quickAccess)
        XCTAssertNil(rig.rooms.key(for: .quickAccess))
        XCTAssertTrue(rig.rooms.isChanged(.quickAccess))
        rig.rooms.reset(.quickAccess)
        XCTAssertEqual(rig.rooms.key(for: .quickAccess), HotKeyAction.quickAccess.fallback)
        XCTAssertFalse(rig.rooms.isChanged(.quickAccess))
    }

    func testAKeyAnotherAppHoldsIsWrittenAndSaidToBeHeld() async {
        let rig = await rig(refused: [.showApp: .systemRefused(-9878)])
        let key = HotKey(key: UInt32(kVK_ANSI_O), carbon: UInt32(controlKey | optionKey))

        rig.rooms.record(key, for: .showApp)
        XCTAssertEqual(rig.rooms.key(for: .showApp), key)
        XCTAssertEqual(rig.rooms.keyProblems[.showApp], HotKeyRefusal.systemRefused(-9878).words)
    }

    /// The whole road: the recorder's key, the settings, `Following`, Carbon
    /// and back. The key is one no keyboard has, and is given back.
    func testARecordedKeyIsRegisteredWithoutARelaunch() async throws {
        let backend = DemoVault.backend()
        let door = Door(store: VaultStore(backend: backend))
        let keys = HotKeys()
        defer { keys.unregisterAll() }
        let following = Following(door.preferences, hands: .init(applyKeys: { keys.apply($0.filter { $0.key == .showApp }) }))
        let rooms = Rooms(door: door, hands: .init(refusedKeys: { keys.refused }))
        let key = HotKey(key: UInt32(kVK_F16), carbon: UInt32(controlKey | optionKey | shiftKey | cmdKey))

        rooms.record(key, for: .showApp)
        XCTAssertEqual(keys.bound[.showApp], key)
        XCTAssertNil(rooms.keyProblems[.showApp])

        rooms.clear(.showApp)
        XCTAssertNil(keys.bound[.showApp])
        withExtendedLifetime(following) {}
    }

    // MARK: Appearance

    func testTheSizeIsTheDoorsAndIsRemembered() async {
        let rig = await rig()
        defer { rig.door.zoom(to: .actual, remembering: false) }
        rig.rooms.room = .appearance
        let window = host(rig.rooms)
        XCTAssertTrue(said(in: window.contentView).contains("Size: Large"))

        rig.door.zoom(to: .large)
        XCTAssertEqual(rig.rooms.preferences.settings.look.zoom, .large)
        XCTAssertEqual(Metrics.zoom, Zoom.large.factor)
    }

    /// The theme is `NSApp.appearance`, and a window with none of its own
    /// takes it: the main one, the settings and the panel of Quick Access.
    /// The app's is put back as it was.
    func testEveryWindowTheAppMakesTakesTheAppsAppearance() {
        let was = NSApp.appearance
        defer { NSApp.appearance = was }
        let windows = [MainWindow.make(), SettingsWindow.make(), QuickPanel(size: Metrics.quickShot)]
        for theme in [Theme.dark, .light] {
            NSApp.appearance = theme.appearance
            for window in windows {
                XCTAssertNil(window.appearance, "\(type(of: window)) has an appearance of its own")
                XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]),
                               theme == .dark ? .darkAqua : .aqua, "\(type(of: window)) in \(theme)")
            }
        }
    }

    // MARK: Security

    func testTouchIDOffForgetsTheSealAndLocksAndOnWaitsForThePassword() async throws {
        let rig = await rig()
        XCTAssertTrue(rig.rooms.canUseFinger)
        await rig.door.unlock(with: SecretBytes(DemoVault.password)).value
        rig.door.answerFingerOffer(true)
        XCTAssertTrue(rig.door.hasSeal)

        await rig.rooms.setFinger(false).value
        XCTAssertEqual(rig.rooms.preferences.settings.lock.unlockWithFinger, false)
        XCTAssertFalse(rig.door.hasSeal)
        XCTAssertEqual(rig.seal.standing, .none)
        XCTAssertEqual(rig.store.state, .locked)
        XCTAssertEqual(rig.backend.count(of: "endSession"), 1, "the engine drops its session before it goes")

        await rig.rooms.setFinger(true).value
        XCTAssertEqual(rig.rooms.preferences.settings.lock.unlockWithFinger, true)
        XCTAssertFalse(rig.door.hasSeal, "nothing is sealed until a password is typed")
        await rig.door.unlock(with: SecretBytes(DemoVault.password)).value
        XCTAssertTrue(rig.door.hasSeal)
        XCTAssertFalse(rig.door.isOfferingFinger, "and he is not asked what he has just answered")
    }

    func testWithNoFingerTheSwitchIsGreyAndSaysWhy() async {
        let rig = await rig()
        rig.enclave.hasFinger = false
        rig.rooms.room = .security
        XCTAssertFalse(rig.rooms.canUseFinger)
        let words = said(in: host(rig.rooms).contentView)
        XCTAssertTrue(words.contains { $0.contains("no finger to offer") })
    }

    // MARK: Privacy

    func testEachPrivacySwitchSaysWhatItSendsAndToWhom() async {
        let rig = await rig()
        rig.rooms.room = .privacy
        let words = said(in: host(rig.rooms).contentView)
        for sentence in [IconStore.sentence, Breaches.sentence, TwoFactorCheck.sentence] {
            XCTAssertTrue(words.contains(sentence), sentence)
        }
        XCTAssertTrue(IconStore.sentence.contains(BitwardenIcons.host))
        XCTAssertTrue(Breaches.sentence.contains(PwnedRange.host))
        XCTAssertTrue(TwoFactorCheck.sentence.contains(TwoFactorDirectory.host))
        XCTAssertTrue(TwoFactorCheck.sentence.contains("Data sourced from 2FA Directory by 2factorauth"))
    }

    // MARK: Filling

    func testTheDeveloperRoomCopiesTheLineAndSaysWhyNothingListens() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("oripass-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let door = Door(store: VaultStore(backend: DemoVault.backend()), clipboard: Clipboard(pasteboard: pasteboard))
        defer { door.clipboard.clear() }
        var problem: String?
        let rooms = Rooms(door: door, hands: .init(agentProblem: { problem }))

        rooms.copyAgentLine()
        XCTAssertEqual(pasteboard.string(forType: .string), "IdentityAgent ~/.oripass/agent.sock")

        problem = SSHAgent.unopened
        rooms.setAgent(true)
        XCTAssertTrue(door.preferences.settings.ssh.isOn)
        XCTAssertEqual(rooms.agentProblem, SSHAgent.unopened)
    }

    func testTheFillingRoomListsEachExtensionAndTakesItBack() async {
        let allowed = "chrome-extension://allowed/", denied = "chrome-extension://denied/"
        let rig = await rig()
        rig.rooms.room = .filling
        var words = said(in: host(rig.rooms).contentView)
        XCTAssertFalse(words.contains(allowed), "nobody has been answered yet")

        rig.rooms.preferences.settings.browser.inOrion = true
        rig.rooms.preferences.settings.browser.answer(allowed, allowed: true)
        rig.rooms.preferences.settings.browser.answer(denied, allowed: false)
        await turn()
        words = said(in: host(rig.rooms).contentView)
        XCTAssertTrue(words.contains("\(allowed): Allowed"))
        XCTAssertTrue(words.contains("\(denied): Denied"))
        XCTAssertTrue(words.contains("Take Back \(allowed)"))
        XCTAssertTrue(words.contains("Forget \(denied)"))

        rig.rooms.forget(allowed)
        rig.rooms.forget(denied)
        let browser = rig.rooms.preferences.settings.browser
        XCTAssertNil(browser.answer(for: allowed), "the card asks again, and is the only way back in")
        XCTAssertNil(browser.answer(for: denied))
        XCTAssertTrue(browser.inOrion, "taking one back leaves the switch")
    }

    func testTheOrionRowSaysWhenOrionHasNoFolderYet() async {
        var isThere = false
        let store = VaultStore(backend: DemoVault.backend())
        let door = Door(store: store, seal: PasswordSeal(directory: directory(), enclave: FakeEnclave()))
        let rooms = Rooms(door: door, hands: .init(hasOrion: { isThere }))
        rooms.room = .filling
        let looked = said(in: host(rooms).contentView).joined(separator: " ")
        XCTAssertTrue(looked.contains("has not been run on this Mac"), looked)

        isThere = true
        await rooms.look().value
        let again = said(in: host(rooms).contentView).joined(separator: " ")
        XCTAssertTrue(again.contains("Tells Orion where this app's helper is"), again)
    }

    func testTheFillingRoomSaysHowTheGrantsStandAndReadsThemAgain() async {
        let rig = await rig()
        rig.rooms.room = .filling
        await rig.rooms.look().value
        var words = said(in: host(rig.rooms).contentView)
        XCTAssertTrue(words.contains("Not allowed"))
        XCTAssertTrue(words.contains("Safari: Allowed"))
        XCTAssertTrue(words.contains("Brave: Not allowed"))
        XCTAssertTrue(words.contains("Orion: Not open"))

        rig.rooms.openAccessibility()
        rig.rooms.openAutomation()
        XCTAssertEqual(rig.access.opened, 1)
        XCTAssertEqual(rig.access.asked, 0, "the room opens the list and does not put the system's question")
        XCTAssertEqual(rig.automation.opened, 1)

        // He is back from System Settings, and the window is in front again.
        rig.access.isTrusted = true
        rig.automation.grants[.orion] = .notAsked
        await rig.rooms.look().value
        words = said(in: host(rig.rooms).contentView)
        XCTAssertTrue(rig.rooms.isTrusted)
        XCTAssertTrue(words.contains("Orion: Not asked yet"))
    }

    // MARK: Account

    func testTheAccountRoomNamesTheAccountTheServerAndTheEngine() async throws {
        let engine = BwBinary(url: URL(fileURLWithPath: "/opt/homebrew/bin/bw"), version: "2026.9.1")
        let rig = await rig(engine: engine)
        rig.backend.server = "https://vault.example.org"
        await rig.store.unlock(password: SecretBytes(DemoVault.password))
        await rig.store.backgroundSync?.value
        rig.rooms.room = .account
        var words = said(in: host(rig.rooms).contentView)
        XCTAssertTrue(words.contains("Looking…"))

        await rig.rooms.look().value
        words = said(in: host(rig.rooms).contentView)
        XCTAssertTrue(words.contains("demo@oripass.invalid"))
        XCTAssertTrue(words.contains("vault.example.org"))
        XCTAssertTrue(words.contains("/opt/homebrew/bin/bw, 2026.9.1"))
        XCTAssertTrue(words.contains { $0.hasPrefix("Synced") })

        rig.rooms.openWebVault()
        XCTAssertEqual(rig.opened(), [try XCTUnwrap(URL(string: "https://vault.example.org"))])
    }

    func testTheEngineIsLookedForOncePerPath() async {
        var asked = 0
        let door = Door(store: VaultStore(backend: DemoVault.backend()))
        let rooms = Rooms(door: door, hands: .init(engine: {
            asked += 1
            return nil
        }))
        await rooms.look().value
        XCTAssertEqual(asked, 0, "the other rooms do not start a bw")

        rooms.room = .account
        await turn()
        await rooms.looking?.value
        await rooms.look().value
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(rooms.hasLooked)
        XCTAssertTrue(said(in: host(rooms).contentView).contains("Not found"))

        rooms.preferences.settings.engine.bwPath = "/usr/local/bin/bw"
        await rooms.look().value
        XCTAssertEqual(asked, 2)
    }

    func testWithNoServerNamedTheWebVaultIsBitwardensOwn() async {
        let rig = await rig()
        await rig.store.refresh()
        XCTAssertEqual(rig.rooms.server, "bitwarden.com")
        rig.rooms.openWebVault()
        XCTAssertEqual(rig.opened().map(\.absoluteString), [Rooms.webVault])
    }

    func testLockAndForgetDeletesTheSealAndKeepsHisAnswer() async {
        let rig = await rig()
        await rig.door.unlock(with: SecretBytes(DemoVault.password)).value
        rig.door.answerFingerOffer(true)

        await rig.rooms.lockAndForget().value
        XCTAssertEqual(rig.store.state, .locked)
        XCTAssertFalse(rig.door.hasSeal)
        XCTAssertEqual(rig.backend.count(of: "endSession"), 1)
        XCTAssertEqual(rig.rooms.preferences.settings.lock.unlockWithFinger, true, "his answer is kept")
    }

    // MARK: Sign Out

    func testSignOutAsksFirstAndCancelLeavesEverything() async {
        let rig = await rig()
        await rig.door.unlock(with: SecretBytes(DemoVault.password)).value
        rig.door.answerFingerOffer(true)
        rig.rooms.room = .account
        XCTAssertNil(rig.rooms.confirmSignOut(), "nothing is signed out that was not asked about")

        rig.rooms.askToSignOut()
        XCTAssertTrue(rig.rooms.isAskingToSignOut)
        let words = said(in: host(rig.rooms).contentView)
        XCTAssertTrue(words.contains("Sign out of demo@oripass.invalid?"))

        rig.rooms.cancelSignOut()
        XCTAssertFalse(rig.rooms.isAskingToSignOut)
        XCTAssertEqual(rig.store.state, .unlocked)
        XCTAssertTrue(rig.door.hasSeal)
        XCTAssertEqual(rig.backend.count(of: "signOut"), 0)
    }

    func testSignOutLeavesNoSealNoRecentItemAndNoAccount() async throws {
        let icons = directory()
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: icons.appendingPathComponent("example.org.png"))
        let recent = directory().appendingPathExtension("json")
        directories.append(recent)
        let rig = await rig(accountFiles: [icons])
        let recents = Recents(file: recent)
        let quick = QuickAccess(door: rig.door, recents: recents, present: { _ in })
        up.append(quick)
        await rig.door.unlock(with: SecretBytes(DemoVault.password)).value
        rig.door.answerFingerOffer(true)
        recents.use(try XCTUnwrap(rig.store.shelves.all.first?.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertEqual(rig.seal.standing, .ready)
        var locks = 0
        let watch = NotificationCenter.default.addObserver(forName: VaultStore.didLock, object: rig.store,
                                                           queue: nil) { _ in locks += 1 }
        defer { NotificationCenter.default.removeObserver(watch) }

        rig.rooms.askToSignOut()
        await rig.rooms.confirmSignOut()?.value

        XCTAssertEqual(locks, 1, "every window is told, as at any lock")
        XCTAssertNil(rig.door.panes)
        XCTAssertEqual(rig.store.state, .loggedOut)
        XCTAssertNil(rig.store.email)
        XCTAssertEqual(rig.backend.count(of: "endSession"), 1)
        XCTAssertEqual(rig.backend.count(of: "signOut"), 1)
        XCTAssertLessThan(try XCTUnwrap(rig.backend.calls.firstIndex(of: "endSession")),
                          try XCTUnwrap(rig.backend.calls.firstIndex(of: "signOut")))
        XCTAssertEqual(rig.seal.standing, .none)
        XCTAssertFalse(rig.door.hasSeal)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: rig.seal.directory.path), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: icons.path))
        XCTAssertEqual(recents.ids, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertFalse(rig.rooms.isSigningOut)
        XCTAssertFalse(rig.rooms.canSignOut, "there is nobody to sign out")

        rig.rooms.room = .account
        let words = said(in: host(rig.rooms).contentView)
        XCTAssertTrue(words.contains("No account on this Mac"))
        XCTAssertFalse(words.contains("demo@oripass.invalid"))
    }

    /// The engine's half against a stand-in `bw` in a directory of its own:
    /// the command it is sent, and the folder it kept its state in emptied.
    func testSigningOutOfBwRunsLogoutAndEmptiesItsFolder() async throws {
        let standIn = try StandIn(["password": "demo"])
        kept.append(standIn)
        try FileManager.default.createDirectory(at: standIn.data, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: standIn.data.appendingPathComponent("data.json"))
        let backend = ServeBackend(preferredPath: standIn.binary.path, runDirectory: standIn.run,
                                   dataDirectory: standIn.data)
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes("demo"))
        XCTAssertEqual(store.state, .unlocked)
        let pid = try XCTUnwrap(pid_t(String(contentsOf: standIn.run.appendingPathComponent("child.pid"),
                                             encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))

        await store.signOut()

        XCTAssertEqual(store.state, .loggedOut)
        XCTAssertTrue(standIn.arguments.contains(["logout"]))
        XCTAssertFalse(standIn.arguments.joined().contains { $0.contains("demo") }, "no password in an argument")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: standIn.data.path), [])
        let gone = await eventually(within: 3) { !isAlive(pid) }
        XCTAssertTrue(gone, "the child is not left serving an account that has gone")
        XCTAssertEqual(standIn.left, [], "and nothing is left where it ran")
    }

    // MARK: The window and the lock

    func testTheWindowOutlivesALockAndSaysNothingOfTheVault() async throws {
        let rig = await rig()
        await rig.store.unlock(password: SecretBytes(DemoVault.password))
        await rig.store.indexing?.value
        let titles = Set(rig.store.shelves.all.map(\.item.name))
        XCTAssertGreaterThan(titles.count, 10)

        for room in Room.allCases {
            rig.rooms.room = room
            let words = said(in: host(rig.rooms).contentView)
            XCTAssertTrue(titles.isDisjoint(with: words), "\(room.title) names an item")
        }
        await rig.store.lock()
        rig.rooms.room = .account
        let words = said(in: host(rig.rooms).contentView)
        XCTAssertTrue(words.contains("demo@oripass.invalid"), "the lock screen says whose vault it is too")
    }

    func testTheWindowIsMadeOnceAndComesBackOnTheRoomItWasLeftOn() async throws {
        let rig = await rig()
        var presented: [NSWindow] = []
        var willShow = 0, closed = 0
        let commands = SettingsCommands(rooms: rig.rooms, present: { presented.append($0) },
                                        willShow: { willShow += 1 }, didClose: { closed += 1 })
        XCTAssertEqual(KeyTable[.settings].strokes, [Stroke(",", .command)])
        XCTAssertNil(KeyTable[.settings].waits)

        commands.show()
        rig.rooms.room = .privacy
        commands.show()
        XCTAssertEqual(presented.count, 2)
        XCTAssertTrue(presented[0] === presented[1], "one window, shown again")
        XCTAssertEqual(willShow, 2)
        XCTAssertEqual(rig.rooms.room, .privacy)
        XCTAssertFalse(presented[0].isRestorable)
        XCTAssertEqual(presented[0].title, "Settings")

        commands.show(.account)
        XCTAssertEqual(rig.rooms.room, .account)
        rig.rooms.askToSignOut()
        XCTAssertFalse(rig.rooms.isAskingToSignOut, "with no account there is nothing to ask about")
        await rig.store.refresh()
        rig.rooms.askToSignOut()
        XCTAssertTrue(rig.rooms.isAskingToSignOut)
        commands.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertFalse(rig.rooms.isAskingToSignOut, "a question is not left waiting behind a closed window")
        XCTAssertEqual(closed, 1)
    }

    func testTheAccountsMenuAndTheMarksMenuRaiseIt() async throws {
        let rig = await rig()
        var shown = 0
        rig.door.showSettings = { shown += 1 }
        await rig.store.unlock(password: SecretBytes(DemoVault.password))
        let panes = try XCTUnwrap(rig.door.panes)
        try XCTUnwrap(panes.showSettings)()
        XCTAssertEqual(shown, 1)

        let quick = QuickAccess(door: rig.door, present: { _ in })
        up.append(quick)
        let menu = MarkMenu(door: rig.door, quick: quick, lock: LockCommands(door: rig.door), showApp: {},
                            showSettings: { shown += 1 }, quickKey: { nil })
        let item = menu.menu().items[4]
        XCTAssertEqual(item.title, "Settings")
        XCTAssertTrue(item.isEnabled)
        menu.menu().performActionForItem(at: 4)
        XCTAssertEqual(shown, 2)

        await rig.store.lock()
        XCTAssertTrue(menu.menu().items[4].isEnabled, "and with the vault shut")
    }
}
