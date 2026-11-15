import AppKit
import SwiftUI
import XCTest
@testable import OriPass

@MainActor
final class CopyRevealTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("oripass-test-\(UUID().uuidString)"))
        suite = "oripass-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }

    private func demo() async -> VaultStore {
        let vault = DemoVault.objects()
        let backend = FakeBackend(items: vault.items, folders: vault.folders, password: DemoVault.password)
        // Synced a minute ago, so no sync is running behind the panes.
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        return store
    }

    private func panes(stage: LargeTypeStage? = nil) async -> Panes {
        Panes(store: await demo(), clipboard: Clipboard(pasteboard: pasteboard), stage: stage)
    }

    private func hosted(_ panes: Panes) -> NSWindow {
        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: PanesView(panes: panes))
        window.setContentSize(CGSize(width: Metrics.windowSize.width, height: Metrics.windowSize.height * 2))
        window.layoutIfNeeded()
        return window
    }

    private func turn(_ seconds: Double = 0.05) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @discardableResult
    private func choose(_ title: String, in panes: Panes) throws -> ItemDetail {
        let entry = try XCTUnwrap(panes.list.entries.first { $0.item.name == title }, "no \(title)")
        panes.select(item: entry.id)
        return try XCTUnwrap(panes.detail)
    }

    private var copied: String? { pasteboard.string(forType: .string) }

    // MARK: Revealing

    func testSelectingAnotherItemConcealsEverything() async throws {
        let panes = await panes()
        let window = hosted(panes)
        let bank = try choose("İş Bankası", in: panes)
        let password = try XCTUnwrap(bank.value(of: ItemDetail.passwordRow))
        try await turn()
        XCTAssertFalse(said(in: window.contentView).contains(password))

        panes.toggleRevealed()
        try await turn()
        var words = said(in: window.contentView)
        XCTAssertEqual(panes.reading.revealed, Set(bank.hiddenRows))
        XCTAssertEqual(bank.hiddenRows.count, 2, "the password and the PIN")
        XCTAssertTrue(words.contains(password), "revealed, the row says what it shows")
        XCTAssertTrue(words.contains(DemoVault.hiddenField))
        XCTAssertFalse(words.contains(ItemDetail.concealed))

        try choose("GitHub", in: panes)
        XCTAssertTrue(panes.reading.revealed.isEmpty)
        try choose("İş Bankası", in: panes)
        XCTAssertTrue(panes.reading.revealed.isEmpty, "and coming back does not bring it back")
        try await turn()
        words = said(in: window.contentView)
        XCTAssertFalse(words.contains(password), "\(words.count) words")
        XCTAssertFalse(words.contains(DemoVault.hiddenField))
        XCTAssertEqual(words.filter { $0 == ItemDetail.concealed }.count, 2)
    }

    func testTheKeyShowsEveryHiddenFieldAndThenHidesThemAll() async throws {
        let panes = await panes()
        let bank = try choose("İş Bankası", in: panes)
        XCTAssertTrue(panes.canReveal)
        XCTAssertFalse(panes.isAllRevealed)

        panes.toggleRevealed(ItemDetail.passwordRow)
        XCTAssertEqual(panes.reading.revealed, [ItemDetail.passwordRow])
        XCTAssertFalse(panes.isAllRevealed, "one of two")
        panes.toggleRevealed()
        XCTAssertEqual(panes.reading.revealed, Set(bank.hiddenRows), "one showing: the key shows the rest")
        XCTAssertTrue(panes.isAllRevealed)
        panes.toggleRevealed()
        XCTAssertTrue(panes.reading.revealed.isEmpty)

        panes.toggleRevealed("username")
        XCTAssertTrue(panes.reading.revealed.isEmpty, "a row that hides nothing has nothing to reveal")
        try choose("Kombi servis notu", in: panes)
        XCTAssertFalse(panes.canReveal)
        panes.toggleRevealed()
        XCTAssertTrue(panes.reading.revealed.isEmpty)
    }

    func testACardsNumberIsShownWholeWhenRevealed() async throws {
        let panes = await panes()
        let window = hosted(panes)
        let card = try choose("Bonus Kart", in: panes)
        let number = try XCTUnwrap(card.value(of: "number"))
        XCTAssertTrue(DemoVault.cardNumbers.contains(number))
        try await turn()
        XCTAssertFalse(said(in: window.contentView).contains(number))

        panes.toggleRevealed()
        try await turn()
        let words = said(in: window.contentView)
        XCTAssertTrue(words.contains(number), "\(words.count) words")
        XCTAssertTrue(words.contains(DemoVault.cardCode))
    }

    func testTheSwitchForOptionIsFollowedWhileTheWindowIsOpen() async throws {
        let store = await demo()
        let watchers = { Instruments.live.filter { $0.owner == "Reveal" }.map(\.name) }
        let preferences = Preferences()
        let panes = Panes(store: store, preferences: preferences)
        let bank = try choose("İş Bankası", in: panes)
        XCTAssertEqual(watchers(), [])

        preferences.settings.details.revealWithOption = true
        XCTAssertEqual(watchers(), ["option", "resigned"])
        panes.peek(true)
        XCTAssertTrue(bank.hiddenRows.allSatisfy(panes.reading.shows))

        preferences.settings.details.revealWithOption = false
        XCTAssertEqual(watchers(), [], "and nothing is left listening")
        XCTAssertFalse(panes.reading.isPeeking, "a key held as the switch went off is let go of")

        panes.end()
        preferences.settings.details.revealWithOption = true
        XCTAssertEqual(watchers(), [], "panes that have ended listen for nothing again")
    }

    func testHoldingOptionShowsEverythingOnlyWhileTheSettingIsOn() async throws {
        let store = await demo()
        let watchers = { Instruments.live.filter { $0.owner == "Reveal" }.map(\.name) }
        var off: Panes? = Panes(store: store, defaults: defaults)
        XCTAssertNil(off?.optionWatch)
        XCTAssertEqual(watchers(), [], "nothing listens for a key nobody asked it to listen for")
        off = nil

        Preferences(defaults: defaults).settings.details.revealWithOption = true
        let panes = Panes(store: store, defaults: defaults)
        XCTAssertEqual(watchers(), ["option", "resigned"])
        let bank = try choose("İş Bankası", in: panes)

        panes.peek(true)
        XCTAssertTrue(bank.hiddenRows.allSatisfy(panes.reading.shows))
        XCTAssertTrue(panes.reading.revealed.isEmpty, "held, not revealed")
        panes.peek(false)
        XCTAssertFalse(bank.hiddenRows.contains(where: panes.reading.shows))

        // The app going to the back counts as letting go: the key coming up
        // in another app's window is never heard of here.
        panes.peek(true)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        try await turn()
        XCTAssertFalse(panes.reading.isPeeking)

        XCTAssertTrue(OptionWatch.isHeld(.option))
        XCTAssertTrue(OptionWatch.isHeld([.option, .capsLock]))
        XCTAssertFalse(OptionWatch.isHeld([.option, .command]), "⌥⌘C is a copy")
        XCTAssertFalse(OptionWatch.isHeld([]))

        panes.end()
        XCTAssertEqual(watchers(), [])
    }

    // MARK: Copying

    func testAClickCopiesTheRowAndSaysSoForAMoment() async throws {
        let panes = await panes()
        panes.acknowledgement = 0.1
        let window = hosted(panes)
        let bank = try choose("İş Bankası", in: panes)
        try await turn()
        XCTAssertFalse(said(in: window.contentView).contains("Copied"))

        XCTAssertTrue(panes.copy("username"))
        XCTAssertEqual(copied, "deniz.yilmaz@\(DemoVault.usernameDomain)")
        XCTAssertTrue(pasteboard.types?.contains(Clipboard.concealed) == true, "a username is marked too")
        XCTAssertEqual(panes.reading.copied, "username")
        try await turn()
        XCTAssertTrue(said(in: window.contentView).contains("Copied"))

        await panes.acknowledging?.value
        XCTAssertNil(panes.reading.copied)
        XCTAssertEqual(copied, "deniz.yilmaz@\(DemoVault.usernameDomain)", "the word goes; the copy has its ninety seconds")

        XCTAssertTrue(panes.copy("field-1"))
        XCTAssertEqual(copied, DemoVault.hiddenField, "hidden or not, the row copies what it holds")
        XCTAssertTrue(panes.copy(try XCTUnwrap(bank.websites.first).row))
        XCTAssertEqual(copied, "https://www.isbank.com.tr/giris")
        XCTAssertTrue(panes.copy(ItemDetail.notesRow))
        XCTAssertEqual(copied, bank.item.notes, "the notes as they were typed, brackets and all")

        let before = pasteboard.changeCount
        XCTAssertFalse(panes.copy("field-2"), "a tick holds nothing to paste")
        XCTAssertFalse(panes.copy("field-3"), "nor does a pointer at another field")
        XCTAssertFalse(panes.copy("no-such-row"))
        let github = try choose("GitHub", in: panes)
        XCTAssertTrue(github.main.contains { $0.id == "passkey-0" })
        XCTAssertFalse(panes.copy("passkey-0"), "the day a passkey was made is not a value")
        XCTAssertEqual(pasteboard.changeCount, before)
    }

    func testTheKeysCopyTheUsernameOrTheTypesFirstFieldAndThePassword() async throws {
        let panes = await panes()
        XCTAssertFalse(panes.copyPrimary(), "nothing is selected")
        XCTAssertFalse(panes.copyPassword())

        let bank = try choose("İş Bankası", in: panes)
        XCTAssertTrue(panes.copyPrimary())
        XCTAssertEqual(copied, "deniz.yilmaz@\(DemoVault.usernameDomain)")
        XCTAssertTrue(panes.copyPassword())
        XCTAssertEqual(copied, bank.value(of: ItemDetail.passwordRow))
        XCTAssertEqual(panes.reading.copied, ItemDetail.passwordRow)

        let wifi = try choose("Ev Wi-Fi", in: panes)
        XCTAssertNil(wifi.primaryRow, "a login with no username has no first field to stand in for it")
        XCTAssertFalse(panes.copyPrimary())
        XCTAssertTrue(panes.copyPassword())

        try choose("Bonus Kart", in: panes)
        XCTAssertTrue(panes.copyPrimary())
        XCTAssertTrue(DemoVault.cardNumbers.contains(copied ?? ""), "a card's is its number, whole")
        XCTAssertFalse(panes.copyPassword(), "⇧⌘C is a login's")

        let person = try choose("Deniz Yılmaz", in: panes)
        XCTAssertEqual(person.primaryRow, "name")
        let key = try choose("Sunucu anahtarı", in: panes)
        XCTAssertEqual(key.primaryRow, "public-key")
        let note = try choose("Kombi servis notu", in: panes)
        XCTAssertEqual(note.primaryRow, ItemDetail.notesRow)
        XCTAssertTrue(panes.copyPrimary())
        XCTAssertEqual(copied, note.item.notes)
    }

    func testTheItemMenuIsGreyWhereThereIsNothingForItToDo() async throws {
        let door = Door(store: await demo(), defaults: defaults, clipboard: Clipboard(pasteboard: pasteboard))
        let commands = ItemCommands(door: door)
        let menu = commands.menu()
        let items = Dictionary(uniqueKeysWithValues: menu.items.filter { !$0.isSeparatorItem }.map { ($0.title, $0) })
        let password = try XCTUnwrap(items["Copy Password"])
        let code = try XCTUnwrap(items["Copy One-Time Code"])
        let reveal = try XCTUnwrap(items["Reveal"])
        XCTAssertEqual([password, code, reveal].map(\.keyEquivalent), ["c", "c", "r"])
        XCTAssertEqual([password, code, reveal].map(\.keyEquivalentModifierMask),
                       [[.command, .shift], [.command, .option], .command])
        let panes = try XCTUnwrap(door.panes)

        XCTAssertFalse(commands.canCopy)
        XCTAssertEqual([password, code, reveal].map(commands.validateMenuItem), [false, false, false])

        try choose("İş Bankası", in: panes)
        XCTAssertTrue(commands.canCopy)
        XCTAssertEqual([password, code, reveal].map(commands.validateMenuItem), [true, true, true])
        try choose("Spotify", in: panes)
        XCTAssertEqual([password, code, reveal].map(commands.validateMenuItem), [true, false, true],
                       "a login with no secret has no code to copy")
        try choose("İş Bankası", in: panes)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(reveal.action), to: reveal.target, from: reveal))
        XCTAssertTrue(panes.isAllRevealed)
        XCTAssertTrue(commands.validateMenuItem(reveal))
        XCTAssertEqual(reveal.title, "Conceal")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(password.action), to: password.target, from: password))
        XCTAssertEqual(copied, panes.detail?.value(of: ItemDetail.passwordRow))

        await door.store.lock()
        XCTAssertFalse(commands.canCopy)
        XCTAssertEqual([password, code, reveal].map(commands.validateMenuItem), [false, false, false])
        XCTAssertFalse(commands.copyPrimary())
    }

    // MARK: A row's menu

    func testARowsMenuOffersWhatTheRowCanDo() async throws {
        let stage = RememberingStage()
        var opened: [URL] = []
        let panes = Panes(store: await demo(), open: { opened.append($0) },
                          clipboard: Clipboard(pasteboard: pasteboard), stage: stage)
        let bank = try choose("İş Bankası", in: panes)
        let website = try XCTUnwrap(bank.websites.first).row

        XCTAssertEqual(panes.actions(for: ItemDetail.passwordRow), [.reveal, .largeType, .history])
        XCTAssertEqual(panes.actions(for: "username"), [.largeType])
        XCTAssertEqual(panes.actions(for: website), [.open, .largeType])
        XCTAssertEqual(panes.actions(for: "field-2"), [], "a tick has no menu")
        XCTAssertEqual(panes.actions(for: ItemDetail.notesRow), [])

        panes.toggle(.sort)
        panes.toggleMenu(for: ItemDetail.passwordRow)
        XCTAssertEqual(panes.reading.menu?.row, ItemDetail.passwordRow)
        XCTAssertNil(panes.openMenu, "one menu at a time")
        panes.toggleMenu(for: "field-2")
        XCTAssertNil(panes.reading.menu, "and a row without one shuts whichever was open")

        panes.toggleMenu(for: ItemDetail.passwordRow)
        panes.perform(.reveal, on: ItemDetail.passwordRow)
        XCTAssertNil(panes.reading.menu)
        XCTAssertEqual(panes.reading.revealed, [ItemDetail.passwordRow], "the one row, and not the PIN")
        XCTAssertEqual(panes.actions(for: ItemDetail.passwordRow), [.conceal, .largeType, .history])
        panes.perform(.conceal, on: ItemDetail.passwordRow)
        XCTAssertTrue(panes.reading.revealed.isEmpty)

        panes.perform(.open, on: website)
        XCTAssertEqual(opened.map(\.absoluteString), ["https://www.isbank.com.tr/giris"])

        panes.toggleMenu(for: "username")
        XCTAssertTrue(panes.dismiss(), "Esc shuts it")
        XCTAssertNil(panes.reading.menu)
        panes.toggleMenu(for: "username")
        panes.toggle(.categories)
        XCTAssertNil(panes.reading.menu)
    }

    func testAHoveredRowSaysCopyAndItsMenuIsDrawnOverTheWindow() async throws {
        let panes = await panes()
        let window = hosted(panes)
        try choose("İş Bankası", in: panes)
        try await turn()
        var words = said(in: window.contentView)
        XCTAssertFalse(words.contains("Menu"))
        XCTAssertTrue(words.contains("strength"))

        panes.reading.hovered = ItemDetail.passwordRow
        try await turn()
        words = said(in: window.contentView)
        XCTAssertEqual(words.filter { $0 == "Menu" }.count, 1, "the chevron, on the one row")
        XCTAssertFalse(words.contains("strength"), "the level gives way to the word")
        XCTAssertFalse(words.contains("Reveal"))

        panes.toggleMenu(for: ItemDetail.passwordRow)
        panes.reading.hovered = nil
        try await turn()
        words = said(in: window.contentView)
        XCTAssertTrue(words.contains("Reveal") && words.contains("Show in Large Type"), "\(words.suffix(12))")
        XCTAssertTrue(words.contains("Menu"), "the row stays lit while its menu is open")

        panes.reading.hovered = "field-2"
        panes.reading.menu = nil
        try await turn()
        XCTAssertFalse(said(in: window.contentView).contains("Menu"), "a tick does not light")
    }

    // MARK: Large Type

    func testLargeTypeGoesUpOnARowAndComesDownWithTheSelection() async throws {
        let stage = RememberingStage()
        let panes = await panes(stage: stage)
        let bank = try choose("İş Bankası", in: panes)
        let password = try XCTUnwrap(bank.value(of: ItemDetail.passwordRow))

        panes.perform(.largeType, on: ItemDetail.passwordRow)
        XCTAssertEqual(stage.showing, LargeType(password, row: ItemDetail.passwordRow))
        XCTAssertEqual(panes.reading.largeType?.cells.count, password.count)
        XCTAssertTrue(panes.reading.revealed.isEmpty, "the row itself stays as it was")

        // Esc or a click, which the panel reports.
        stage.close()
        XCTAssertNil(panes.reading.largeType)

        panes.showLargeType(of: "username")
        panes.showLargeType(of: ItemDetail.passwordRow)
        XCTAssertEqual(stage.shows, 3)
        XCTAssertEqual(panes.reading.largeType?.row, ItemDetail.passwordRow, "the second took the first one's place")
        try choose("GitHub", in: panes)
        XCTAssertNil(stage.showing)
        XCTAssertNil(panes.reading.largeType)

        panes.showLargeType(of: "field-2")
        XCTAssertNil(stage.showing, "nothing to spell")
    }

    // MARK: An item that leaves the details

    /// Everything `putAway` puts away, set on the item in the details.
    private func busy(_ panes: Panes, _ stage: RememberingStage) {
        panes.toggleRevealed()
        panes.toggleCreated()
        panes.reading.hovered = "username"
        panes.toggleMenu(for: "username")
        panes.showLargeType(of: ItemDetail.passwordRow)
    }

    private func assertPutAway(_ panes: Panes, _ stage: RememberingStage, _ how: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(panes.reading.revealed.isEmpty, "\(how) left the item revealed", file: file, line: line)
        XCTAssertFalse(panes.showsCreated, how, file: file, line: line)
        XCTAssertNil(panes.reading.hovered, how, file: file, line: line)
        XCTAssertNil(panes.reading.menu, how, file: file, line: line)
        XCTAssertNil(panes.reading.largeType, how, file: file, line: line)
        XCTAssertNil(stage.showing, "\(how) left Large Type up", file: file, line: line)
    }

    /// Spotify is no favourite, no card, and not what "github" finds.
    func testAnItemThatLeavesTheDetailsComesBackConcealed() async throws {
        let ways: [(how: String, leave: (Panes) -> Void, back: (Panes) -> Void)] = [
            ("another row of the sidebar", { $0.select(.favorites) }, { $0.select(.allItems) }),
            ("another category", { $0.choose(.card) }, { $0.choose(.all) }),
            ("a search", { $0.query = "github" }, { $0.query = "" }),
            ("a filter", {
                $0.beginFilter()
                $0.filter = "github"
            }, { $0.endFilter() }),
            ("going back", {
                $0.select(.favorites)
                $0.select(.trash)
            }, {
                $0.goBack()
                $0.goBack()
            }),
        ]
        for way in ways {
            let stage = RememberingStage()
            let panes = await panes(stage: stage)
            await panes.store.indexing?.value
            let spotify = try choose("Spotify", in: panes).id
            busy(panes, stage)
            XCTAssertFalse(panes.reading.revealed.isEmpty)
            XCTAssertNotNil(stage.showing)

            way.leave(panes)
            XCTAssertNil(panes.selectedItem, "\(way.how) should have emptied the details")
            assertPutAway(panes, stage, way.how)

            way.back(panes)
            XCTAssertEqual(panes.selectedItem?.id, spotify, "\(way.how), undone, brings the item back")
            assertPutAway(panes, stage, way.how)
        }
    }

    func testAnItemThatStaysInTheDetailsStaysAsItWas() async throws {
        let stage = RememberingStage()
        let panes = await panes(stage: stage)
        await panes.store.indexing?.value
        let spotify = try choose("Spotify", in: panes)
        panes.toggleRevealed()

        panes.query = "spotify"
        panes.choose(.login)
        panes.order(by: .created)
        XCTAssertEqual(panes.selectedItem?.id, spotify.id)
        XCTAssertEqual(panes.reading.revealed, Set(spotify.hiddenRows), "it never left")
    }

    func testAnItemASyncTakesAwayAndBringsBackComesBackConcealed() async throws {
        var vault = DemoVault.objects()
        let whole = vault
        let backend = FakeBackend(items: vault.items, folders: vault.folders, password: DemoVault.password)
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        let stage = RememberingStage()
        let panes = Panes(store: store, clipboard: Clipboard(pasteboard: pasteboard), stage: stage)
        let spotify = try choose("Spotify", in: panes).id
        busy(panes, stage)

        vault.items.removeAll { $0["id"]?.string == spotify }
        backend.incoming = vault
        await store.sync()
        XCTAssertNil(panes.selectedItem)
        // The panes hear of a sync a turn of the main queue after it.
        try await turn()
        assertPutAway(panes, stage, "a sync")

        backend.incoming = whole
        await store.sync()
        try await turn()
        XCTAssertEqual(panes.selectedItem?.id, spotify)
        assertPutAway(panes, stage, "a sync")
    }

    // MARK: The window and the lock

    func testAWindowPutAwayShowsNothingWhenItComesBack() async throws {
        let stage = RememberingStage()
        let panes = await panes(stage: stage)
        try choose("İş Bankası", in: panes)
        panes.toggleRevealed()
        panes.reading.hovered = "username"
        panes.toggleMenu(for: "username")
        panes.showLargeType(of: ItemDetail.passwordRow)
        panes.copy("username")

        panes.putAway()

        XCTAssertTrue(panes.reading.revealed.isEmpty)
        XCTAssertNil(panes.reading.menu)
        XCTAssertNil(panes.reading.hovered)
        XCTAssertNil(panes.reading.copied)
        XCTAssertNil(panes.reading.largeType)
        XCTAssertNil(stage.showing)
        XCTAssertNotNil(panes.selectedItem, "the item is still the one chosen")
        XCTAssertNotNil(copied, "and what was copied is the clipboard's to take back")
    }

    func testTheLockClearsThePasteboardClosesLargeTypeAndStopsListening() async throws {
        Preferences(defaults: defaults).settings.details.revealWithOption = true
        let stage = RememberingStage()
        let clipboard = Clipboard(pasteboard: pasteboard)
        let door = Door(store: await demo(), defaults: defaults, clipboard: clipboard, stage: stage)
        var panes: Panes? = try XCTUnwrap(door.panes)
        weak var dropped = panes
        let reading = try XCTUnwrap(panes?.reading)
        try choose("İş Bankası", in: try XCTUnwrap(panes))
        panes?.toggleRevealed()
        panes?.copyPassword()
        panes?.showLargeType(of: ItemDetail.passwordRow)
        XCTAssertNotNil(copied)
        XCTAssertNotNil(stage.showing)
        XCTAssertEqual(Instruments.live.filter { $0.owner == "Clipboard" || $0.owner == "Reveal" }.count, 3)
        panes = nil

        await door.store.lock()

        XCTAssertNil(copied, "the lock took the password off the pasteboard")
        XCTAssertFalse(clipboard.isHolding)
        XCTAssertNil(stage.showing)
        XCTAssertNil(reading.largeType)
        XCTAssertTrue(reading.revealed.isEmpty)
        XCTAssertEqual(Instruments.live.filter { $0.owner == "Clipboard" || $0.owner == "Reveal" }.map(\.name), [])
        XCTAssertNil(door.panes)
        XCTAssertNil(dropped, "and nothing the copy started is holding the panes")
    }

    func testTheLockLeavesAnotherAppsCopyAlone() async throws {
        let clipboard = Clipboard(pasteboard: pasteboard)
        let door = Door(store: await demo(), defaults: defaults, clipboard: clipboard)
        try choose("İş Bankası", in: try XCTUnwrap(door.panes))
        door.panes?.copyPassword()
        pasteboard.clearContents()
        pasteboard.setString("a shopping list", forType: .string)

        await door.store.lock()

        XCTAssertEqual(copied, "a shopping list")
    }
}
