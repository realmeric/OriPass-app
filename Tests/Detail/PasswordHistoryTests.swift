import AppKit
import SwiftUI
import XCTest
@testable import OriPass

@MainActor
final class PasswordHistoryTests: XCTestCase {
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
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        return store
    }

    private func panes() async -> Panes {
        Panes(store: await demo(), clipboard: Clipboard(pasteboard: pasteboard))
    }

    private func hosted(_ panes: Panes) -> NSWindow {
        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: PanesView(panes: panes))
        window.setContentSize(CGSize(width: Metrics.windowSize.width, height: Metrics.windowSize.height))
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

    // MARK: The menu

    func testTheEntryIsInThePasswordsMenuOnlyWhenTheItemHasEarlierPasswords() async throws {
        let panes = await panes()
        try choose("İş Bankası", in: panes)
        XCTAssertEqual(panes.actions(for: ItemDetail.passwordRow), [.reveal, .largeType, .history])
        XCTAssertEqual(FieldAction.history.name, "View password history")
        XCTAssertEqual(panes.actions(for: "username"), [.largeType], "the password's menu and no other")
        panes.toggleRevealed(ItemDetail.passwordRow)
        XCTAssertEqual(panes.actions(for: ItemDetail.passwordRow), [.conceal, .largeType, .history])

        // A history that is a null and one that is an empty list are none.
        for title in ["GitHub", "Spotify"] {
            try choose(title, in: panes)
            XCTAssertEqual(panes.actions(for: ItemDetail.passwordRow), [.reveal, .largeType], title)
        }
        panes.showHistory()
        XCTAssertNil(panes.reading.history, "and nothing to open")
    }

    func testChoosingTheEntryRaisesTheSheetAndShutsTheMenu() async throws {
        let panes = await panes()
        try choose("İş Bankası", in: panes)
        panes.toggleMenu(for: ItemDetail.passwordRow)
        XCTAssertNotNil(panes.reading.menu)
        panes.perform(.history, on: ItemDetail.passwordRow)
        XCTAssertNil(panes.reading.menu)
        XCTAssertEqual(panes.reading.history?.title, "İş Bankası")
    }

    // MARK: The list

    func testTheSheetListsTheEarlierPasswordsNewestFirst() async throws {
        let panes = await panes()
        let bank = try choose("İş Bankası", in: panes)
        panes.showHistory()
        let history = try XCTUnwrap(panes.reading.history)
        XCTAssertEqual(history.entries.map(\.password), DemoVault.old)
        XCTAssertEqual(history.entries.map(\.id), [0, 1, 2])
        XCTAssertEqual(bank.item.passwordHistory.map(\.password), DemoVault.old)
        let dates = history.entries.compactMap(\.used)
        XCTAssertEqual(dates.count, 3)
        XCTAssertEqual(dates, dates.sorted(by: >))
        XCTAssertTrue(history.entries.allSatisfy { $0.when.hasPrefix("Last used ") })
        XCTAssertNotEqual(history.entries[0].when, history.entries[1].when)
        XCTAssertTrue(history.revealed.isEmpty)
    }

    func testAnEntryIsPlacedByItsDateWhateverOrderTheItemHeldThem() throws {
        var item = try Fixture.item(named: "İş Bankası")
        let now = Date()
        item.passwordHistory = [
            PasswordHistoryEntry(password: "no-date-first", lastUsed: now),
            PasswordHistoryEntry(password: "old", lastUsed: now.addingTimeInterval(-86_400 * 90)),
            PasswordHistoryEntry(password: "new", lastUsed: now.addingTimeInterval(-86_400)),
            PasswordHistoryEntry(password: "no-date-second", lastUsed: now),
        ]
        item.passwordHistory[0].lastUsedDate = nil
        item.passwordHistory[3].lastUsedDate = "not a date"
        let history = try XCTUnwrap(PasswordHistory(item: item))
        XCTAssertEqual(history.entries.map(\.password), ["new", "old", "no-date-first", "no-date-second"])
        XCTAssertEqual(history.entries.map(\.when).suffix(2), ["Date unknown", "Date unknown"])

        item.passwordHistory = []
        XCTAssertNil(PasswordHistory(item: item))
    }

    func testTheSheetSaysWhatIsWrittenOnItAndNoPasswordUntilOneIsRevealed() async throws {
        let panes = await panes()
        let window = hosted(panes)
        try choose("İş Bankası", in: panes)
        panes.showHistory()
        try await turn()
        var words = said(in: window.contentView)
        XCTAssertTrue(words.contains("Password history"))
        XCTAssertTrue(words.contains("Done"))
        XCTAssertEqual(words.filter { $0 == "Reveal" }.count, 3, "one for each")
        XCTAssertEqual(words.filter { $0 == "Copy" }.count, 3)
        XCTAssertEqual(words.filter { $0 == ItemDetail.concealed }.count, 3 + 2, "and the details' password and PIN")
        for password in DemoVault.old { XCTAssertFalse(words.contains(password)) }

        panes.toggleRevealed(historyEntry: 1)
        try await turn()
        words = said(in: window.contentView)
        XCTAssertTrue(words.contains(DemoVault.old[1]))
        XCTAssertFalse(words.contains(DemoVault.old[0]))
        XCTAssertFalse(words.contains(DemoVault.old[2]))
        XCTAssertEqual(words.filter { $0 == "Conceal" }.count, 1)
        panes.toggleRevealed(historyEntry: 1)
        try await turn()
        XCTAssertFalse(said(in: window.contentView).contains(DemoVault.old[1]))
    }

    func testNothingTheSheetHoldsIsSaidByAPrintOrADump() async throws {
        let panes = await panes()
        try choose("İş Bankası", in: panes)
        panes.showHistory()
        panes.toggleRevealed(historyEntry: 0)
        let history = try XCTUnwrap(panes.reading.history)
        var dumped = ""
        dump(history, to: &dumped)
        let said = [String(describing: history), String(reflecting: history), dumped,
                    String(describing: history.entries), String(reflecting: history.entries)]
        for line in said { XCTAssertFalse(line.contains("CANARY"), line) }
        XCTAssertEqual(String(describing: history), "PasswordHistory(3)")
    }

    // MARK: Copying

    func testACopyIsMarkedAndSaysCopiedForAMoment() async throws {
        let panes = await panes()
        panes.acknowledgement = 0.05
        try choose("İş Bankası", in: panes)
        panes.showHistory()
        XCTAssertTrue(panes.copy(historyEntry: 2))
        XCTAssertEqual(pasteboard.string(forType: .string), DemoVault.old[2])
        XCTAssertNotNil(pasteboard.data(forType: Clipboard.concealed))
        XCTAssertEqual(panes.reading.history?.copied, 2)

        XCTAssertTrue(panes.copy(historyEntry: 0))
        XCTAssertEqual(pasteboard.string(forType: .string), DemoVault.old[0])
        XCTAssertEqual(panes.reading.history?.copied, 0, "one at a time")
        await panes.acknowledging?.value
        XCTAssertNil(panes.reading.history?.copied)
        XCTAssertNotNil(panes.reading.history, "and the sheet stays")

        XCTAssertFalse(panes.copy(historyEntry: 7))
        XCTAssertEqual(pasteboard.string(forType: .string), DemoVault.old[0], "nothing for an entry that is not there")
    }

    func testACopyOfARowAndAnEarlierPasswordDoNotLeaveTwoCopiedBehind() async throws {
        let panes = await panes()
        panes.acknowledgement = 0.05
        try choose("İş Bankası", in: panes)
        panes.copy("username")
        XCTAssertEqual(panes.reading.copied, "username")
        panes.showHistory()
        panes.copy(historyEntry: 1)
        XCTAssertNil(panes.reading.copied)
        XCTAssertEqual(panes.reading.history?.copied, 1)
        await panes.acknowledging?.value
        XCTAssertNil(panes.reading.copied)
        XCTAssertNil(panes.reading.history?.copied)
    }

    // MARK: Putting it away

    func testEscDoneAndAClickBesideItPutTheSheetAway() async throws {
        let panes = await panes()
        let bank = try choose("İş Bankası", in: panes)
        panes.showHistory()
        XCTAssertTrue(panes.dismiss())
        XCTAssertNil(panes.reading.history)

        panes.showHistory()
        XCTAssertTrue(panes.press(.escape))
        XCTAssertNil(panes.reading.history)
        XCTAssertEqual(panes.detail?.id, bank.id)

        panes.showHistory()
        panes.closeHistory()
        XCTAssertNil(panes.reading.history)
        panes.closeHistory()
    }

    func testWhileTheSheetIsUpTheKeysAreItsAndSelectionStays() async throws {
        let panes = await panes()
        let bank = try choose("İş Bankası", in: panes)
        panes.showHistory()
        for key in [PaneKey.down, .up, .left, .right, .enter, .space, .delete] {
            XCTAssertTrue(panes.press(key), "\(key)")
        }
        XCTAssertNotNil(panes.reading.history)
        XCTAssertEqual(panes.detail?.id, bank.id)
        XCTAssertNil(panes.refused)
        XCTAssertFalse(panes.selectedItem?.item.isArchived ?? true, "Delete did not archive it")
    }

    func testAnotherItemAndAFormTakeTheSheetDownAndItsRevealsWithIt() async throws {
        let panes = await panes()
        try choose("İş Bankası", in: panes)
        panes.showHistory()
        panes.toggleRevealed(historyEntry: 0)
        try choose("GitHub", in: panes)
        XCTAssertNil(panes.reading.history)
        try choose("İş Bankası", in: panes)
        XCTAssertNil(panes.reading.history, "and coming back does not bring it back")
        panes.showHistory()
        XCTAssertTrue(try XCTUnwrap(panes.reading.history).revealed.isEmpty)

        XCTAssertTrue(panes.beginEdit())
        XCTAssertNil(panes.reading.history, "a form is not drawn under a sheet")
        panes.cancelEdit()

        panes.showHistory()
        XCTAssertTrue(panes.beginNew())
        XCTAssertNil(panes.reading.history)
        panes.choosing = nil

        panes.showHistory()
        XCTAssertTrue(panes.beginGenerating(for: .alone))
        XCTAssertNil(panes.reading.history)
    }

    func testTheLockTakesTheSheetAndWhatItWasHolding() async throws {
        let store = await demo()
        let door = Door(store: store, defaults: defaults)
        let panes = try XCTUnwrap(door.panes)
        let bank = try XCTUnwrap(panes.list.entries.first { $0.item.name == "İş Bankası" })
        panes.select(item: bank.id)
        panes.showHistory()
        panes.toggleRevealed(historyEntry: 0)
        weak var reading = panes.reading
        XCTAssertNotNil(reading?.history)

        await store.lock()
        XCTAssertNil(door.panes)
        XCTAssertNil(panes.reading.history)
        XCTAssertTrue(panes.reading.revealed.isEmpty)
    }

    // MARK: A window of one item

    func testAWindowOfOneItemHasTheSameMenuAndTheSameSheet() async throws {
        let store = await demo()
        let main = Panes(store: store, clipboard: Clipboard(pasteboard: pasteboard))
        let bank = try XCTUnwrap(main.list.entries.first { $0.item.name == "İş Bankası" })
        let alone = main.pinned(to: bank.id)
        XCTAssertEqual(alone.actions(for: ItemDetail.passwordRow), [.reveal, .largeType, .history])
        alone.perform(.history, on: ItemDetail.passwordRow)
        XCTAssertEqual(alone.reading.history?.entries.map(\.password), DemoVault.old)
        XCTAssertNil(main.reading.history, "the sheet is the window's")
    }
}
