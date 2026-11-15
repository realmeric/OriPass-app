import AppKit
import Carbon.HIToolbox
import XCTest
@testable import OriPass

private struct SaidTab: TabAsker {
    let address: String?
    func address(of app: FrontApp) async -> String? { address }
}

/// Against a sink: no key is posted, no app is asked where its caret is, and
/// macOS is asked for nothing. The one thing made for real is a `CGEvent`,
/// which is read and never posted.
@MainActor
final class TypistTests: XCTestCase {
    private let slack = FrontApp(pid: 4711, bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
    private let spotify = FrontApp(pid: 4712, bundleID: "com.spotify.client", name: "Spotify")
    private let safari = FrontApp(pid: 4713, bundleID: "com.apple.Safari", name: "Safari")
    private let laptop = NSRect(x: 0, y: 0, width: 1512, height: 982)

    private var sink: FakeSink!
    private var ground: FakeForeground!
    private var access: FakeAccessibility!
    /// How many times the typist has waited, and what to do at each.
    private var pauses = 0
    private var onPause: ((Int) async -> Void)?

    private var pasteboard: NSPasteboard!
    private var suite: String!
    private var defaults: UserDefaults!
    private var up: [QuickAccess] = []

    override func setUp() {
        sink = FakeSink()
        ground = FakeForeground(frontPID: slack.pid)
        access = FakeAccessibility()
        pauses = 0
        onPause = nil
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

    private func typist() -> Typist {
        Typist(access: access, ground: ground, sink: sink) { [weak self] _ in
            guard let self else { return }
            self.pauses += 1
            await self.onPause?(self.pauses)
        }
    }

    private var copied: String? { pasteboard.string(forType: .string) }

    private func keys(_ text: String) -> [Key] { text.map { .text(String($0)) } }

    // MARK: The sequence

    func testAPlainFieldGetsTheUsernameATabAndThePassword() async {
        let typing = typist().type(Filling(username: "deniz", password: "s3cret"), into: slack, pressingReturn: false)
        let outcome = await typing.value
        XCTAssertEqual(sink.keys, keys("deniz") + [.tab] + keys("s3cret"))
        XCTAssertEqual(outcome, .typed(12))
        XCTAssertEqual(sink.pids, [slack.pid], "every key to the app it was asked for")
    }

    func testWhatTheLogIsToldOfAFillSaysNothingOfHowLongTheLoginIs() {
        let outcomes: [Typist.Outcome] = [.typed(12), .notAllowed, .notInFront(7), .keysHeld, .stopped(2),
                                          .needsPasswordField, .noPassword]
        XCTAssertEqual(outcomes.map(\.kind), ["typed", "not allowed", "not in front", "keys held", "stopped",
                                              "needs a password field", "no password"])
        XCTAssertEqual(Typist.Outcome.typed(12).kind, Typist.Outcome.typed(6).kind)
    }

    func testASecureFieldGetsThePasswordAlone() async {
        ground.caret = .secure
        let outcome = await typist().type(Filling(username: "deniz", password: "s3cret"), into: slack,
                                          pressingReturn: false).value
        XCTAssertEqual(sink.keys, keys("s3cret"))
        XCTAssertEqual(outcome, .typed(6))
    }

    func testReturnFollowsThePasswordOnlyWhenItIsAskedFor() async {
        let login = Filling(username: "deniz", password: "pw")
        _ = await typist().type(login, into: slack, pressingReturn: true).value
        XCTAssertEqual(sink.keys, keys("deniz") + [.tab] + keys("pw") + [.enter])

        sink.forget()
        ground.caret = .secure
        _ = await typist().type(login, into: slack, pressingReturn: true).value
        XCTAssertEqual(sink.keys, keys("pw") + [.enter])

        XCTAssertEqual(Typist.keys(for: login, caret: .plain, pressingReturn: false)?.last, .text("w"))
        XCTAssertFalse(Settings().fill.pressesReturn, "off until he switches it on")
    }

    // MARK: Where a password goes

    /// What was seen in Orion: the caret in a username's
    /// field, a login with a password and no username, and the password
    /// typed there in the clear.
    func testALoginWithNoUsernameTypesNothingIntoAFieldThatIsNoPasswords() async {
        var told: [Typist.Outcome] = []
        for username in [nil, "", "   ", "\u{a0}\t"] as [String?] {
            let outcome = await typist().type(Filling(username: username, password: "s3cret"), into: slack,
                                              pressingReturn: true) { told.append($0) }.value
            XCTAssertEqual(outcome, .needsPasswordField)
            XCTAssertEqual(sink.keys, [], "the password would stand in the clear where a username goes")
        }
        XCTAssertEqual(told, Array(repeating: .needsPasswordField, count: 4), "whoever asked is told before it is over")
        XCTAssertFalse(Instruments.live.contains { $0.owner == "Fill" })
    }

    func testALoginWithNoUsernameIsItsPasswordAloneInAPasswordsField() async {
        ground.caret = .secure
        for username in [nil, "", "   "] as [String?] {
            sink.forget()
            let outcome = await typist().type(Filling(username: username, password: "s3cret"), into: slack,
                                              pressingReturn: true).value
            XCTAssertEqual(sink.keys, keys("s3cret") + [.enter])
            XCTAssertEqual(outcome, .typed(7))
        }
    }

    func testALoginWithNoUsernameTypesNothingIntoAnAppThatDoesNotSayWhereItsCaretIs() async {
        ground.caret = .unknown
        let outcome = await typist().type(Filling(username: nil, password: "s3cret"), into: slack,
                                          pressingReturn: false).value
        XCTAssertEqual(outcome, .needsPasswordField)
        XCTAssertEqual(sink.keys, [])
    }

    func testALoginWithAUsernameIsTypedWholeIntoAnAppThatDoesNotSayWhereItsCaretIs() async {
        ground.caret = .unknown
        let outcome = await typist().type(Filling(username: "deniz", password: "s3cret"), into: slack,
                                          pressingReturn: false).value
        XCTAssertEqual(sink.keys, keys("deniz") + [.tab] + keys("s3cret"))
        XCTAssertEqual(outcome, .typed(12))
    }

    /// A Tab or a line's end inside the username may move the caret, and
    /// this app's own Tab would then lead somewhere else.
    func testAUsernameThatWouldMoveTheCaretIsNotTypedAndThePasswordGoesOnlyWhereOneBelongs() async {
        for username in ["de\tniz", "deniz\n", "de\rniz", "de\u{2028}niz"] {
            ground.caret = .plain
            sink.forget()
            let plain = await typist().type(Filling(username: username, password: "pw"), into: slack,
                                            pressingReturn: false).value
            XCTAssertEqual(plain, .needsPasswordField)
            XCTAssertEqual(sink.keys, [])

            ground.caret = .secure
            let secure = await typist().type(Filling(username: username, password: "pw"), into: slack,
                                             pressingReturn: false).value
            XCTAssertEqual(secure, .typed(2))
            XCTAssertEqual(sink.keys, keys("pw"))
        }
        XCTAssertEqual(Filling(username: " deniz ", password: "pw").leadingUsername, " deniz ", "as it is written")
    }

    /// Not the username alone either: with Return switched on that would
    /// send a form whose password is empty.
    func testALoginWithNoPasswordTypesNothing() async {
        for caret in [Caret.plain, .secure, .unknown] {
            ground.caret = caret
            let outcome = await typist().type(Filling(username: "deniz", password: ""), into: slack,
                                              pressingReturn: true).value
            XCTAssertEqual(outcome, .noPassword)
            XCTAssertEqual(sink.keys, [])
        }
    }

    func testThePasswordIsInTheKeysOnlyAfterAUsernameAndATabOrForAPasswordsField() {
        let none = Filling(username: nil, password: "pw")
        XCTAssertNil(Typist.keys(for: none, caret: .plain, pressingReturn: false))
        XCTAssertNil(Typist.keys(for: none, caret: .unknown, pressingReturn: true))
        XCTAssertEqual(Typist.keys(for: none, caret: .secure, pressingReturn: false), keys("pw"))
        let whole = Filling(username: "a", password: "pw")
        XCTAssertEqual(Typist.keys(for: whole, caret: .plain, pressingReturn: false), keys("a") + [.tab] + keys("pw"))
        XCTAssertEqual(Typist.keys(for: whole, caret: .unknown, pressingReturn: false),
                       keys("a") + [.tab] + keys("pw"))
        XCTAssertEqual(Typist.keys(for: whole, caret: .secure, pressingReturn: false), keys("pw"))
    }

    func testAUsernameWithTurkishLettersAndAnAtSignArrivesWhole() async {
        let username = "şükrü.dağ@örnek.com.tr"
        let password = "İ~ğ€ 🔑é"
        _ = await typist().type(Filling(username: username, password: password), into: slack,
                                pressingReturn: false).value
        XCTAssertEqual(sink.typed, username + "\t" + password)
        XCTAssertEqual(sink.keys.count, username.count + 1 + password.count, "a character to a key")
        XCTAssertTrue(sink.keys.contains(.text("ş")))
        XCTAssertTrue(sink.keys.contains(.text("ğ")))
        XCTAssertTrue(sink.keys.contains(.text("@")))
    }

    /// The events the real sink would post, made and read and not posted.
    func testAKeyIsTwoEventsThatCarryItsOwnTextAndNothingHeld() {
        for character in ["ş", "ğ", "@", "🔑", "e\u{301}"] {
            let events = EventKeys.events(for: .text(character))
            XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
            for event in events {
                var units = [UniChar](repeating: 0, count: 8)
                var count = 0
                event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &count,
                                               unicodeString: &units)
                XCTAssertEqual(String(utf16CodeUnits: units, count: count), character)
                XCTAssertEqual(event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]), [])
            }
        }
        let tab = EventKeys.events(for: .tab)
        XCTAssertEqual(tab.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [Int64(kVK_Tab), Int64(kVK_Tab)])
        let enter = EventKeys.events(for: .enter)
        XCTAssertEqual(enter.map { $0.getIntegerValueField(.keyboardEventKeycode) },
                       [Int64(kVK_Return), Int64(kVK_Return)])
        XCTAssertEqual(enter.map(\.type), [.keyDown, .keyUp])
    }

    // MARK: Which app

    func testItWaitsUntilTheAppIsInFrontAgainAndTheKeysAreLetGo() async {
        ground.frontPID = 1
        ground.holdsModifier = true
        onPause = { [ground, slack, sink] turn in
            XCTAssertTrue(turn > 5 || sink?.keys.isEmpty == true, "nothing goes while it waits")
            if turn == 3 { ground?.frontPID = slack.pid }
            if turn == 5 { ground?.holdsModifier = false }
        }
        let outcome = await typist().type(Filling(username: "a", password: "b"), into: slack,
                                          pressingReturn: false).value
        XCTAssertEqual(outcome, .typed(3))
        XCTAssertEqual(sink.typed, "a\tb")
    }

    func testWithAnotherAppInFrontNothingIsTyped() async {
        ground.frontPID = spotify.pid
        let typist = typist()
        let outcome = await typist.type(Filling(username: "deniz", password: "s3cret"), into: slack,
                                        pressingReturn: true).value
        XCTAssertEqual(outcome, .notInFront(0))
        XCTAssertEqual(sink.keys, [])
        XCTAssertEqual(Double(pauses) * Typist.look, Typist.patience, accuracy: Typist.look * 2,
                       "it gave the app two seconds to come back")
        XCTAssertFalse(Instruments.live.contains { $0.owner == "Fill" })

        ground.frontPID = nil
        let nobody = await typist.type(Filling(username: nil, password: "s3cret"), into: slack,
                                       pressingReturn: false).value
        XCTAssertEqual(nobody, .notInFront(0))
        XCTAssertEqual(sink.keys, [])
    }

    func testAnAppThatComesInFrontPartOfTheWayGetsNoKey() async {
        sink.afterKey = { [ground, spotify] count in
            if count == 3 { ground?.frontPID = spotify.pid }
        }
        let outcome = await typist().type(Filling(username: "deniz", password: "s3cret"), into: slack,
                                          pressingReturn: true).value
        XCTAssertEqual(outcome, .notInFront(3))
        XCTAssertEqual(sink.typed, "den", "and not one character of the password")
        XCTAssertEqual(sink.pids, [slack.pid])
    }

    func testKeysHeldForTheWholeWaitTypeNothing() async {
        ground.holdsModifier = true
        let outcome = await typist().type(Filling(username: "a", password: "b"), into: slack,
                                          pressingReturn: false).value
        XCTAssertEqual(outcome, .keysHeld)
        XCTAssertEqual(sink.keys, [])
    }

    func testWithoutTheGrantNothingIsPostedAndNothingIsAsked() async {
        access.isTrusted = false
        let outcome = await typist().type(Filling(username: "a", password: "b"), into: slack,
                                          pressingReturn: false).value
        XCTAssertEqual(outcome, .notAllowed)
        XCTAssertEqual(sink.keys, [])
        XCTAssertEqual(access.asked, 0, "asking is the panel's, with its sentence")
    }

    func testAStopEndsItBetweenTwoKeysAndLeavesNoTimer() async {
        let typist = typist()
        onPause = { [sink] _ in
            if sink?.keys.count == 2 { typist.stop() }
        }
        let typing = typist.type(Filling(username: "deniz", password: "s3cret"), into: slack, pressingReturn: false)
        XCTAssertEqual(Instruments.live.filter { $0.owner == "Fill" }.map(\.name), ["typing"])
        let outcome = await typing.value
        XCTAssertEqual(outcome, .stopped(2))
        XCTAssertEqual(sink.typed, "de")
        XCTAssertFalse(Instruments.live.contains { $0.owner == "Fill" })
    }

    func testNothingOfALoginIsSaidByAPrintOrADump() {
        let login = Filling(username: "CANARY-USER", password: "CANARY-PASS")
        sink.post(.text("C"), to: 1)
        var said = "\(login) \(String(reflecting: login)) \(Key.text("C")) \([Key.text("C"), .tab]) \(sink!)"
        dump(login, to: &said)
        dump(Key.text("C"), to: &said)
        dump(sink, to: &said)
        XCTAssertFalse(said.contains("CANARY"))
        XCTAssertFalse(said.contains("\"C\""))
        XCTAssertTrue(said.contains("Key.tab"))
    }

    // MARK: Quick Access

    /// The demo's vault, with `nameless` left without its username.
    private func store(with more: [JSONValue] = [], nameless: String? = nil) async -> VaultStore {
        let vault = DemoVault.objects()
        let items = vault.items.map { $0["name"]?.string == nameless ? $0.setting(["login", "username"], to: .null) : $0 }
        let backend = FakeBackend(items: items + more, folders: vault.folders, password: DemoVault.password)
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        await store.indexing?.value
        return store
    }

    /// The panel over the demo's vault, ordered in nowhere, told what is in
    /// front and given the test's typist.
    private func quickAccess(over store: VaultStore, in front: FrontApp?, tab: String? = nil,
                             authoriser: FakeAuthoriser? = nil,
                             voice: Voice? = nil) -> (quick: QuickAccess, typist: Typist) {
        let typist = typist()
        ground.frontPID = front?.pid
        let door = Door(store: store, clipboard: Clipboard(pasteboard: pasteboard),
                        reprompt: authoriser.map { Reprompt(store: store, authoriser: $0) })
        let quick = QuickAccess(door: door, recents: Recents(file: nil), front: { front },
                                tabs: tab.map { SaidTab(address: $0) }, typist: typist, settings: defaults,
                                voice: voice, present: { _ in }, pointer: { .zero }, screens: { [self] in [laptop] })
        up.append(quick)
        return (quick, typist)
    }

    private func login(_ title: String, in store: VaultStore) throws -> Login {
        try XCTUnwrap(store.shelves.all.first { $0.item.name == title }?.item.login, "no \(title)")
    }

    private func shiftReturn(in panel: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
                                       windowNumber: panel.windowNumber, context: nil, characters: "\r",
                                       charactersIgnoringModifiers: "\r", isARepeat: false,
                                       keyCode: UInt16(kVK_Return)))
    }

    func testShiftReturnTypesTheSelectedLoginIntoTheAppThePanelCameUpOver() async throws {
        let store = await store()
        let (quick, typist) = quickAccess(over: store, in: slack)
        quick.show()
        quick.query = "spotify"
        let spotify = try login("Spotify", in: store)
        let count = pasteboard.changeCount

        XCTAssertTrue(quick.press(try shiftReturn(in: quick.panel)))
        XCTAssertFalse(quick.isUp, "the panel goes before the first key")
        let outcome = await typist.typing?.value
        XCTAssertEqual(sink.typed, try XCTUnwrap(spotify.username) + "\t" + (try XCTUnwrap(spotify.password)))
        XCTAssertEqual(outcome, .typed(sink.keys.count))
        XCTAssertEqual(sink.pids, [slack.pid], "the app in front, whatever the login is for")
        XCTAssertNil(copied, "nothing goes through the pasteboard")
        XCTAssertEqual(pasteboard.changeCount, count)
        XCTAssertFalse(quick.door.clipboard.isHolding)
        XCTAssertEqual(quick.recents.ids.count, 1, "and the item is the one used last")
    }

    func testReturnAfterThePasswordIsASetting() async throws {
        let store = await store()
        let (quick, typist) = quickAccess(over: store, in: slack)
        quick.door.preferences.settings.fill.pressesReturn = true
        quick.show()
        quick.query = "spotify"
        XCTAssertTrue(quick.fill())
        _ = await typist.typing?.value
        XCTAssertEqual(sink.keys.last, .enter)
        XCTAssertEqual(sink.keys.filter { $0 == .enter }.count, 1)
    }

    func testWithNoAppInFrontOrNoPasswordNothingIsFilledAndThePanelStays() async throws {
        let store = await store()
        let (quick, typist) = quickAccess(over: store, in: nil)
        quick.show()
        quick.query = "spotify"
        XCTAssertFalse(quick.fill(), "the panel came up over this app")
        XCTAssertTrue(quick.isUp)
        XCTAssertNil(typist.typing)
        quick.openSelected()
        XCTAssertFalse(quick.opened?.actions.contains { $0.act == .fill } == true)
        quick.close()

        let (other, _) = quickAccess(over: store, in: slack)
        other.show()
        other.query = "yazılım"
        XCTAssertNil(other.rows.first?.item.login, "a note")
        _ = other.press(try shiftReturn(in: other.panel))
        XCTAssertTrue(other.isUp)
        XCTAssertEqual(sink.keys, [])
    }

    func testAnOpenedLoginOffersTheFillByTheAppsNameBetweenTheTwoWindows() async throws {
        let store = await store()
        let (quick, typist) = quickAccess(over: store, in: slack)
        quick.show()
        quick.query = "spotify"
        quick.openSelected()
        let actions = try XCTUnwrap(quick.opened?.actions)
        let place = try XCTUnwrap(actions.firstIndex { $0.act == .fill })
        XCTAssertEqual(actions[place].name, "Fill in Slack")
        XCTAssertEqual(actions[place].keys?.symbols, "⇧Return")
        XCTAssertEqual(actions[place - 1].act, .openWindow)
        XCTAssertEqual(actions[place + 1].act, .openInApp)

        quick.perform(actions[place])
        XCTAssertFalse(quick.isUp)
        _ = await typist.typing?.value
        XCTAssertEqual(sink.typed.split(separator: "\t").count, 2)
    }

    // MARK: Before it is allowed

    func testUntilItIsAllowedThePasswordIsCopiedAndThePanelSaysSo() async throws {
        let store = await store()
        access.isTrusted = false
        let (quick, typist) = quickAccess(over: store, in: slack)
        quick.show()
        quick.query = "spotify"
        let spotify = try login("Spotify", in: store)

        XCTAssertTrue(quick.fill())
        XCTAssertEqual(copied, spotify.password)
        XCTAssertTrue(pasteboard.types?.contains(Clipboard.concealed) == true, "through the one way out (D15)")
        XCTAssertNil(typist.typing)
        XCTAssertEqual(sink.keys, [])
        XCTAssertTrue(quick.isUp, "it stays, to say what it did")
        let notice = try XCTUnwrap(quick.notice)
        XCTAssertEqual(notice, .copiedInstead(of: "Slack"))
        XCTAssertTrue(notice.title.contains("copied"))
        XCTAssertTrue(notice.sentence.contains("type a login into Slack"))
        XCTAssertTrue(notice.sentence.contains("Accessibility"))
        XCTAssertEqual(quick.height, 58 + Metrics.quickNotice)
        XCTAssertEqual(access.asked, 0, "macOS's question waits for him to ask for it")

        // Return is the notice's button: the system's question the first
        // time, and the list in System Settings after that.
        XCTAssertTrue(quick.press(try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: UInt16(kVK_Return)))))
        XCTAssertEqual(access.asked, 1)
        XCTAssertEqual(access.opened, 0)
        XCTAssertFalse(quick.isUp)
        XCTAssertNil(quick.notice)
        XCTAssertTrue(defaults.bool(forKey: QuickAccess.askedKey), "and it is written down that it was asked")

        quick.show()
        quick.query = "spotify"
        quick.fill()
        quick.allowTyping()
        XCTAssertEqual(access.asked, 1, "once")
        XCTAssertEqual(access.opened, 1)

        // A letter puts the notice away and the list is back.
        quick.show()
        quick.query = "spotify"
        quick.fill()
        XCTAssertNotNil(quick.notice)
        quick.query = "spot"
        XCTAssertNil(quick.notice)
        XCTAssertEqual(quick.rows.first?.item.name, "Spotify")

        // Granted since: the same key types.
        access.isTrusted = true
        pasteboard.clearContents()
        quick.fill()
        _ = await typist.typing?.value
        XCTAssertFalse(sink.keys.isEmpty)
        XCTAssertNil(copied)
    }

    // MARK: A login with no username

    private func plainReturn() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: UInt16(kVK_Return)))
    }

    func testALoginWithNoUsernameIsNotTypedAndThePanelComesBackToSayWhy() async throws {
        let store = await store(nameless: "Spotify")
        let voice = RememberingVoice()
        let (quick, typist) = quickAccess(over: store, in: slack, voice: voice)
        XCTAssertNil(try login("Spotify", in: store).username)
        quick.show()
        quick.query = "spotify"
        let count = pasteboard.changeCount

        XCTAssertTrue(quick.press(try shiftReturn(in: quick.panel)))
        XCTAssertFalse(quick.isUp)
        let outcome = await typist.typing?.value
        XCTAssertEqual(outcome, .needsPasswordField)
        XCTAssertEqual(sink.keys, [])
        XCTAssertTrue(quick.isUp, "it is back, to say why nothing was typed")
        let notice = try XCTUnwrap(quick.notice)
        XCTAssertEqual(notice, .needsPasswordField(in: "Slack"))
        XCTAssertEqual(notice.sentence,
                       "This login has no username, so the caret has to be in a password field in Slack.")
        XCTAssertNil(notice.button, "there is nothing to switch on")
        XCTAssertEqual(voice.said.last, "Nothing typed. " + notice.sentence)
        XCTAssertEqual(quick.height, 58 + Metrics.quickNotice)
        XCTAssertNil(copied, "and nothing is copied in its place")
        XCTAssertEqual(pasteboard.changeCount, count)
        XCTAssertFalse(quick.door.clipboard.isHolding)
        XCTAssertEqual(quick.inFront, slack, "the app a login is typed into is still the one it was")

        // Return puts it away, and asks macOS for nothing.
        XCTAssertTrue(quick.press(try plainReturn()))
        XCTAssertFalse(quick.isUp)
        XCTAssertNil(quick.notice)
        XCTAssertEqual(access.asked, 0)
        XCTAssertEqual(access.opened, 0)
        XCTAssertFalse(defaults.bool(forKey: QuickAccess.askedKey))

        // The caret put in the password's field: the same key types it.
        ground.caret = .secure
        quick.show()
        quick.query = "spotify"
        XCTAssertTrue(quick.fill())
        let second = await typist.typing?.value
        XCTAssertEqual(sink.typed, try XCTUnwrap(try login("Spotify", in: store).password))
        XCTAssertEqual(second, .typed(sink.keys.count))
        XCTAssertFalse(quick.isUp)
        XCTAssertNil(quick.notice)
    }

    /// ⌘\ with one login for the app types with no panel on the screen, so
    /// the panel is what comes up when that login is refused.
    func testTheKeyThatFillsWithoutThePanelBringsItUpForALoginWithNoUsername() async throws {
        let store = await store(nameless: "Spotify")
        let (quick, typist) = quickAccess(over: store, in: spotify)
        quick.autofill()
        XCTAssertFalse(quick.isUp, "one login for the app: it does not stop at the panel")
        let outcome = await typist.typing?.value
        XCTAssertEqual(outcome, .needsPasswordField)
        XCTAssertEqual(sink.keys, [])
        XCTAssertTrue(quick.isUp)
        XCTAssertEqual(quick.notice, .needsPasswordField(in: "Spotify"))
        XCTAssertNil(copied)

        // The notice goes with the vault, as the panel does.
        await store.lock()
        XCTAssertFalse(quick.isUp)
        XCTAssertNil(quick.notice)
    }

    func testALockBeforeTheRefusalLeavesThePanelDown() async throws {
        let store = await store(nameless: "Spotify")
        let (quick, typist) = quickAccess(over: store, in: slack)
        quick.show()
        quick.query = "spotify"
        // Slack is not in front yet, so the typist is still waiting when
        // the vault locks.
        ground.frontPID = nil
        var locking: Task<Void, Never>?
        onPause = { _ in
            guard locking == nil else { return }
            locking = Task { await store.lock() }
            await locking?.value
        }
        XCTAssertTrue(quick.fill())
        let outcome = await typist.typing?.value
        XCTAssertEqual(outcome, .stopped(0))
        XCTAssertFalse(quick.isUp)
        XCTAssertNil(quick.notice)
        XCTAssertEqual(sink.keys, [])
    }

    // MARK: An item that asks

    func testAnItemThatAsksIsAnsweredForBeforeAKeyGoes() async throws {
        let store = await store()
        let authoriser = FakeAuthoriser()
        let (quick, typist) = quickAccess(over: store, in: slack, authoriser: authoriser)
        let reprompt = try XCTUnwrap(quick.door.reprompt)
        quick.show()
        quick.query = "github"
        XCTAssertEqual(quick.rows.first?.item.name, "GitHub")
        let github = try login("GitHub", in: store)

        authoriser.answer = false
        XCTAssertTrue(quick.fill())
        XCTAssertFalse(quick.isUp, "the panel goes before the question comes")
        await reprompt.asking?.value
        XCTAssertEqual(authoriser.asked, [.fill])
        XCTAssertNil(typist.typing, "a no types nothing")
        XCTAssertEqual(sink.keys, [])

        authoriser.answer = true
        quick.show()
        quick.query = "github"
        quick.fill()
        XCTAssertEqual(sink.keys, [])
        await reprompt.asking?.value
        _ = await typist.typing?.value
        XCTAssertEqual(sink.typed, try XCTUnwrap(github.username) + "\t" + (try XCTUnwrap(github.password)))
        XCTAssertNil(copied)
    }

    // MARK: The lock

    func testALockStopsWhatIsBeingTypedAndForgetsTheApp() async throws {
        let store = await store()
        let (quick, typist) = quickAccess(over: store, in: slack)
        quick.show()
        quick.query = "spotify"
        var locking: Task<Void, Never>?
        onPause = { [sink] _ in
            guard sink?.keys.count == 2, locking == nil else { return }
            locking = Task { await store.lock() }
            await locking?.value
        }
        XCTAssertTrue(quick.fill())
        let outcome = await typist.typing?.value
        XCTAssertEqual(outcome, .stopped(2))
        XCTAssertEqual(sink.keys.count, 2)
        XCTAssertEqual(store.state, .locked)
        XCTAssertNil(quick.inFront)
        XCTAssertFalse(Instruments.live.contains { $0.owner == "Fill" })

        onPause = nil
        await store.unlock(password: SecretBytes(DemoVault.password))
        await store.indexing?.value
        sink.forget()
        quick.query = "spotify"
        XCTAssertFalse(quick.fill(), "nothing is typed into the app from before the lock")
        XCTAssertEqual(sink.keys, [])
    }

    func testALockUnderTheQuestionTypesNothingAfterIt() async throws {
        let store = await store()
        let authoriser = FakeAuthoriser()
        authoriser.holds = true
        let (quick, typist) = quickAccess(over: store, in: slack, authoriser: authoriser)
        quick.show()
        quick.query = "github"
        quick.fill()
        for _ in 0..<1000 where authoriser.asked.isEmpty { await Task.yield() }
        XCTAssertEqual(authoriser.asked, [.fill])
        await store.lock()
        authoriser.release(true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(typist.typing)
        XCTAssertEqual(sink.keys, [])
    }

    // MARK: ⌘\

    func testTheKeyFillsTheOneLoginForTheAppInFrontWithoutThePanel() async throws {
        let store = await store()
        let (quick, typist) = quickAccess(over: store, in: spotify)
        let actions = HotKeyActions(quick: quick, door: quick.door, lock: LockCommands(door: quick.door)) {}
        let login = try login("Spotify", in: store)

        actions.perform(.fill)
        XCTAssertFalse(quick.isUp, "it does not stop at the panel")
        XCTAssertEqual(quick.inFront, spotify)
        _ = await typist.typing?.value
        XCTAssertEqual(sink.typed, try XCTUnwrap(login.username) + "\t" + (try XCTUnwrap(login.password)))
        XCTAssertEqual(sink.pids, [spotify.pid])
        XCTAssertNil(copied)
    }

    func testTheKeyOpensThePanelWhenThereIsNotExactlyOne() async throws {
        // A second login on Spotify's site, beside the demo's own.
        let first = try XCTUnwrap(DemoVault.objects().items.first { $0["name"]?.string == "Spotify" })
        let second = first.setting(["id"], to: .string(UUID().uuidString.lowercased()))
            .setting(["name"], to: .string("Spotify (aile)"))
        let store = await store(with: [second])
        let (none, noTypist) = quickAccess(over: store, in: FrontApp(pid: 9, bundleID: "invalid.example", name: "Nix"))
        none.autofill()
        XCTAssertTrue(none.isUp, "nothing for this app: the panel, on what was used last")
        XCTAssertNil(noTypist.typing)
        none.autofill()
        XCTAssertFalse(none.isUp, "and the key again puts it away")

        let (several, typist) = quickAccess(over: store, in: spotify)
        several.autofill()
        XCTAssertTrue(several.isUp, "two logins: he chooses")
        XCTAssertEqual(Set(several.rows.prefix(2).map(\.item.name)), ["Spotify", "Spotify (aile)"])
        XCTAssertEqual(several.headings[0], "Spotify")
        XCTAssertNil(typist.typing)
        XCTAssertEqual(sink.keys, [])
    }

    func testTheKeyOverAShutVaultIsTheLockAndTypesNothing() async {
        let store = VaultStore(backend: FakeBackend(items: [], folders: [], password: "right"))
        let (quick, typist) = quickAccess(over: store, in: spotify)
        quick.autofill()
        XCTAssertTrue(quick.isUp)
        XCTAssertFalse(quick.isOpen)
        XCTAssertNil(typist.typing)
    }

    func testOverABrowserThePanelComesUpAndGoesWhenThePageHasOneLogin() async throws {
        let store = await store()
        let (quick, typist) = quickAccess(over: store, in: safari, tab: "https://github.com/login")
        let github = try login("GitHub", in: store)
        quick.autofill()
        XCTAssertTrue(quick.isUp, "the key does not wait for the browser")
        XCTAssertNil(typist.typing)
        await quick.askingTab?.value
        XCTAssertFalse(quick.isUp)
        _ = await typist.typing?.value
        XCTAssertEqual(sink.typed, try XCTUnwrap(github.username) + "\t" + (try XCTUnwrap(github.password)))
        XCTAssertEqual(sink.pids, [safari.pid])
    }

    func testOverABrowserNothingIsFilledOnceHeHasMovedOrWhenThePanelCameByItsOwnKey() async throws {
        let store = await store()
        let (moved, typist) = quickAccess(over: store, in: safari, tab: "https://github.com/login")
        moved.autofill()
        moved.move(by: 1)
        await moved.askingTab?.value
        XCTAssertTrue(moved.isUp)
        XCTAssertNil(typist.typing)
        moved.close()

        let (own, ownTypist) = quickAccess(over: store, in: safari, tab: "https://github.com/login")
        own.show()
        await own.askingTab?.value
        XCTAssertTrue(own.isUp, "⌥⌘\\ suggests and fills nothing")
        XCTAssertEqual(own.rows.first?.item.name, "GitHub")
        XCTAssertNil(ownTypist.typing)
    }

    func testTheAppThatWasInFrontAtTheKeyIsTheOnlyOneTypedInto() async throws {
        let store = await store()
        let (quick, typist) = quickAccess(over: store, in: spotify)
        // Between the key and the first event, another app has come up.
        ground.frontPID = slack.pid
        quick.autofill()
        let outcome = await typist.typing?.value
        XCTAssertEqual(outcome, .notInFront(0))
        XCTAssertEqual(sink.keys, [])
        XCTAssertNil(copied)
    }

    // MARK: The key itself

    func testTheFillsKeyIsCommandBackslashAndIsLetThroughAsADefaultOnly() throws {
        let key = try XCTUnwrap(HotKeyAction.fill.fallback)
        XCTAssertEqual(key.words, "⌘\\")
        XCTAssertEqual(KeyTable[.autofill].strokes.first?.symbols, "⌘\\")
        XCTAssertEqual(KeyTable[.autofill].bound, .hotKey)
        XCTAssertNil(KeyTable[.autofill].waits)
        XCTAssertNil(HotKeyRules.refusal(for: key, taken: ShortcutChoices().all, by: .fill))
        XCTAssertEqual(HotKeyRules.refusal(for: key, taken: [:], by: .showApp), .notEnoughModifiers,
                       "⌘ alone is still nobody else's to take")
        XCTAssertEqual(HotKeyRules.refusal(for: HotKey(key: UInt32(kVK_ANSI_K), carbon: UInt32(cmdKey)), taken: [:],
                                           by: .fill), .notEnoughModifiers)
        XCTAssertEqual(HotKeyAction.allCases.last, .fill, "the ids Carbon has for the other three have not moved")
    }
}
