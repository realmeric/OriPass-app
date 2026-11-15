import AppKit
import SwiftUI
import XCTest
@testable import OriPass

@MainActor
final class ItemListTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "oripass-list-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    /// A login with a name and nothing else, numbered in the order given.
    private func entries(_ names: [String]) throws -> [Entry] {
        try names.enumerated().map { index, name in
            Entry(try Item(json: .object(["id": .string(String(format: "id-%03d", index)), "type": .int(1),
                                          "name": .string(name)])))
        }
    }

    private func backend(_ vault: (items: [JSONValue], folders: [JSONValue]) = DemoVault.objects()) -> FakeBackend {
        let backend = FakeBackend(items: vault.items, folders: vault.folders, password: DemoVault.password)
        // Synced a minute ago, so no sync is running behind the panes.
        backend.lastSync = Date().addingTimeInterval(-60)
        return backend
    }

    private func unlocked(_ backend: FakeBackend) async -> VaultStore {
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        return store
    }

    private func hosted(_ panes: Panes) -> NSWindow {
        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: PanesView(panes: panes))
        window.setContentSize(Metrics.windowSize)
        window.layoutIfNeeded()
        return window
    }

    private func turn(_ seconds: Double = 0.05) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func views<Wanted: NSView>(_ type: Wanted.Type, in view: NSView?) -> [Wanted] {
        guard let view else { return [] }
        return ((view as? Wanted).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    private func key(_ characters: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                       windowNumber: 0, context: nil, characters: characters,
                                       charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
    }

    // MARK: By title

    func testSortedByTitleTheOrderIsTurkishAndBlindToCaseAndAccents() throws {
        let names = ["Zeytin", "İş Bankası", "ilk", "Şirket", "Ilgaz", "ısı", "Dükkan", "Özel", "Sanat", "çay",
                     "cam 2", "Cam", "eczane", "Éclair", "Okul", "Vault 10", "Vault 9", "9 Eylül", "ÇAY"]
        let list = ItemList(try entries(names), category: .all, sort: ItemList.Sort(), filter: "")
        XCTAssertEqual(list.entries.map(\.item.name), [
            "9 Eylül", "Cam", "cam 2", "çay", "ÇAY", "Dükkan", "Éclair", "eczane", "Ilgaz", "ısı", "ilk",
            "İş Bankası", "Okul", "Özel", "Sanat", "Şirket", "Vault 9", "Vault 10", "Zeytin",
        ])
        XCTAssertEqual(list.sections.map(\.heading),
                       ["#", "C", "Ç", "D", "E", "I", "İ", "O", "Ö", "S", "Ş", "V", "Z"])
        XCTAssertEqual(list.sections.first { $0.heading == "İ" }?.entries.map(\.item.name), ["ilk", "İş Bankası"])
        XCTAssertEqual(list.sections.first { $0.heading == "E" }?.entries.map(\.item.name), ["Éclair", "eczane"])

        // Blind: a capital and an accent make no difference to where a title
        // is filed, and the Turkish letters are not accents.
        XCTAssertEqual(ItemList.filed("İŞ BANKASI"), ItemList.filed("iş bankası"))
        XCTAssertEqual(ItemList.filed("ISI"), "ısı")
        XCTAssertEqual(ItemList.filed("Kâr"), ItemList.filed("kar"))
        XCTAssertNotEqual(ItemList.filed("şal"), ItemList.filed("sal"))
        XCTAssertEqual(ItemList.initial(of: "iyzico"), "İ")
        XCTAssertEqual(ItemList.initial(of: "ılgaz"), "I")

        let backwards = ItemList(try entries(names), category: .all,
                                 sort: ItemList.Sort(key: .title, isReversed: true), filter: "")
        XCTAssertEqual(backwards.entries.map(\.id), list.entries.reversed().map(\.id))
        XCTAssertEqual(backwards.sections.map(\.heading), list.sections.reversed().map(\.heading))
    }

    func testInTheDemoIsBankasiSitsUnderDottedI() async throws {
        let panes = Panes(store: await unlocked(backend()))
        XCTAssertEqual(panes.sort, ItemList.Sort(key: .title, isReversed: false))
        let section = try XCTUnwrap(panes.list.sections.first { $0.heading == "İ" })
        XCTAssertEqual(section.entries.map(\.item.name), ["İSKİ", "İş Bankası", "iyzico"])
        XCTAssertEqual(panes.list.entries.count, panes.listed.count)
        XCTAssertEqual(Set(panes.list.entries.map(\.id)), Set(panes.listed.map(\.id)))
    }

    // MARK: By date

    func testSortedByDateModifiedNewestFirstTheHeadingsAreMonthsInOrder() async throws {
        let panes = Panes(store: await unlocked(backend()), calendar: utc)
        panes.order(by: .modified)
        let list = panes.list
        XCTAssertEqual(list.entries.count, panes.listed.count)

        let dates = try list.entries.map { try XCTUnwrap($0.item.revised) }
        XCTAssertEqual(dates, dates.sorted(by: >))

        let formatter = DateFormatter()
        formatter.calendar = utc
        formatter.timeZone = utc.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "LLLL yyyy"
        var months: [Date] = []
        for section in list.sections {
            XCTAssertEqual(section.heading, section.heading.uppercased())
            let month = try XCTUnwrap(formatter.date(from: section.heading.capitalized), section.heading)
            months.append(month)
            for entry in section.entries {
                let revised = try XCTUnwrap(entry.item.revised)
                XCTAssertTrue(utc.isDate(revised, equalTo: month, toGranularity: .month),
                              "\(entry.id) is under \(section.heading)")
            }
        }
        // Each month once, the newest at the top.
        XCTAssertGreaterThan(months.count, 3)
        XCTAssertEqual(months, Array(Set(months)).sorted(by: >))
        // The demo's newest item was changed on its epoch, late in September 2026.
        XCTAssertEqual(list.sections.first?.heading, "SEPTEMBER 2026")

        panes.order(reversed: true)
        XCTAssertEqual(panes.list.entries.map(\.id), list.entries.reversed().map(\.id))
        XCTAssertEqual(panes.list.sections.map(\.heading), list.sections.reversed().map(\.heading))

        panes.order(by: .created)
        let created = try panes.list.entries.map { try XCTUnwrap($0.item.created) }
        XCTAssertEqual(created, created.sorted(by: >), "a key starts newest first, whatever the last one was left at")
    }

    func testAnItemWithNoDateComesLastUnderItsOwnHeading() throws {
        let dated = try Item(json: .object(["id": .string("a"), "type": .int(1), "name": .string("Dated"),
                                            "revisionDate": .string("2025-03-12T16:41:03.000Z")]))
        let undated = try Item(json: .object(["id": .string("b"), "type": .int(1), "name": .string("Undated")]))
        for reversed in [false, true] {
            let list = ItemList([Entry(undated), Entry(dated)], category: .all,
                                sort: ItemList.Sort(key: .modified, isReversed: reversed), filter: "",
                                calendar: utc)
            XCTAssertEqual(list.sections.map(\.heading), ["MARCH 2025", "NO DATE"])
        }
    }

    // MARK: The second line

    func testTheSecondLineIsWhatTheLookFileSaysForEachType() async throws {
        let store = await unlocked(backend())
        func line(_ name: String) throws -> String? {
            try XCTUnwrap(store.shelves.all.first { $0.item.name == name }, name).item.secondLine
        }
        XCTAssertEqual(try line("GitHub"), "deniz@kanarya.invalid")
        XCTAssertEqual(try line("Bonus Kart"), "Mastercard •••• 9903")
        XCTAssertEqual(try line("Maximum"), "Visa •••• 1486")
        XCTAssertEqual(try line("Şirket Amex"), "Amex •••• 0126")
        XCTAssertEqual(try line("Deniz Yılmaz"), "Deniz Yılmaz")
        XCTAssertEqual(try line("Kombi servis notu"), "Servis her ekim ayında gelir.")
        XCTAssertEqual(try line("Sunucu anahtarı"), "SHA256:DemoDemoDemoDemoDemoDemoDemoDemoDemoDemoDem")
        // No username, no note, a type this app does not know: a title alone.
        XCTAssertNil(try line("Ev Wi-Fi"))
        XCTAssertNil(try line("Boş not"))
        XCTAssertNil(try line("Ehliyet"))
    }

    func testTheSecondLineNeverShowsAHiddenValue() async throws {
        let store = await unlocked(backend())
        // Everything the details hide: passwords, card numbers and their
        // codes, one-time secrets, hidden fields, keys and the numbers on an
        // identity. A username and a note are shown where they are, so the
        // two canaries that stand for those are not in this list.
        let hidden = DemoVault.canaries.filter { $0 != DemoVault.usernameDomain && $0 != DemoVault.note }
        let all = store.shelves.all + store.shelves.archive + store.shelves.trash
        XCTAssertGreaterThanOrEqual(all.count, 40)
        for entry in all {
            let line = entry.item.secondLine ?? ""
            for secret in hidden {
                XCTAssertFalse(line.contains(secret), "\(entry.id) shows a hidden value")
            }
            if case .card(let card) = entry.item.payload {
                let number = try XCTUnwrap(card.number)
                XCTAssertEqual(line, "\(try XCTUnwrap(card.brand)) •••• \(number.suffix(4))")
                XCTAssertEqual(line.filter(\.isNumber).count, 4)
            }
        }
        // A number too short to have a last four shows none of itself.
        let short = try Item(json: .object(["id": .string("c"), "type": .int(3), "name": .string("Short"),
                                            "card": .object(["brand": .string("Visa"), "number": .string("4111")])]))
        XCTAssertEqual(short.secondLine, "Visa")

        // Six digits behind four dots would be two hidden and four shown. The
        // details hide a number that short whole, and the list says what
        // they say: one function decides for both.
        let six = try Item(json: .object(["id": .string("s"), "type": .int(3), "name": .string("Six"),
                                          "card": .object(["brand": .string("Visa"), "number": .string("123456")])]))
        XCTAssertEqual(six.secondLine, "Visa")
        XCTAssertNil(Card.lastFour(of: "123456"))
        XCTAssertNil(Card.lastFour(of: "1234 567"))
        XCTAssertEqual(Card.lastFour(of: "1234 5678"), "5678")
        let row = try XCTUnwrap(ItemDetail(item: six, vault: .personal).main.first { $0.label == "number" })
        XCTAssertEqual(row.spoken, ItemDetail.concealed)
        XCTAssertTrue(row.isHidden)
    }

    // MARK: The category and the filter

    func testACategoryListsItsTypeAndTheCaptionCountsWhatIsListed() async {
        let panes = Panes(store: await unlocked(backend()))
        XCTAssertEqual(panes.list.caption, "\(panes.listed.count) ITEMS SORTED BY")
        var seen = 0
        for category in ItemList.Category.allCases where category != .all {
            panes.choose(category)
            XCTAssertFalse(panes.list.isEmpty, category.name)
            XCTAssertTrue(panes.list.entries.allSatisfy { $0.item.type == category.type }, category.name)
            seen += panes.list.entries.count
        }
        // The one the demo has of a type this app does not know is in All
        // Categories and in none of the five.
        XCTAssertEqual(seen, panes.listed.count - 1)
        panes.choose(.card)
        XCTAssertEqual(panes.list.caption, "3 ITEMS SORTED BY")
        panes.select(.vault(.personal))
        XCTAssertEqual(panes.list.caption, "1 ITEM SORTED BY")
        XCTAssertEqual(ItemList.Category.allCases.map(\.name),
                       ["All Categories", "Logins", "Secure Notes", "Credit Cards", "Identities", "SSH Keys"])
    }

    func testTheFilterNarrowsTheListWhereItStandsAndGoesWhenItIsPutAway() async {
        let panes = Panes(store: await unlocked(backend()))
        let whole = panes.list.entries.count
        panes.filter = "kar"
        XCTAssertEqual(panes.list.entries.count, whole, "nothing filters until the field is up")

        panes.beginFilter()
        XCTAssertEqual(panes.list.entries.map(\.item.name), ["Bonus Kart", "Yurtiçi Kargo"])
        panes.filter = "IS"
        XCTAssertFalse(panes.list.entries.contains { $0.item.name == "İş Bankası" }, "I is ı, as he reads it")
        panes.filter = "İŞ"
        XCTAssertTrue(panes.list.entries.contains { $0.item.name == "İş Bankası" })
        // The grey line is searched too.
        panes.filter = "mastercard"
        XCTAssertEqual(panes.list.entries.map(\.item.name), ["Bonus Kart"])
        panes.filter = "zzz"
        XCTAssertTrue(panes.list.isEmpty)

        XCTAssertTrue(panes.dismiss())
        XCTAssertFalse(panes.isFiltering)
        XCTAssertEqual(panes.filter, "")
        XCTAssertEqual(panes.list.entries.count, whole)
        XCTAssertFalse(panes.dismiss())
    }

    // MARK: The keys

    func testDownAndUpMoveTheSelectionAndStopAtTheEnds() async {
        let panes = Panes(store: await unlocked(backend()))
        let rows = panes.list.entries
        XCTAssertNil(panes.selectedItem)
        panes.moveSelection(by: 1)
        XCTAssertTrue(panes.selectedItem === rows[0])
        panes.moveSelection(by: 1)
        XCTAssertTrue(panes.selectedItem === rows[1])
        panes.moveSelection(by: -1)
        panes.moveSelection(by: -1)
        XCTAssertTrue(panes.selectedItem === rows[0])

        panes.select(item: nil)
        panes.moveSelection(by: -1)
        XCTAssertTrue(panes.selectedItem === rows[rows.count - 1])
        panes.moveSelection(by: 1)
        XCTAssertTrue(panes.selectedItem === rows[rows.count - 1])
    }

    func testAFewTypedLettersJumpToTheFirstTitleThatStartsWithThem() async {
        var clock = Date(timeIntervalSince1970: 1_000)
        let panes = Panes(store: await unlocked(backend()), now: { clock })
        XCTAssertTrue(panes.type("g"))
        XCTAssertEqual(panes.selectedItem?.item.name, "Garanti BBVA")
        clock += 0.3
        XCTAssertTrue(panes.type("i"))
        XCTAssertEqual(panes.selectedItem?.item.name, "Git imza anahtarı")
        clock += 0.3
        XCTAssertTrue(panes.type("t"))
        clock += 0.3
        XCTAssertTrue(panes.type("H"))
        XCTAssertEqual(panes.selectedItem?.item.name, "GitHub")
        clock += 0.3
        XCTAssertFalse(panes.type("q"), "no title starts with githq")
        XCTAssertEqual(panes.selectedItem?.item.name, "GitHub")

        // After a pause the next letter starts a new word.
        clock += Panes.typingPause + 0.1
        XCTAssertTrue(panes.type("ş"))
        XCTAssertEqual(panes.selectedItem?.item.name, "Şirket Amex")
        clock += Panes.typingPause + 0.1
        XCTAssertTrue(panes.type("i"))
        XCTAssertEqual(panes.selectedItem?.item.name, "İSKİ")
    }

    func testTheKeysReachThePanesThroughTheListsOwnView() async throws {
        let panes = Panes(store: await unlocked(backend()))
        let window = hosted(panes)
        try await turn()
        let catcher = try XCTUnwrap(views(ListKeys.Catcher.self, in: window.contentView).first)
        XCTAssertTrue(catcher.acceptsFirstResponder)

        catcher.keyDown(with: try key("\u{F701}"))
        XCTAssertTrue(panes.selectedItem === panes.list.entries[0])
        catcher.keyDown(with: try key("\u{F701}"))
        catcher.keyDown(with: try key("\u{F701}"))
        catcher.keyDown(with: try key("\u{F700}"))
        XCTAssertTrue(panes.selectedItem === panes.list.entries[1])
        catcher.keyDown(with: try key("s"))
        XCTAssertEqual(panes.selectedItem?.item.name, "Slack")
        let chosen = panes.selectedItem
        // A key with ⌘ on it is a menu's and not the list's.
        catcher.keyDown(with: try key("g", modifiers: .command))
        XCTAssertTrue(panes.selectedItem === chosen)

        panes.toggle(.sort)
        catcher.keyDown(with: try key("\u{1B}"))
        XCTAssertNil(panes.openMenu)
        panes.beginFilter()
        catcher.keyDown(with: try key("\u{1B}"))
        XCTAssertFalse(panes.isFiltering)

        // A click on a row asks for the keys, and the list's view takes them.
        XCTAssertTrue(window.firstResponder === catcher, "a window that opens gives the list the keys")
        window.makeFirstResponder(nil)
        panes.click(item: panes.list.entries[4].id)
        try await turn()
        XCTAssertTrue(window.firstResponder === catcher)
    }

    // MARK: The selection

    func testTheSelectionSurvivesASyncAndGoesWithItsItem() async throws {
        let fake = backend()
        let store = await unlocked(fake)
        let panes = Panes(store: store)
        let bank = try XCTUnwrap(panes.list.entries.first { $0.item.name == "İş Bankası" })
        panes.select(item: bank.id)

        // The same vault back: the same row, the very same object.
        fake.incoming = DemoVault.objects()
        await store.sync()
        XCTAssertTrue(panes.selectedItem === bank)

        // Renamed on another device: it moves in the list and stays selected.
        var vault = DemoVault.objects()
        let place = try XCTUnwrap(vault.items.firstIndex { $0["id"]?.string == bank.id })
        vault.items[place] = vault.items[place].setting(["name"], to: .string("Ziraat"))
        fake.incoming = vault
        await store.sync()
        XCTAssertEqual(panes.selectedItem?.id, bank.id)
        XCTAssertEqual(panes.selectedItem?.item.name, "Ziraat")
        XCTAssertEqual(panes.list.entries.last?.id, bank.id)

        // In another row of the sidebar it is not selected, and is again on
        // the way back.
        panes.select(.vault(.personal))
        XCTAssertNil(panes.selectedItem)
        panes.select(.allItems)
        XCTAssertEqual(panes.selectedItem?.id, bank.id)

        vault.items.remove(at: place)
        fake.incoming = vault
        await store.sync()
        XCTAssertNil(panes.selectedItem)
    }

    func testTheListIsArrangedOncePerChangeAndNotPerRead() async {
        let fake = backend()
        let store = await unlocked(fake)
        let panes = Panes(store: store)
        for _ in 0..<50 { _ = panes.list }
        XCTAssertEqual(panes.arrangements, 1)
        panes.moveSelection(by: 1)
        _ = panes.selectedItem
        XCTAssertEqual(panes.arrangements, 1, "a selection is not a new list")
        panes.order(by: .created)
        _ = panes.list
        _ = panes.list
        XCTAssertEqual(panes.arrangements, 2)
        // A sync that brought nothing arranges nothing.
        fake.incoming = DemoVault.objects()
        await store.sync()
        _ = panes.list
        XCTAssertEqual(panes.arrangements, 2)
    }

    // MARK: What is remembered

    func testTheCategoryAndTheOrderAreRememberedAndNothingElseIs() async {
        let store = await unlocked(backend())
        let panes = Panes(store: store, defaults: defaults)
        panes.choose(.login)
        panes.order(by: .modified)
        panes.order(reversed: true)
        panes.beginFilter()
        panes.filter = "git"
        panes.moveSelection(by: 1)

        let next = Panes(store: store, defaults: defaults)
        XCTAssertEqual(next.category, .login)
        XCTAssertEqual(next.sort, ItemList.Sort(key: .modified, isReversed: true))
        XCTAssertFalse(next.isFiltering)
        XCTAssertEqual(next.filter, "")
        XCTAssertNil(next.selectedItem)
        // The settings and no key beside them, and in them three words of
        // the app's own and neither a title nor what he typed.
        let written = defaults.persistentDomain(forName: suite) ?? [:]
        XCTAssertEqual(written.keys.sorted(), [SettingsStore.key])
        let kept = SettingsStore(defaults: defaults).load()
        XCTAssertEqual(kept.list.category, .login)
        XCTAssertEqual(kept.list.sort, .modified)
        XCTAssertTrue(kept.list.isReversed)
        let text = String(decoding: defaults.data(forKey: SettingsStore.key) ?? Data(), as: UTF8.self)
        XCTAssertFalse(text.localizedCaseInsensitiveContains("git"))
    }

    // MARK: In the window

    func testTheWindowSaysTheRowsTheirHeadingsAndTheOpenMenu() async throws {
        let panes = Panes(store: await unlocked(backend()))
        let window = hosted(panes)
        try await turn()
        var words = said(in: window.contentView)
        for word in ["A", "Apple Account", "deniz@kanarya.invalid", "Bonus Kart", "Mastercard •••• 9903",
                     "All Categories", "Sort", "Find in List"] {
            XCTAssertTrue(words.contains(word), "\(word) is not in \(words)")
        }
        XCTAssertFalse(words.contains("Date Modified"), "the menu is drawn shut")

        panes.toggle(.sort)
        try await turn()
        words = said(in: window.contentView)
        for word in ["40 ITEMS SORTED BY", "Title", "Date Created", "Date Modified", "A to Z", "Z to A"] {
            XCTAssertTrue(words.contains(word), "\(word) is not in \(words)")
        }
        panes.order(by: .modified)
        XCTAssertNil(panes.openMenu, "a choice puts the menu away")
        try await turn()
        words = said(in: window.contentView)
        XCTAssertTrue(words.contains("SEPTEMBER 2026"), "\(words)")
        XCTAssertFalse(words.contains("Date Created"))

        panes.toggle(.sort)
        try await turn()
        XCTAssertTrue(said(in: window.contentView).contains("Newest First"))
        panes.toggle(.categories)
        try await turn()
        words = said(in: window.contentView)
        XCTAssertTrue(words.contains("Secure Notes"))
        XCTAssertFalse(words.contains("Newest First"), "one menu at a time")
    }

    func testOptionCommandFPutsTheFieldUp() async throws {
        let store = VaultStore(backend: backend())
        let door = Door(store: store, defaults: defaults)
        let commands = WindowCommands(door: door)
        let item = commands.filterItem()
        XCTAssertEqual(item.keyEquivalent, "f")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .option])
        XCTAssertFalse(commands.validateMenuItem(item), "there is no list behind the lock screen")

        await store.unlock(password: SecretBytes(DemoVault.password))
        XCTAssertTrue(commands.validateMenuItem(item))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(door.panes?.isFiltering, true)
    }

    // MARK: Two thousand

    func testTwoThousandItemsAreArrangedInAFractionOfASecond() async throws {
        let store = await unlocked(backend((ScrollTrace.items(), [])))
        let panes = Panes(store: store, calendar: utc)
        XCTAssertEqual(panes.listed.count, 2000)
        var took: [String: TimeInterval] = [:]
        for key in ItemList.Key.allCases {
            let started = Date()
            panes.order(by: key)
            XCTAssertEqual(panes.list.entries.count, 2000)
            took[key.rawValue] = Date().timeIntervalSince(started)
        }
        print("ItemListTests: 2000 items arranged in",
              took.sorted { $0.key < $1.key }.map { "\($0.key) \(Int($0.value * 1000)) ms" }.joined(separator: ", "))
        XCTAssertLessThan(took.values.max() ?? 1, 0.25)
        XCTAssertTrue(panes.type("ş"))
    }

    // MARK: Where the list stands

    /// The list's scroll view is the one in the middle column.
    private func rows(in window: NSWindow) throws -> NSScrollView {
        let all = views(NSScrollView.self, in: window.contentView)
            .filter { ($0.documentView?.frame.height ?? 0) > $0.frame.height }
        return try XCTUnwrap(all.first, "no list that scrolls")
    }

    /// The top of a row in the stack, from the same two heights the view
    /// counts with.
    private func top(of name: String, in list: ItemList) throws -> CGFloat {
        var above: CGFloat = 0
        for section in list.sections {
            above += Metrics.listHeading
            if let place = section.entries.firstIndex(where: { $0.item.name == name }) {
                return above + CGFloat(place) * Metrics.listRow
            }
            above += CGFloat(section.entries.count) * Metrics.listRow
        }
        throw XCTSkip("no row called \(name)")
    }

    private func assertInView(_ name: String, _ panes: Panes, _ window: NSWindow,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let scroll = try rows(in: window)
        let seen = scroll.documentVisibleRect
        let top = try top(of: name, in: panes.list)
        XCTAssertGreaterThanOrEqual(top, seen.minY, "\(name) is above what the list shows", file: file, line: line)
        // A lazy stack's height is its guess until every row is built, and
        // the guess comes out a few points short of the two heights added
        // up. A list at its very end shows its last row whatever they say.
        let isAtItsEnd = seen.maxY >= (scroll.documentView?.frame.height ?? 0) - 1
            && panes.list.entries.last?.item.name == name
        XCTAssertTrue(top + Metrics.listRow <= seen.maxY || isAtItsEnd,
                      "\(name) ends at \(top + Metrics.listRow), below what the list shows, \(seen.maxY)",
                      file: file, line: line)
    }

    func testAListBuiltWithARowSelectedShowsThatRow() async throws {
        let store = await unlocked(backend())
        // The second screen of rows, the middle, and the very last one.
        for name in ["Ehliyet", "GitHub", "Spotify", "Yurtiçi Kargo"] {
            let panes = Panes(store: store)
            XCTAssertTrue(panes.list.entries.contains { $0.item.name == name }, name)
            panes.select(item: panes.list.entries.first { $0.item.name == name }?.id)
            let window = hosted(panes)
            try assertInView(name, panes, window)
            XCTAssertGreaterThan(try rows(in: window).documentVisibleRect.minY, 0, name)
            try await turn()
            try assertInView(name, panes, window)
        }
        // The first row needs no moving, and nothing selected moves nothing.
        for name in ["Apple Account", nil] {
            let panes = Panes(store: store)
            panes.select(item: panes.list.entries.first { $0.item.name == name }?.id)
            let window = hosted(panes)
            try await turn()
            XCTAssertEqual(try rows(in: window).documentVisibleRect.minY, 0)
        }
    }

    func testAListPutInAnotherOrderStillShowsTheSelectedRow() async throws {
        let panes = Panes(store: await unlocked(backend()))
        let window = hosted(panes)
        try await turn()
        // By title it is on the first screen, and by date it is not.
        let by = ItemList(panes.listed, category: .all, sort: ItemList.Sort(key: .created), filter: "")
        let last = try XCTUnwrap(by.entries.last?.item.name)
        panes.select(item: by.entries.last?.id)
        try await turn()
        try assertInView(last, panes, window)

        panes.order(by: .created)
        try await turn()
        XCTAssertEqual(panes.list.entries.last?.item.name, last)
        try assertInView(last, panes, window)
        XCTAssertGreaterThan(try rows(in: window).documentVisibleRect.minY, 0)

        panes.order(by: .title)
        try await turn()
        try assertInView(last, panes, window)
    }
}
