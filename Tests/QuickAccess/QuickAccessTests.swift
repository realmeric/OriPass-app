import AppKit
import SwiftUI
import XCTest
@testable import OriPass

@MainActor
final class QuickAccessTests: XCTestCase {
    private let laptop = NSRect(x: 0, y: 0, width: 1512, height: 982)
    /// A second display to the left of the first and standing higher.
    private let desk = NSRect(x: -2560, y: 200, width: 2560, height: 1440)

    private var presented = 0
    private var up: [QuickAccess] = []

    override func tearDown() async throws {
        // Ended and not only closed: the panel and its view hold each
        // other, and a test that only closed it would leave a window behind.
        up.forEach { $0.end() }
        up = []
        pasteboards.forEach { $0.releaseGlobally() }
        pasteboards = []
        pasteboard = nil
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        scratch = nil
        watchers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        watchers = []
    }

    private var watchers: [NSObjectProtocol] = []

    /// A panel that is ordered in nowhere, with the pointer on the laptop.
    private func quickAccess(over store: VaultStore? = nil, pointer: CGPoint = CGPoint(x: 700, y: 400)) -> QuickAccess {
        let quick = QuickAccess(door: Door(store: store ?? shut()),
                                present: { [weak self] _ in self?.presented += 1 },
                                pointer: { pointer }, screens: { [self] in [laptop, desk] })
        up.append(quick)
        return quick
    }

    /// A vault nobody has opened.
    private func shut() -> VaultStore {
        VaultStore(backend: FakeBackend(items: [], folders: [], password: "right"))
    }

    /// An empty one, open, which is what the field's own tests want under
    /// them: over a shut one the keys are the password's.
    private func empty() async -> VaultStore {
        let store = shut()
        await store.unlock(password: SecretBytes("right"))
        return store
    }

    private func key(_ code: UInt16, in panel: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: panel.windowNumber, context: nil, characters: "",
                                       charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }

    // MARK: Where it goes

    func testItIsAcrossTheMiddleOfThePointersScreenAThirdOfTheWayDown() {
        let size = CGSize(width: 600, height: 58)
        let onLaptop = QuickPlace.frame(of: size, pointer: CGPoint(x: 10, y: 10), screens: [laptop, desk])
        XCTAssertEqual(onLaptop.midX, laptop.midX)
        XCTAssertEqual(onLaptop.maxY, (laptop.maxY - laptop.height / 3).rounded(), "its top, wherever its foot is")

        let onDesk = QuickPlace.frame(of: size, pointer: CGPoint(x: -100, y: 1500), screens: [laptop, desk])
        XCTAssertEqual(onDesk.midX, desk.midX)
        XCTAssertEqual(onDesk.maxY, desk.maxY - desk.height / 3)

        let tall = QuickPlace.frame(of: CGSize(width: 600, height: 400), pointer: .zero, screens: [laptop, desk])
        XCTAssertEqual(tall.maxY, onLaptop.maxY, "the field does not move when the panel grows")

        let between = QuickPlace.frame(of: size, pointer: CGPoint(x: 5000, y: 5000), screens: [laptop, desk])
        XCTAssertEqual(between, onLaptop, "a pointer on no screen gets the first")
        XCTAssertEqual(QuickPlace.frame(of: size, pointer: .zero, screens: []).size, size)
    }

    // MARK: The panel

