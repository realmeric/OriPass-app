import AppKit
import Carbon.HIToolbox
import XCTest
@testable import OriPass

/// A clock the test winds by hand.
private final class Clock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func wind(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

/// A browser that says it is on whatever page the test last named.
private final class ToldTab: TabAsker {
    var page: String?
    private(set) var asked = 0
    func address(of app: FrontApp) async -> String? {
        asked += 1
        return page
    }
}

/// Open & Fill against a fake default browser and a sink: no address is
/// opened, no key is posted and macOS is asked for nothing.
@MainActor
final class ArmedFillTests: XCTestCase {
    private let orion = FrontApp(pid: 4801, bundleID: "com.kagi.kagimacOS", name: "Orion")
    private let safari = FrontApp(pid: 4802, bundleID: "com.apple.Safari", name: "Safari")
    /// A browser in `Browser.known` that nobody can ask for its tab.
    private let chrome = FrontApp(pid: 4803, bundleID: "com.google.Chrome", name: "Google Chrome")
    private let spotifyPage = "https://accounts.spotify.com/en/login"
    private let laptop = NSRect(x: 0, y: 0, width: 1512, height: 982)

    private var clock: Clock!
    private var sites: FakeSites!
    private var sink: FakeSink!
    private var ground: FakeForeground!
    private var pasteboard: NSPasteboard!
    private var suite: String!
    private var defaults: UserDefaults!
    private var up: [QuickAccess] = []
    /// What the panel is told is in front, which a test changes.
    private var inFront: FrontApp?
    /// The page the browser in front says it is on: Spotify's sign-in,
    /// which is where the arming sent it, until a test says otherwise.
    private var tab: ToldTab!

    override func setUp() {
        clock = Clock()
        tab = ToldTab()
        tab.page = spotifyPage
        sites = FakeSites(browser: orion.bundleID)
        sink = FakeSink()
        ground = FakeForeground(frontPID: orion.pid)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("oripass-test-\(UUID().uuidString)"))
        suite = "oripass-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        up.forEach { $0.end() }
        up = []
        pasteboard.releaseGlobally()
        pasteboard = nil
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }

    /// The demo's vault, with `nameless` left without its username.
    private func store(with more: [JSONValue] = [], nameless: String? = nil) async -> VaultStore {
        let vault = DemoVault.objects()
        let items = vault.items.map { $0["name"]?.string == nameless ? $0.setting(["login", "username"], to: .null) : $0 }
        let backend = FakeBackend(items: items + more, folders: vault.folders, password: DemoVault.password)
        backend.lastSync = clock.date.addingTimeInterval(-60)
        let store = VaultStore(backend: backend, now: { [clock] in clock!.date })
        await store.unlock(password: SecretBytes(DemoVault.password))
        await store.indexing?.value
        return store
    }

    /// Quick Access over `store`, with the front app and the typist the
    /// test names. `armed` is false for a door that has no Open & Fill.
    private func quickAccess(over store: VaultStore, in front: FrontApp?, armed: Bool = true,
                             authoriser: FakeAuthoriser? = nil) -> (quick: QuickAccess, typist: Typist) {
        come(to: front)
        let typist = Typist(access: FakeAccessibility(), ground: ground, sink: sink) { _ in }
        let door = Door(store: store, clipboard: Clipboard(pasteboard: pasteboard),
                        reprompt: authoriser.map { Reprompt(store: store, authoriser: $0) },
                        armedFill: armed ? ArmedFill(sites: sites) : nil)
        let quick = QuickAccess(door: door, recents: Recents(file: nil), front: { [self] in inFront }, tabs: tab, typist: typist,
                                settings: defaults, present: { _ in }, pointer: { .zero },
                                screens: { [self] in [laptop] })
        up.append(quick)
        return (quick, typist)
    }

    /// Another app comes to the front.
    private func come(to app: FrontApp?) {
        inFront = app
        ground.frontPID = app?.pid
    }

    private func login(_ title: String, in store: VaultStore) throws -> Login {
        try XCTUnwrap(store.shelves.all.first { $0.item.name == title }?.item.login, "no \(title)")
    }

    private func typedForm(of title: String, in store: VaultStore) throws -> String {
        let login = try login(title, in: store)
        return try XCTUnwrap(login.username) + "\t" + (try XCTUnwrap(login.password))
    }

    private func key(_ characters: String, _ flags: NSEvent.ModifierFlags, in panel: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                       windowNumber: panel.windowNumber, context: nil, characters: characters,
                                       charactersIgnoringModifiers: characters, isARepeat: false,
                                       keyCode: UInt16(kVK_Return)))
    }

    /// Spotify's address opened from the panel, as ⌥Return does.
    private func armSpotify(_ quick: QuickAccess) throws {
        quick.show()
        quick.query = "spotify"
        XCTAssertTrue(quick.press(try key("\r", .option, in: quick.panel)))
    }

    // MARK: The page it was opened for, and no other

    /// Inside the two minutes he is on another tab of the same browser and
    /// presses the fill's key there.
    func testAnotherPageInTheSameBrowserIsNotTypedIntoAndTheArmingStands() async throws {
        let store = await store()
        let (quick, typist) = quickAccess(over: store, in: orion)
        let armed = try XCTUnwrap(quick.door.armedFill)
        try armSpotify(quick)

        tab.page = "https://mail.kanarya.invalid/compose"
        quick.autofill()
        await quick.askingArmed?.value
        await quick.askingTab?.value
        _ = await typist.typing?.value

        XCTAssertEqual(sink.keys, [], "Spotify's login went into another site's page")
        XCTAssertTrue(quick.isUp, "the key is the ordinary one's there, and brings the panel")
        XCTAssertNotNil(armed.armed, "the page it opened is still waiting")
        quick.close()

        // Back on the page it opened, the same key types.
        tab.page = spotifyPage
        quick.autofill()
        await quick.askingArmed?.value
        _ = await typist.typing?.value
        XCTAssertEqual(sink.typed, try typedForm(of: "Spotify", in: store))
        XCTAssertFalse(quick.isUp)
        XCTAssertNil(armed.armed)
    }

    /// A browser that would not say, or one nobody can ask: the login
    /// leads the panel and is typed when he says so, and by nothing else.
    func testABrowserThatDoesNotSayItsPageGetsThePanelLedByTheLoginAndNoKeys() async throws {
        for (browser, page) in [(orion, nil as String?), (orion, "favorites://"), (chrome, spotifyPage)] {
            sink.forget()
            sites.browser = browser.bundleID
            let store = await store()
            let (quick, typist) = quickAccess(over: store, in: browser)
            let armed = try XCTUnwrap(quick.door.armedFill)
            try armSpotify(quick)

            tab.page = page
            quick.autofill()
            await quick.askingArmed?.value
            await quick.askingTab?.value
            _ = await typist.typing?.value

            XCTAssertEqual(sink.keys, [], "\(browser.name) on \(page ?? "nothing")")
            XCTAssertTrue(quick.isUp)
            XCTAssertEqual(quick.rows.first?.item.name, "Spotify")
            XCTAssertNil(armed.armed, "it has done what it could: the login is under his hand")

            XCTAssertTrue(quick.fill(), "⇧Return")
            _ = await typist.typing?.value
            XCTAssertEqual(sink.typed, try typedForm(of: "Spotify", in: store))
        }
    }

    // MARK: Used once, and then gone

    /// The page is filled with no panel on the screen, so a login that is
    /// refused has to bring one up.
    func testAnArmedLoginWithNoUsernameIsNotTypedAndThePanelComesUpToSayWhy() async throws {
        let store = await store(nameless: "Spotify")
        let (quick, typist) = quickAccess(over: store, in: orion)
        let armed = try XCTUnwrap(quick.door.armedFill)
        try armSpotify(quick)
        XCTAssertNotNil(armed.armed)

        quick.autofill()
        // The typing is over by the time the browser's answer can be
        // waited for here, and it is what brings the panel.
        XCTAssertFalse(quick.isUp)
        await quick.askingArmed?.value
        let outcome = await typist.typing?.value
        XCTAssertEqual(outcome, .needsPasswordField)
        XCTAssertEqual(sink.keys, [], "the page's first field is a username's")
        XCTAssertTrue(quick.isUp)
        XCTAssertEqual(quick.notice, .needsPasswordField(in: "Orion"))
        XCTAssertNil(armed.armed, "used, as a fill that typed is")
        XCTAssertNil(pasteboard.string(forType: .string))
        quick.close()

        // With the caret in the page's password field the same login is
        // typed, by the fill he asks for.
        ground.caret = .secure
        try armSpotify(quick)
        quick.autofill()
        await quick.askingArmed?.value
        let second = await typist.typing?.value
        XCTAssertEqual(sink.typed, try XCTUnwrap(try login("Spotify", in: store).password))
        XCTAssertEqual(second, .typed(sink.keys.count))
        XCTAssertFalse(quick.isUp)
    }

    func testArmedAndUsedOnceThenGone() async throws {
        let store = await store()
        let (quick, typist) = quickAccess(over: store, in: orion)
        let armed = try XCTUnwrap(quick.door.armedFill)
        try armSpotify(quick)
        XCTAssertFalse(quick.isUp, "the panel goes with the page opening")
        XCTAssertEqual(sites.opened.map(\.absoluteString), ["https://accounts.spotify.com"])
        XCTAssertNotNil(armed.armed)
        XCTAssertEqual(quick.recents.ids.count, 1)

        quick.autofill()
        await quick.askingArmed?.value
        XCTAssertFalse(quick.isUp, "it fills without the panel, and without asking which")
        _ = await typist.typing?.value
        XCTAssertEqual(sink.typed, try typedForm(of: "Spotify", in: store))
        XCTAssertEqual(sink.pids, [orion.pid])
        XCTAssertNil(armed.armed)
        XCTAssertNil(pasteboard.string(forType: .string), "nothing went through the pasteboard")

        // The second press is the ordinary one: Orion would not say its
        // page here, so it lists what was used last and types nothing.
        sink.forget()
        tab.page = nil
        quick.autofill()
        await quick.askingArmed?.value
        XCTAssertEqual(sink.keys, [])
        XCTAssertTrue(quick.isUp)
    }

    func testTwoMinutesAndItIsGone() async throws {
        let store = await store()
        let (quick, _) = quickAccess(over: store, in: orion)
        let armed = try XCTUnwrap(quick.door.armedFill)
        try armSpotify(quick)
        XCTAssertEqual(ArmedFill.lasts, 120)

        clock.wind(119)
        let stillThere = armed.take(for: orion, at: clock.date)
        XCTAssertNotNil(stillThere, "a second short of two minutes it stands")

        // Armed again, and this time the key comes at two minutes.
        try armSpotify(quick)
        sites.forget()
        clock.wind(120)
        quick.autofill()
        await quick.askingArmed?.value
        XCTAssertEqual(sink.keys, [])
        XCTAssertNil(armed.armed, "the lapse is noticed and dropped")
        XCTAssertTrue(quick.isUp, "and the key is the ordinary one's")
    }

    func testAnotherBrowserInFrontDoesNotUseItAndTheOneItWasOpenedInStillCan() async throws {
        let store = await store()
        let (quick, typist) = quickAccess(over: store, in: safari)
        let armed = try XCTUnwrap(quick.door.armedFill)
        try armSpotify(quick)
        XCTAssertNotNil(armed.armed)

        quick.autofill()
        await quick.askingArmed?.value
        XCTAssertEqual(sink.keys, [])
        XCTAssertNil(typist.typing)
        XCTAssertNotNil(armed.armed, "the page it opened is still waiting in Orion")
        quick.close()

        // Orion comes to the front: the same key now types.
        XCTAssertEqual(armed.armed?.browser, "com.kagi.kagimacos")
        come(to: orion)
        quick.autofill()
        await quick.askingArmed?.value
        _ = await typist.typing?.value
        XCTAssertEqual(sink.typed, try typedForm(of: "Spotify", in: store))
        XCTAssertEqual(sink.pids, [orion.pid])
        XCTAssertNil(armed.armed)
    }

    func testTheBrowserIsTheOneTheAddressWasHandedTo() async throws {
        let store = await store()
        sites.browser = safari.bundleID
        let (quick, typist) = quickAccess(over: store, in: orion)
        try armSpotify(quick)
        quick.autofill()
        await quick.askingArmed?.value
        XCTAssertNil(typist.typing, "armed for Safari, and Orion is in front")
        XCTAssertEqual(sink.keys, [])
        XCTAssertNotNil(quick.door.armedFill?.armed)
    }

    func testNoBrowserThatOpensItArmsNothing() async throws {
        let store = await store()
        sites.browser = nil
        let (quick, _) = quickAccess(over: store, in: orion)
        quick.show()
        quick.query = "spotify"
        XCTAssertFalse(quick.openAndFill(), "nothing took the address")
        XCTAssertNil(quick.door.armedFill?.armed)
        XCTAssertEqual(sites.opened, [])
    }

    func testOpeningAnotherPageReplacesTheArming() async throws {
        let store = await store()
        let (quick, _) = quickAccess(over: store, in: orion)
        try armSpotify(quick)
        let first = quick.door.armedFill?.armed?.item
        quick.show()
        quick.query = "github"
        quick.openAndFill()
        XCTAssertNotEqual(quick.door.armedFill?.armed?.item, first)
        XCTAssertEqual(sites.opened.count, 2)
    }

    // MARK: Which items

    func testTheFirstAddressThatIsWrittenIsTheOneOpenedAndOneWithoutASchemeIsHttps() async throws {
        let template = try XCTUnwrap(DemoVault.objects().items.first { $0["name"]?.string == "Spotify" })
        let item = template
            .setting(["id"], to: .string(UUID().uuidString.lowercased()))
            .setting(["name"], to: .string("Kuzey"))
            .setting(["login", "uris"], to: .array([
                .object(["match": .null, "uri": .string("  ")]),
                .object(["match": .null, "uri": .string("kuzey.example/giris")]),
                .object(["match": .null, "uri": .string("https://baska.example")]),
            ]))
        let store = await store(with: [item])
        let found = try XCTUnwrap(store.shelves.all.first { $0.item.name == "Kuzey" })
        XCTAssertEqual(ArmedFill.address(of: found.item)?.absoluteString, "https://kuzey.example/giris")
    }

    func testNoAddressNoPasswordOrTheTrashIsNothingToOpen() async throws {
        let template = try XCTUnwrap(DemoVault.objects().items.first { $0["name"]?.string == "Spotify" })
        func variant(_ name: String, _ changes: [([String], JSONValue)]) -> JSONValue {
            changes.reduce(template.setting(["id"], to: .string(UUID().uuidString.lowercased()))
                .setting(["name"], to: .string(name))) { $0.setting($1.0, to: $1.1) }
        }
        let store = await store(with: [
            variant("Adressiz", [(["login", "uris"], .array([]))]),
            variant("Parolasiz", [(["login", "password"], .null)]),
            variant("Cop", [(["deletedDate"], .string("2026-10-01T10:00:00.000Z"))]),
            variant("Dosya", [(["login", "uris"], .array([.object(["match": .null, "uri": .string("file:///etc/hosts")])]))]),
        ])
        for title in ["Adressiz", "Parolasiz", "Cop", "Dosya"] {
            let item = try XCTUnwrap(store.shelves.all.first { $0.item.name == title }?.item
                ?? store.shelves.trash.first { $0.item.name == title }?.item, title)
            XCTAssertFalse(ArmedFill.canOpen(item), title)
        }
        let (quick, _) = quickAccess(over: store, in: orion)
        quick.show()
        quick.query = "adressiz"
        XCTAssertFalse(quick.openAndFill(), "and the panel stays")
        XCTAssertTrue(quick.isUp)
        XCTAssertEqual(sites.opened, [])
    }

    // MARK: Quick Access

    func testAnOpenedLoginOffersOpenAndFillBeforeTheFillWithOptionReturn() async throws {
        let store = await store()
        let (quick, _) = quickAccess(over: store, in: orion)
        quick.show()
        quick.query = "spotify"
        quick.openSelected()
        let actions = try XCTUnwrap(quick.opened?.actions)
        let place = try XCTUnwrap(actions.firstIndex { $0.act == .openAndFill })
        XCTAssertEqual(actions[place].name, "Open & Fill")
        XCTAssertEqual(actions[place].keys?.symbols, "⌥Return")
        XCTAssertEqual(actions[place - 1].act, .openWindow)
        XCTAssertEqual(actions[place + 1].act, .fill)
        XCTAssertEqual(actions[place + 2].act, .openInApp)

        quick.perform(actions[place])
        XCTAssertFalse(quick.isUp)
        XCTAssertEqual(sites.opened.count, 1)
        XCTAssertNotNil(quick.door.armedFill?.armed)
    }

    func testWithoutTheArmingNoRowIsOfferedAndTheKeyDoesNothing() async throws {
        let store = await store()
        let (quick, _) = quickAccess(over: store, in: orion, armed: false)
        quick.show()
        quick.query = "spotify"
        XCTAssertFalse(quick.press(try key("\r", .option, in: quick.panel)) && !quick.isUp)
        quick.openSelected()
        XCTAssertFalse(quick.opened?.actions.contains { $0.act == .openAndFill } == true)
        XCTAssertEqual(sites.opened, [])
    }

    func testANoteHasNoOpenAndFillRow() async throws {
        let store = await store()
        let (quick, _) = quickAccess(over: store, in: orion)
        quick.show()
        quick.query = "yazılım"
        XCTAssertNil(quick.rows.first?.item.login)
        quick.openSelected()
        XCTAssertFalse(quick.opened?.actions.contains { $0.act == .openAndFill } == true)
        XCTAssertFalse(quick.openAndFill())
    }

    // MARK: The window

    func testShiftCommandFOpensTheSelectedLoginFromTheItemMenu() async throws {
        let store = await store()
        let door = Door(store: store, defaults: defaults, armedFill: ArmedFill(sites: sites))
        let commands = ItemCommands(door: door) { false }
        let panes = try XCTUnwrap(door.panes)
        let item = try XCTUnwrap(commands.menu().items.first { $0.identifier == KeyTable.name(.openAndFill) })
        XCTAssertEqual(item.keyEquivalent, "f")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertFalse(commands.validateMenuItem(item), "no item chosen")
        XCTAssertFalse(commands.openAndFill())

        let entry = try XCTUnwrap(panes.list.entries.first { $0.item.name == "Spotify" })
        panes.select(item: entry.id)
        XCTAssertTrue(commands.validateMenuItem(item))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(sites.opened.map(\.absoluteString), ["https://accounts.spotify.com"])
        let armed = try XCTUnwrap(door.armedFill?.armed)
        XCTAssertEqual(armed.item, entry.id)
        XCTAssertEqual(armed.until.timeIntervalSince(clock.date), 120, accuracy: 0.001)

        let note = try XCTUnwrap(panes.list.entries.first { $0.item.login == nil })
        panes.select(item: note.id)
        XCTAssertFalse(commands.validateMenuItem(item), "a note has no page")
        XCTAssertTrue(KeyTable.working.contains { $0.id == .openAndFill }, "the sheet lists it now")
    }

    func testAWindowOfOneItemArmsToo() async throws {
        let store = await store()
        let door = Door(store: store, defaults: defaults, armedFill: ArmedFill(sites: sites))
        let panes = try XCTUnwrap(door.panes)
        let entry = try XCTUnwrap(panes.list.entries.first { $0.item.name == "GitHub" })
        let own = panes.pinned(to: entry.id)
        XCTAssertTrue(own.canOpenAndFill)
        XCTAssertTrue(own.openAndFill())
        XCTAssertEqual(sites.opened.map(\.absoluteString), ["https://github.com/login"])
        XCTAssertEqual(door.armedFill?.armed?.item, entry.id)
    }

    func testAPanesWithoutTheArmingOpensNothing() async throws {
        let store = await store()
        let door = Door(store: store, defaults: defaults)
        let panes = try XCTUnwrap(door.panes)
        panes.select(item: panes.list.entries.first { $0.item.name == "Spotify" }?.id)
        XCTAssertFalse(panes.canOpenAndFill)
        XCTAssertFalse(panes.openAndFill())
        XCTAssertEqual(sites.opened, [])
    }

    // MARK: An item that asks, and the lock

    func testAnItemThatAsksIsAskedAtTheFillAndNotAtTheOpening() async throws {
        let store = await store()
        let authoriser = FakeAuthoriser()
        let (quick, typist) = quickAccess(over: store, in: orion, authoriser: authoriser)
        let reprompt = try XCTUnwrap(quick.door.reprompt)
        tab.page = "https://github.com/login"
        quick.show()
        quick.query = "github"
        XCTAssertEqual(quick.rows.first?.item.name, "GitHub")
        XCTAssertTrue(quick.openAndFill())
        XCTAssertEqual(authoriser.asked, [], "a page is not a secret")
        XCTAssertEqual(sites.opened.count, 1)

        authoriser.answer = false
        quick.autofill()
        await quick.askingArmed?.value
        await reprompt.asking?.value
        XCTAssertEqual(authoriser.asked, [.fill])
        XCTAssertNil(typist.typing, "a no types nothing")
        XCTAssertEqual(sink.keys, [])
        XCTAssertNil(quick.door.armedFill?.armed, "and the arming is spent")

        authoriser.answer = true
        quick.show()
        quick.query = "github"
        quick.openAndFill()
        quick.autofill()
        await quick.askingArmed?.value
        await reprompt.asking?.value
        _ = await typist.typing?.value
        XCTAssertEqual(sink.typed, try typedForm(of: "GitHub", in: store))
    }

    func testALockForgetsThePageThatWasOpened() async throws {
        let store = await store()
        let (quick, typist) = quickAccess(over: store, in: orion)
        let armed = try XCTUnwrap(quick.door.armedFill)
        try armSpotify(quick)
        XCTAssertNotNil(armed.armed)
        await store.lock()
        XCTAssertNil(armed.armed)

        await store.unlock(password: SecretBytes(DemoVault.password))
        await store.indexing?.value
        quick.autofill()
        await quick.askingArmed?.value
        XCTAssertNil(typist.typing, "a key after the lock fills nothing for a page opened before it")
        XCTAssertEqual(sink.keys, [])
    }

    func testAnItemThatWentToTheTrashInTheMeantimeIsNotFilled() async throws {
        let store = await store()
        let (quick, typist) = quickAccess(over: store, in: orion)
        try armSpotify(quick)
        let id = try XCTUnwrap(store.shelves.all.first { $0.item.name == "Spotify" }?.id)
        _ = try await store.apply(.delete, to: id)
        await store.indexing?.value
        quick.autofill()
        await quick.askingArmed?.value
        XCTAssertNil(typist.typing)
        XCTAssertEqual(sink.keys, [])
    }

    func testNothingIsKeptAwakeForIt() async throws {
        let store = await store()
        let (quick, _) = quickAccess(over: store, in: orion)
        let held = { Set(Instruments.live.map { "\($0.owner)/\($0.name)" }) }
        let before = held()
        let item = try XCTUnwrap(store.shelves.all.first { $0.item.name == "Spotify" }?.item)
        XCTAssertTrue(try XCTUnwrap(quick.door.armedFill).open(item, at: clock.date))
        XCTAssertEqual(held(), before, "a time to compare against and no timer")
    }

    func testTheKeyTableAndTheSheetKnowTheKey() {
        let row = KeyTable[.openAndFill]
        XCTAssertNil(row.waits)
        XCTAssertEqual(row.strokes, [Stroke("f", [.command, .shift])])
    }
}