    func testThePanelTakesTheKeysAndNothingElse() {
        let quick = quickAccess()
        let panel = quick.panel
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel), "or showing it brings the app forward")
        XCTAssertFalse(panel.styleMask.contains(.titled))
        XCTAssertTrue(panel.canBecomeKey, "or nothing typed would arrive")
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary]))
        XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.floating.rawValue)
        XCTAssertFalse(panel.hidesOnDeactivate, "its app is not the active one when it is used")
        XCTAssertFalse(panel.isRestorable)
        XCTAssertEqual(panel.animationBehavior, .none)
        XCTAssertEqual(panel.frame.size, CGSize(width: 600, height: 58 + 56), "the field, and the lock under it")
        XCTAssertEqual(quick.field?.accessibilityLabel(), "Search")
        XCTAssertTrue(quick.field?.window === panel, "the field is in it before it is ever shown")
    }

    func testItIsMadeOnceAndOnlyShownAndHidden() async {
        let quick = quickAccess(over: await empty(), pointer: CGPoint(x: -100, y: 1500))
        let panel = quick.panel
        let content = panel.contentView
        XCTAssertFalse(quick.isUp)

        quick.toggle()
        XCTAssertTrue(quick.isUp)
        XCTAssertEqual(presented, 1)
        XCTAssertEqual(panel.frame.midX, desk.midX, "on the screen the pointer is on")
        XCTAssertTrue(panel.firstResponder is NSTextView, "the caret is in the field: \(String(describing: panel.firstResponder))")

        quick.toggle()
        XCTAssertFalse(quick.isUp)
        quick.toggle()
        XCTAssertEqual(presented, 2)
        XCTAssertTrue(quick.panel === panel)
        XCTAssertTrue(panel.contentView === content, "the same view, not one built for this showing")
    }

    // MARK: What puts it away

    func testWhatIsTypedIsTheQueryAndEscEmptiesItBeforeItCloses() async throws {
        let quick = quickAccess(over: await empty())
        quick.show()
        let editor = try XCTUnwrap(quick.panel.firstResponder as? NSTextView)
        editor.insertText("banka", replacementRange: editor.selectedRange())
        XCTAssertEqual(quick.query, "banka")

        quick.panel.sendEvent(try key(0, in: quick.panel))
        XCTAssertEqual(quick.query, "banka", "any other key is not Esc")
        quick.panel.sendEvent(try key(53, in: quick.panel))
        XCTAssertEqual(quick.query, "")
        XCTAssertTrue(quick.isUp, "the first Esc is for the field")
        quick.panel.layoutIfNeeded()
        XCTAssertEqual(quick.field?.stringValue, "")

        quick.panel.sendEvent(try key(53, in: quick.panel))
        XCTAssertFalse(quick.isUp)
    }

    func testEscLeavesAWordThatIsStillBeingComposedToTheInputMethod() async throws {
        let quick = quickAccess(over: await empty())
        quick.show()
        let editor = try XCTUnwrap(quick.panel.firstResponder as? NSTextView)
        editor.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: editor.selectedRange())
        XCTAssertTrue(editor.hasMarkedText())
        quick.panel.sendEvent(try key(53, in: quick.panel))
        XCTAssertTrue(quick.isUp)
    }

    func testLosingTheKeysPutsItAwayWithWhatWasTyped() async {
        let quick = quickAccess(over: await empty())
        quick.show()
        quick.query = "banka"
        quick.panel.resignKey()
        XCTAssertFalse(quick.isUp)
        XCTAssertEqual(quick.query, "")
        XCTAssertEqual(quick.field?.stringValue, "")

        quick.show()
        XCTAssertEqual(quick.query, "", "and it comes back empty")
    }

    func testTheLockPutsItAway() async {
        let backend = FakeBackend(items: [], folders: [], password: "right")
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes("right"))
        XCTAssertEqual(store.state, .unlocked)
        let quick = quickAccess(over: store)
        quick.show()
        quick.query = "banka"

        await store.lock()
        XCTAssertFalse(quick.isUp)
        XCTAssertEqual(quick.query, "")
        XCTAssertEqual(quick.field?.stringValue, "")
    }

    // MARK: On the screen, for a moment

    private func turn(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private var inFront: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    func testEndingItLeavesNoPanelBehind() {
        weak var panel: QuickPanel?
        weak var model: QuickAccess?
        let before = NSApp.windows.count
        autoreleasepool {
            let quick = QuickAccess(door: Door(store: shut()),
                                    present: { _ in })
            panel = quick.panel
            model = quick
            quick.show()
            XCTAssertEqual(NSApp.windows.count, before + 1)
            quick.end()
            XCTAssertFalse(quick.isUp)
        }
        XCTAssertNil(model)
        XCTAssertNil(panel)
        XCTAssertEqual(NSApp.windows.count, before)
    }

    /// The real panel, ordered in and given the keys, and out again before
    /// the test ends, with every app the workspace brings forward in
    /// between written down.
    ///
    /// What fails it: the panel not on screen, not the key window, or with
    /// no caret in its field while another app is in front; no refresh
    /// arriving with the panel in it; the refresh's link or the click
    /// monitor missing while they are wanted or left after; this app
    /// brought forward at any moment from the showing to a third of a second
    /// after the closing, whether or not it had gone back by the time anyone
    /// looked; this app already in front when the test starts, since nothing
    /// could then be shown; and some other app coming forward in all three
    /// attempts.
    ///
    /// What cannot fail it: `.nonactivatingPanel` taken out of the style
    /// mask does not bring this app forward here. Run that way once (OP-31)
    /// the app in front did not change, and the test failed on the panel not
    /// being key and on nothing else. So the lines about the app in front
    /// catch only code that activates the app outright, and the line about
    /// the key window is the one that holds the flag. An app other than this
    /// one coming forward is taken to be somebody else's doing and tried
    /// again, so a panel that pushed a third app forward once or twice in
    /// three would pass. Nothing is watched after the last third of a
    /// second, and nobody's eyes are on the panel.
    func testTheAppInFrontIsTheSameBeforeDuringAndAfter() async throws {
        try Screen.skipIfLocked("that the panel takes the keys and leaves the app in front where it was")
        let quick = QuickAccess(door: Door(store: await empty()))
        up.append(quick)
        var drawn: CFTimeInterval?
        quick.drawn = { drawn = $0 }
        var forward: [pid_t] = []
        watchers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notice in
            let app = notice.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { forward.append(app?.processIdentifier ?? -1) }
        })
        let live = { Instruments.live.filter { $0.owner == "QuickAccess" }.map(\.name) }

        for attempt in 1...3 {
            forward = []
            drawn = nil
            let before = try XCTUnwrap(inFront)
            XCTAssertNotEqual(before, getpid(), "the test's own app is in front, so nothing here is shown")

            quick.show()
            XCTAssertEqual(live(), ["clicks-outside", "first-frame"], "a link for the one refresh, and it says so")
            turn(0.3)
            let during = inFront
            XCTAssertTrue(quick.panel.isVisible)
            XCTAssertTrue(quick.panel.isKeyWindow, "what is typed goes to the panel")
            XCTAssertTrue(quick.panel.firstResponder is NSTextView)
            XCTAssertEqual(live(), ["clicks-outside"], "the link ended at the refresh it was for")
            XCTAssertNotNil(drawn, "a refresh came with the panel in it")

            quick.close()
            turn(0.3)
            let after = inFront
            XCTAssertFalse(quick.panel.isVisible)
            XCTAssertEqual(live(), [], "nothing listens once it is gone")

            XCTAssertNotEqual(during, getpid(), "showing it brought this app forward")
            XCTAssertNotEqual(after, getpid(), "putting it away brought this app forward")
            XCTAssertFalse(forward.contains(getpid()), "this app came forward for a moment: \(forward)")
            if during == before, after == before, forward.isEmpty { return }
            XCTAssertLessThan(attempt, 3, "the app in front changed three times running: \(before), \(String(describing: during)), \(String(describing: after)), and \(forward) came forward")
        }
    }

    /// Put away before a refresh has come: the link goes with the panel, as
    /// it does when the vault locks under it.
    func testALinkThatIsStillWaitingEndsWithThePanel() async throws {
        let quick = QuickAccess(door: Door(store: await empty()),
                                present: { $0.orderFrontRegardless() })
        up.append(quick)
        var drawn = 0
        quick.drawn = { _ in drawn += 1 }
        let live = { Instruments.live.filter { $0.owner == "QuickAccess" }.map(\.name) }

        quick.show()
        XCTAssertEqual(live(), ["clicks-outside", "first-frame"])
        quick.close()
        XCTAssertEqual(live(), [])
        turn(0.1)
        XCTAssertEqual(drawn, 0, "a link that was ended calls nobody")
    }

    // MARK: What it lists, and what the keys do

    private var pasteboard: NSPasteboard?
    private var pasteboards: [NSPasteboard] = []
    private var scratch: URL?

    private var copied: String? { pasteboard?.string(forType: .string) }

    private func demoStore(_ items: [JSONValue]? = nil) async -> VaultStore {
        let vault = DemoVault.objects()
        let backend = FakeBackend(items: items ?? vault.items, folders: vault.folders, password: DemoVault.password)
        // Synced a minute ago, so no sync is running behind the panel.
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        await store.indexing?.value
        return store
    }

    /// The panel over a door whose copies go to a pasteboard of this test's
    /// own, ordered in nowhere and shown.
    private func demo(over store: VaultStore? = nil, recents: Recents? = nil,
                      seal: PasswordSeal? = nil) async -> QuickAccess {
        let board = NSPasteboard(name: NSPasteboard.Name("oripass-test-\(UUID().uuidString)"))
        pasteboard = board
        pasteboards.append(board)
        let opened: VaultStore
        if let store { opened = store } else { opened = await demoStore() }
        let door = Door(store: opened, seal: seal, clipboard: Clipboard(pasteboard: board))
        let quick = QuickAccess(door: door, recents: recents ?? Recents(file: nil), present: { _ in },
                                pointer: { .zero }, screens: { [self] in [laptop] })
        up.append(quick)
        quick.show()
        return quick
    }

    private func id(of title: String, in quick: QuickAccess) throws -> String {
        try XCTUnwrap(quick.door.store.shelves.all.first { $0.item.name == title }, "no \(title)").id
    }

    /// A key as the panel is sent it. An arrow comes with the two flags a
    /// real one is said to carry.
    @discardableResult
    private func press(_ key: String, _ held: NSEvent.ModifierFlags = [], code: UInt16 = 0,
                       in quick: QuickAccess) throws -> Bool {
        let isArrow = [Stroke.up, Stroke.down, Stroke.left, Stroke.right].contains(key)
        let flags = isArrow ? held.union([.numericPad, .function]) : held
        let typed = held.contains(.shift) ? key.uppercased() : key
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                   timestamp: 0, windowNumber: quick.panel.windowNumber,
                                                   context: nil, characters: typed,
                                                   charactersIgnoringModifiers: typed, isARepeat: false,
                                                   keyCode: code))
        return quick.panel.performKeyEquivalent(with: event)
    }

    private func type(_ letters: String, into quick: QuickAccess) throws {
        let editor = try XCTUnwrap(quick.panel.firstResponder as? NSTextView)
        editor.insertText(letters, replacementRange: editor.selectedRange())
    }

    private func turn() async throws {
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    func testBeforeALetterItListsTheItemsUsedLastAndALetterAsksTheIndex() async throws {
        let quick = await demo()
        XCTAssertEqual(quick.rows.count, 0, "nothing has been used")
        XCTAssertEqual(quick.panel.frame.height, 58, "the field alone")
        quick.close()

        let recents = Recents(file: nil)
        for title in ["Spotify", "GitHub"] { recents.use(try id(of: title, in: quick)) }
        recents.use("3f9d0c7a-0001-4b6e-9d1f-b2f400a1e000")
        let used = await demo(over: quick.door.store, recents: recents)
        XCTAssertEqual(used.rows.map(\.item.name), ["GitHub", "Spotify"], "an id the vault does not hold is passed over")
        let top = used.panel.frame.maxY
        XCTAssertEqual(used.panel.frame.height, 58 + 2 * 36 + 8 + 40)

        try type("is", into: used)
        XCTAssertEqual(used.query, "is")
        XCTAssertEqual(used.rows.first?.item.name, "İş Bankası")
        XCTAssertEqual(used.rows.map(\.id), used.door.store.searchIndex?.search("is").map(\.id))
        XCTAssertGreaterThan(used.rows.count, 2)
        XCTAssertEqual(used.offer.enter, "Copy Password")
        XCTAssertEqual(used.panel.frame.maxY, top, "it grows downwards, and the field stays where it is")
        XCTAssertGreaterThan(used.panel.frame.height, 58 + 2 * 36 + 8 + 40)

        try type("qqq", into: used)
        XCTAssertTrue(used.rows.isEmpty)
        XCTAssertTrue(used.foundNothing)
        used.escape()
        XCTAssertEqual(used.rows.map(\.item.name), ["GitHub", "Spotify"])
    }

    func testAnItemUsedLastLeadsThoseFoundInTheSamePlace() async throws {
        let quick = await demo()
        try type("e", into: quick)
        let found = quick.rows.map(\.id)
        let third = try XCTUnwrap(found.dropFirst(2).first)
        let index = try XCTUnwrap(quick.door.store.searchIndex)
        XCTAssertNotEqual(index.search("e", usedLast: [third]).map(\.id), found)
        XCTAssertEqual(Set(index.search("e", usedLast: [third]).map(\.id)), Set(index.search("e").map(\.id)))

        // Two titles that start with the word, the older of them used.
        let old = try Item(json: .object(["id": .string("0de40000-0000-4000-8000-00000000a001"), "type": .int(1),
                                          "name": .string("Banka bir"),
                                          "revisionDate": .string("2026-01-01T00:00:00.000Z")]))
        let new = try Item(json: .object(["id": .string("0de40000-0000-4000-8000-00000000a002"), "type": .int(1),
                                          "name": .string("Banka iki"),
                                          "revisionDate": .string("2026-06-01T00:00:00.000Z")]))
        let two = SearchIndex([Entry(old), Entry(new)])
        XCTAssertEqual(two.search("banka").map(\.item.name), ["Banka iki", "Banka bir"])
        XCTAssertEqual(two.search("banka", usedLast: [old.id]).map(\.item.name), ["Banka bir", "Banka iki"])
    }

    func testUpAndDownMoveTheSelectionAndStopAtTheEnds() async throws {
        let quick = await demo()
        try type("is", into: quick)
        XCTAssertEqual(quick.selected, 0)
        XCTAssertTrue(try press(Stroke.up, in: quick), "taken, so the caret does not jump to the start")
        XCTAssertEqual(quick.selected, 0)
        try press(Stroke.down, in: quick)
        try press(Stroke.down, in: quick)
        XCTAssertEqual(quick.selected, 2)
        for _ in 0..<100 { try press(Stroke.down, in: quick) }
        XCTAssertEqual(quick.selected, quick.rows.count - 1)
        try press(Stroke.up, in: quick)
        XCTAssertEqual(quick.selected, quick.rows.count - 2)
        XCTAssertEqual(quick.query, "is", "none of them typed anything")

        try type("k", into: quick)
        XCTAssertEqual(quick.selected, 0, "another letter starts from the top")
    }

    func testReturnCopiesThePasswordClosesAndPutsTheItemFirstAmongTheUsed() async throws {
        let recents = Recents(file: nil)
        let quick = await demo(recents: recents)
        recents.use(try id(of: "Spotify", in: quick))
        try type("github", into: quick)
        XCTAssertEqual(quick.rows.first?.item.name, "GitHub")
        let password = try XCTUnwrap(quick.rows.first?.item.login?.password)

        XCTAssertTrue(try press(Stroke.enter, in: quick))
        XCTAssertEqual(copied, password)
        XCTAssertTrue(pasteboard?.types?.contains(Clipboard.concealed) == true, "through the one way out (D15)")
        XCTAssertFalse(quick.isUp, "an action that copies puts the panel away")
        XCTAssertEqual(quick.query, "")
        XCTAssertEqual(recents.ids, [try id(of: "GitHub", in: quick), try id(of: "Spotify", in: quick)])

        quick.show()
        XCTAssertEqual(quick.rows.map(\.item.name), ["GitHub", "Spotify"], "and it leads the panel the next time")
        try press(Stroke.down, in: quick)
        try press(Stroke.enter, in: quick)
        XCTAssertEqual(recents.ids.first, try id(of: "Spotify", in: quick))
    }

    /// ⌘C's name under the list and in an opened item follows what the
    /// username is, and what is copied is the value as it was.
    func testCopyUsernameIsCopyEmailForAnAddress() async throws {
        let vault = DemoVault.objects()
        let store = await demoStore(vault.items.map { item in
            switch item["name"]?.string {
            case "Spotify": return item.setting(["login", "username"], to: .string("deniz"))
            case "GitHub": return item.setting(["login", "password"], to: .null)
            default: return item
            }
        })
        let quick = await demo(over: store)
        try type("spotify", into: quick)
        XCTAssertEqual(quick.offer.primary, "Copy Username")
        XCTAssertTrue(try press(Stroke.right, in: quick))
        XCTAssertEqual(quick.opened?.actions.first?.name, "Copy Username")

        let other = await demo(over: store)
        try type("github", into: other)
        XCTAssertEqual(other.rows.first?.item.name, "GitHub")
        XCTAssertEqual(other.offer.primary, "Copy Email")
        XCTAssertEqual(other.offer.enter, "Copy Email", "with no password it is what Return does, and what is said")
        XCTAssertTrue(try press(Stroke.right, in: other))
        let action = try XCTUnwrap(other.opened?.actions.first)
        XCTAssertEqual(action.name, "Copy Email")
        XCTAssertEqual(action.id, "username", "the row it copies is the one it always was")
        XCTAssertEqual(action.keys?.symbols, "⌘C")
        XCTAssertEqual(other.selectedSaid?.hasPrefix("Copy Email, 1 of"), true)
        XCTAssertTrue(try press("c", .command, in: other))
        XCTAssertEqual(copied, "deniz@kanarya.invalid")
    }

    func testReturnOnAnItemWithNoPasswordCopiesItsFirstField() async throws {
        let quick = await demo()
        let card = try XCTUnwrap(quick.door.store.shelves.byType[.card]?.first)
        try type(card.item.name, into: quick)
        XCTAssertEqual(quick.rows.first?.id, card.id)
        XCTAssertEqual(quick.offer.enter, "Copy Number")
        XCTAssertNil(quick.offer.password)
        guard case .card(let payload) = card.item.payload else { return XCTFail("not a card") }

        try press(Stroke.enter, in: quick)
        XCTAssertEqual(copied, payload.number)
        XCTAssertFalse(quick.isUp)
    }

    func testTheCopyKeysActOnTheSelectedRowWithoutOpeningIt() async throws {
        let quick = await demo()
        try type("is ban", into: quick)
        let login = try XCTUnwrap(quick.rows.first?.item.login)

        XCTAssertTrue(try press("c", .command, in: quick))
        XCTAssertEqual(copied, login.username)
        XCTAssertFalse(quick.isUp)
        XCTAssertNil(quick.opened)

        quick.show()
        try type("is ban", into: quick)
        XCTAssertTrue(try press("c", [.command, .shift], in: quick))
        XCTAssertEqual(copied, login.password)
        XCTAssertFalse(quick.isUp)

        // The one-time code, as it stands when the key is pressed.
        quick.show()
        try type("is ban", into: quick)
        let totp = try XCTUnwrap(login.totp.flatMap(Totp.init))
        let before = totp.code(at: Date())
        XCTAssertTrue(try press("c", [.command, .option], in: quick))
        XCTAssertTrue([before, totp.code(at: Date())].contains(copied ?? ""))
        XCTAssertFalse(quick.isUp)

        // An item with no code keeps the key from the menu bar and copies
        // nothing.
        quick.show()
        try type("spotify", into: quick)
        XCTAssertTrue(try press("c", [.command, .option], in: quick))
        XCTAssertTrue([before, totp.code(at: Date())].contains(copied ?? ""), "what was there is still there")
        XCTAssertTrue(quick.isUp)
        quick.close()
        quick.show()
        try type("is ban", into: quick)

        // Letters selected in the field are what ⌘C means there.
        let editor = try XCTUnwrap(quick.panel.firstResponder as? NSTextView)
        editor.selectAll(nil)
        XCTAssertFalse(try press("c", .command, in: quick), "left to the Edit menu")
        XCTAssertTrue(quick.isUp)
    }

    func testRightOpensTheActionsAndLeftComesBack() async throws {
        let quick = await demo()
        XCTAssertFalse(try press(Stroke.right, in: quick), "nothing is listed, so there is nothing to open")
        try type("is ban", into: quick)
        let listed = quick.panel.frame.height
        let item = try XCTUnwrap(quick.rows.first?.item)

        let editor = try XCTUnwrap(quick.panel.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertFalse(try press(Stroke.right, in: quick), "inside what was typed, → is the caret's")
        XCTAssertNil(quick.opened)
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        XCTAssertFalse(try press(Stroke.left, in: quick), "and ← is, with nothing opened")

        XCTAssertTrue(try press(Stroke.right, in: quick))
        let opened = try XCTUnwrap(quick.opened)
        XCTAssertEqual(opened.entry.id, item.id)
        XCTAssertEqual(opened.actions.map(\.name), [
            "Copy Email", "Copy Password", "Copy One-Time Code", "Open in New Window", "Open in OriPass",
            "Copy Website (www.isbank.com.tr)", "Copy Website (internet.isbank.com.tr)",
            "Copy Website (isbank.com.tr)", "Copy Müşteri no", "Copy PIN", "Copy Notes",
        ])
        XCTAssertEqual(opened.actions.map { $0.keys?.symbols ?? "" },
                       ["⌘C", "⇧⌘C", "⌥⌘C", "⌘O", "⇧⌘O", "", "", "", "", "", ""])
        XCTAssertEqual(opened.actions.filter(\.startsGroup).map(\.name),
                       ["Open in New Window", "Copy Website (www.isbank.com.tr)"])
        XCTAssertEqual(opened.detail.vault.name, "İş", "the foot says where it lives")
        XCTAssertNotEqual(quick.panel.frame.height, listed)
        XCTAssertEqual(quick.query, "is ban", "what was typed is still in the field")

        XCTAssertTrue(try press(Stroke.left, in: quick))
        XCTAssertNil(quick.opened)
        XCTAssertEqual(quick.panel.frame.height, listed)
        XCTAssertTrue(quick.isUp)

        // The arrows move among the actions, and Return does the chosen one.
        try press(Stroke.right, in: quick)
        for _ in 0..<9 { try press(Stroke.down, in: quick) }
        XCTAssertEqual(quick.opened?.chosen, 9)
        XCTAssertEqual(quick.selected, 0, "the list under it has not moved")
        try press(Stroke.enter, in: quick)
        XCTAssertEqual(copied, item.fields.first { $0.name == "PIN" }?.value)
        XCTAssertFalse(quick.isUp)
        XCTAssertNil(quick.opened, "and it comes back as a list")

        // A letter typed over an opened item is a search again.
        quick.show()
        try type("is ban", into: quick)
        try press(Stroke.right, in: quick)
        try type("k", into: quick)
        XCTAssertNil(quick.opened)
        XCTAssertEqual(quick.query, "is bank")
    }

    func testTheKeysOfAnOpenedItemAreTheItems() async throws {
        let quick = await demo()
        try type("github", into: quick)
        let login = try XCTUnwrap(quick.rows.first?.item.login)
        try press(Stroke.right, in: quick)
        try press(Stroke.down, in: quick)
        XCTAssertEqual(quick.opened?.chosen, 1)
        XCTAssertTrue(try press("c", .command, in: quick))
        XCTAssertEqual(copied, login.username, "⌘C is the username whichever action is chosen")
    }

    func testCommandOOpensTheItemsWindowAndShiftCommandOTheMainWindowOnIt() async throws {
        let recents = Recents(file: nil)
        let quick = await demo(recents: recents)
        var activated = 0
        var shown = 0
        quick.activate = { activated += 1 }
        quick.showApp = { shown += 1 }
        let panes = try XCTUnwrap(quick.door.panes)
        let github = try id(of: "GitHub", in: quick)

        try type("github", into: quick)
        XCTAssertTrue(try press("o", .command, in: quick))
        XCTAssertFalse(quick.isUp)
        XCTAssertEqual(activated, 1, "the app comes forward for its window")
        XCTAssertEqual(panes.windows?.panes(showing: github)?.selectedItem?.id, github)
        XCTAssertNil(panes.selectedItem, "the main window is left as it was")
        XCTAssertEqual(recents.ids, [github])
        XCTAssertNil(copied)

        panes.select(.favorites)
        panes.choose(.card)
        quick.show()
        try type("spotify", into: quick)
        XCTAssertTrue(try press("o", [.command, .shift], in: quick))
        XCTAssertFalse(quick.isUp)
        XCTAssertEqual(shown, 1)
        XCTAssertEqual(panes.selectedItem?.item.name, "Spotify", "which is no favourite and no card")
        XCTAssertEqual(panes.selection, .allItems)
        XCTAssertEqual(recents.ids.first, try id(of: "Spotify", in: quick))
        await store(of: quick).lock()
    }

    private func store(of quick: QuickAccess) -> VaultStore { quick.door.store }

    func testACommandKeyThatIsNotThePanelsGoesNoFurther() async throws {
        let quick = await demo()
        try type("github", into: quick)
        for key in ["r", "f", "q", "w", ","] {
            XCTAssertTrue(try press(key, .command, in: quick), "⌘\(key) would be done to the main window")
        }
        XCTAssertTrue(quick.isUp)
        XCTAssertEqual(quick.query, "github")
        for key in ["a", "v", "x", "z"] {
            XCTAssertFalse(try press(key, .command, in: quick), "⌘\(key) is the field's")
        }
        XCTAssertFalse(try press("g", in: quick), "a letter is the field's")
    }

    // MARK: Over a vault that is shut

    func testOverAShutVaultItIsTheLockAndWhatWasTypedIsSearchedForWhenItOpens() async throws {
        let store = await demoStore()
        await store.lock()
        let quick = await demo(over: store)
        XCTAssertFalse(quick.isOpen)
        XCTAssertEqual(quick.panel.frame.height, 58 + 56)
        try await turn()
        let editor = try XCTUnwrap(quick.panel.firstResponder as? NSTextView)
        XCTAssertTrue(editor.delegate is PasswordTextField, "no finger can open it, so the keys are the password's")

        // A password half typed does not wait in a panel that has gone.
        editor.insertText("half", replacementRange: editor.selectedRange())
        let field = try XCTUnwrap(editor.delegate as? PasswordTextField)
        XCTAssertEqual(field.stringValue, "half")
        quick.close()
        XCTAssertEqual(field.stringValue, "")
        quick.show()

        // What he had begun to type in the other field.
        quick.field?.stringValue = "github"
        quick.query = "github"
        XCTAssertTrue(quick.rows.isEmpty, "nothing is searched for while it is shut")
        XCTAssertFalse(try press(Stroke.enter, in: quick), "Return is the password field's")
        XCTAssertTrue(try press("o", .command, in: quick), "and ⌘O is nobody's")

        quick.unlock(with: SecretBytes("not-the-password"))
        await quick.unlocking?.value
        XCTAssertFalse(quick.isOpen)
        XCTAssertNotNil(store.refusal)
        XCTAssertTrue(quick.isUp)

        quick.unlock(with: SecretBytes(DemoVault.password))
        await quick.unlocking?.value
        await store.indexing?.value
        XCTAssertTrue(quick.isOpen)
        XCTAssertEqual(quick.query, "github", "what was typed in the meantime is kept")
        XCTAssertEqual(quick.rows.first?.item.name, "GitHub", "and run")
        let search = try XCTUnwrap(quick.panel.firstResponder as? NSTextView)
        XCTAssertTrue(search.delegate === quick.field, "the keys are the search's again")
        XCTAssertEqual(search.selectedRange(), NSRange(location: 6, length: 0), "after what was typed, not around it")
        XCTAssertGreaterThan(quick.panel.frame.height, 58 + 56)
        await store.lock()
    }

    func testAFingerIsAskedForAtOnceWhenOneCanOpenItAndThePasswordIsThereOtherwise() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oripass-quick-\(UUID().uuidString)")
        scratch = directory
        let enclave = FakeEnclave()
        let seal = PasswordSeal(directory: directory, enclave: enclave)
        let store = await demoStore()
        await store.lock()
        try seal.seal(SecretBytes(DemoVault.password))

        // The sheet is cancelled: the panel stays, and the keys go to the
        // password.
        enclave.cancels = true
        let quick = await demo(over: store, seal: seal)
        XCTAssertTrue(quick.door.hasSeal)
        XCTAssertEqual(enclave.asked.count, 0)
        let asking = try XCTUnwrap(quick.asking, "asked as the panel comes up")
        XCTAssertTrue(quick.panel.firstResponder === (quick.field?.currentEditor() as? NSTextView),
                      "and the keys are the search's while he reaches for the sensor")
        quick.query = "spot"
        quick.panel.resignKey()
        XCTAssertTrue(quick.isUp, "a sheet that takes the keys does not put the panel away")
        await asking.value
        XCTAssertEqual(enclave.asked.count, 1)
        XCTAssertFalse(quick.isOpen)
        XCTAssertTrue(quick.isUp)
        XCTAssertNil(quick.asking)
        let editor = try XCTUnwrap(quick.panel.firstResponder as? NSTextView)
        XCTAssertTrue(editor.delegate is PasswordTextField)
        quick.close()

        // A finger: the vault opens under what was typed.
        enclave.cancels = false
        quick.show()
        quick.query = "spot"
        await quick.asking?.value
        await store.indexing?.value
        XCTAssertEqual(enclave.asked.count, 2)
        XCTAssertTrue(quick.isOpen)
        XCTAssertEqual(quick.rows.first?.item.name, "Spotify")
        await store.lock()
    }

    func testALockLeavesNothingOfTheVaultInThePanel() async throws {
        let recents = Recents(file: nil)
        let quick = await demo(recents: recents)
        recents.use(try id(of: "GitHub", in: quick))
        try type("is ban", into: quick)
        try press(Stroke.right, in: quick)
        quick.panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertNotNil(quick.opened)
        weak var entry = quick.rows.first
        XCTAssertNotNil(entry)

        await store(of: quick).lock()
        XCTAssertFalse(quick.isUp)
        XCTAssertFalse(quick.isOpen)
        XCTAssertNil(quick.opened)
        XCTAssertTrue(quick.rows.isEmpty)
        XCTAssertEqual(quick.query, "")
        try await turn()
        XCTAssertNil(entry, "an item of a vault that has shut is still held by the panel or by what it drew")
        XCTAssertEqual(recents.ids.count, 1, "the ids stay, and name nothing without the vault")

        quick.show()
        XCTAssertTrue(quick.rows.isEmpty, "over the shut vault it lists nothing")
    }

    // MARK: The recents

    func testTheRecentsFileHoldsIdsAndNothingElse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oripass-quick-\(UUID().uuidString)")
        scratch = directory
        let file = directory.appendingPathComponent("recent.json")
        let quick = await demo(recents: Recents(file: file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "nothing is written until something is used")

        for word in ["is ban", "github", "spotify", "is ban"] {
            quick.show()
            try type(word, into: quick)
            try press(Stroke.enter, in: quick)
        }
        let ids = [try id(of: "İş Bankası", in: quick), try id(of: "Spotify", in: quick), try id(of: "GitHub", in: quick)]
        let written = try Data(contentsOf: file)
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: written), ids)
        // All of it, byte for byte: three ids in a list.
        XCTAssertEqual(String(decoding: written, as: UTF8.self), "[" + ids.map { "\"\($0)\"" }.joined(separator: ",") + "]")
        let text = String(decoding: written, as: UTF8.self)
        for entry in store(of: quick).shelves.all {
            XCTAssertFalse(text.contains(entry.item.name), "a title")
            if let username = entry.item.login?.username { XCTAssertFalse(text.contains(username), "a username") }
        }
        for canary in DemoVault.canaries { XCTAssertFalse(text.contains(canary)) }
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        XCTAssertEqual(Recents(file: file).ids, ids, "and it is read back")
    }

    func testOnlyAnIdIsEverWrittenOrRead() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oripass-quick-\(UUID().uuidString)")
        scratch = directory
        let file = directory.appendingPathComponent("recent.json")
        let recents = Recents(file: file)
        recents.use("İş Bankası")
        recents.use(DemoVault.canaries[0])
        XCTAssertEqual(recents.ids, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        // More than ten, and the oldest go.
        let ids = (0..<12).map { String(format: "0de40000-0000-4000-8000-%012d", $0) }
        ids.forEach(recents.use)
        XCTAssertEqual(recents.ids, Array(ids.reversed().prefix(10)))
        recents.use(ids[5])
        XCTAssertEqual(recents.ids.first, ids[5])
        XCTAssertEqual(recents.ids.count, 10)

        // A file somebody else wrote into is read for its ids alone.
        try Data(#"["0de40000-0000-4000-8000-000000000001","hunter2","0de40000-0000-4000-8000-000000000001"]"#.utf8)
            .write(to: file)
        XCTAssertEqual(Recents(file: file).ids, ["0de40000-0000-4000-8000-000000000001"])
        try Data(#"{"title":"x"}"#.utf8).write(to: file)
        XCTAssertEqual(Recents(file: file).ids, [])
    }

    // MARK: The budget (D18)

    /// A letter to the list laid out again, at two thousand items: the
    /// search, the model, and the panel's views brought up to date, which is
    /// the main thread's share of a frame. The median of the letters is held
    /// under a sixtieth of a second, in the Debug build the tests are, which
    /// is some three times slower at this than the one he runs. The drawing
    /// into a bitmap that follows is not timed. It is there to show that the
    /// layout that was timed is the one with the new list in it. What a
    /// letter costs on a screen is `OP_DEMO=type`'s to say (`docs/notes.md`,
    /// "Timing").
    func testALetterToTheListLaidOutAgainIsInsideOneFrameAtTwoThousandItems() async throws {
        let quick = await demo(over: await demoStore(ScrollTrace.items(2000)))
        XCTAssertEqual(store(of: quick).shelves.all.count, 2000)
        let view = try XCTUnwrap(quick.panel.contentView)

        /// The first row's title, as it was drawn.
        func firstRow(in bitmap: NSBitmapImageRep) -> [NSColor?] {
            let scale = bitmap.pixelsWide / 600
            return stride(from: 64 * scale, to: 90 * scale, by: 3).flatMap { y in
                stride(from: 44 * scale, to: 200 * scale, by: 3).map { x in bitmap.colorAt(x: x, y: y) }
            }
        }

        var took: [Double] = []
        var drawn: [(first: String?, row: [NSColor?])] = []
        for typed in ["i", "in", "inv", "", "ç", "il", "ilg", "ilga", "ilgaz", "ilgaz 7"] {
            let started = DispatchTime.now().uptimeNanoseconds
            quick.field?.stringValue = typed
            quick.query = typed
            view.layoutSubtreeIfNeeded()
            if !typed.isEmpty { took.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000) }
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            XCTAssertEqual(quick.rows.isEmpty, typed.isEmpty, typed)
            drawn.append((quick.rows.first?.item.name, firstRow(in: bitmap)))
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        // What was timed drew the list it was timed for: where the first
        // row is another item, its pixels are other pixels.
        var changes = 0
        for (before, after) in zip(drawn, drawn.dropFirst()) where before.first != after.first {
            changes += 1
            XCTAssertNotEqual(before.row, after.row, "\(before.first ?? "nothing") to \(after.first ?? "nothing")")
        }
        XCTAssertGreaterThan(changes, 2)
        let median = took.sorted()[took.count / 2]
        print("QuickAccessTests: 2000 items, a letter to the list laid out:",
              took.map { String(format: "%.1f", $0) }.joined(separator: " "), "ms, median", String(format: "%.1f", median))
        XCTAssertLessThan(median, 1000.0 / 60, "\(took)")
    }
}
