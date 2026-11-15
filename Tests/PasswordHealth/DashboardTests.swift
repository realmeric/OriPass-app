import SwiftUI
import XCTest
@testable import OriPass

@MainActor
final class DashboardTests: XCTestCase {
    private func backend() -> FakeBackend {
        let vault = DemoVault.objects()
        let backend = FakeBackend(items: vault.items, folders: vault.folders, password: DemoVault.password)
        // Synced a minute ago, so no sync is running behind the count.
        backend.lastSync = Date().addingTimeInterval(-60)
        return backend
    }

    /// The vault open, searched and counted.
    private func unlocked(_ backend: FakeBackend? = nil) async -> VaultStore {
        let store = VaultStore(backend: backend ?? self.backend())
        await store.unlock(password: SecretBytes(DemoVault.password))
        await store.indexing?.value
        await store.counting?.value
        return store
    }

    private func turn(_ seconds: Double = 0.05) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: The page

    func testThePageCountsTheDemoVault() async throws {
        let store = await unlocked()
        let page = Dashboard(store.watch)
        XCTAssertEqual(page.cards.map(\.kind), [.reused, .weak, .unsecured, .expiring])
        XCTAssertEqual(page.cards.map(\.count), [2, 3, 1, 1])

        // Every login with a password is in one segment, the strongest
        // level first, and a level nobody is at has none.
        let withPasswords = store.shelves.all.filter { $0.item.login?.password?.isEmpty == false }.count
        XCTAssertEqual(page.passwords, withPasswords)
        XCTAssertGreaterThan(page.segments.count, 1)
        XCTAssertEqual(page.segments.map(\.level), page.segments.map(\.level).sorted(by: >))
        XCTAssertTrue(page.segments.allSatisfy { $0.count > 0 })
        let weak = page.segments.filter { Watch.weakLevels.contains($0.level) }.reduce(0) { $0 + $1.count }
        XCTAssertEqual(weak, 3)
        for level in Strength.allCases {
            let counted = store.shelves.all.filter { $0.item.login != nil && $0.strength == level }.count
            XCTAssertEqual(page.segments.first { $0.level == level }?.count ?? 0, counted, level.word)
        }
    }

    func testACardAtNoughtStaysAndAVaultNotCountedYetHasNoNumbers() {
        let clean = Dashboard(levels: [0, 0, 0, 0, 4], counts: [:])
        XCTAssertEqual(clean.cards.map(\.kind), WatchCard.counted)
        XCTAssertEqual(clean.cards.map(\.count), [0, 0, 0, 0])
        // The breach check's card is drawn when it is asked for, and has
        // no number until its answer is in.
        let asked = Dashboard(levels: [0, 0, 0, 0, 4], counts: [:], cards: WatchCard.allCases)
        XCTAssertEqual(asked.cards.map(\.kind), WatchCard.allCases)
        XCTAssertEqual(asked.cards.map(\.count), [nil, 0, 0, 0, nil, 0])
        XCTAssertEqual(clean.segments, [.init(level: .strong, count: 4)])
        XCTAssertEqual(clean.spoken, "4 Strong")

        // Nought is a count, and nobody has counted.
        let early = Dashboard(nil)
        XCTAssertEqual(early.cards.map(\.kind), WatchCard.counted)
        XCTAssertEqual(early.cards.map(\.count), [nil, nil, nil, nil])
        XCTAssertTrue(early.segments.isEmpty)
        XCTAssertEqual(early.spoken, "no passwords")
    }

    func testEveryCardHasItsOwnNameAndSentenceAndNobodyElsesName() {
        XCTAssertEqual(Set(WatchCard.allCases.map(\.title)).count, WatchCard.allCases.count)
        XCTAssertEqual(Set(WatchCard.allCases.map(\.sentence)).count, WatchCard.allCases.count)
        for card in WatchCard.allCases {
            let words = (card.title + " " + card.sentence).lowercased()
            XCTAssertFalse(words.contains("1password") || words.contains("bitwarden"), card.title)
        }
    }

    func testTheWindowDrawsThePageWhereTheListAndTheDetailsWere() async throws {
        let store = await unlocked()
        let panes = Panes(store: store)
        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: PanesView(panes: panes))
        window.setContentSize(Metrics.windowSize)
        window.layoutIfNeeded()
        try await turn()
        XCTAssertFalse(said(in: window.contentView).contains("Password Strength"))

        panes.select(.passwordHealth)
        try await turn()
        let page = said(in: window.contentView)
        XCTAssertTrue(page.contains("Password Strength"), "\(page)")
        XCTAssertTrue(page.contains(Dashboard(store.watch).spoken), "\(page)")
        for card in WatchCard.counted {
            XCTAssertTrue(page.contains(card.title), card.title)
            XCTAssertTrue(page.contains("Show Items, \(card.title)"), card.title)
        }
        // Nobody switched the breach check on.
        XCTAssertFalse(page.contains(WatchCard.vulnerable.title), "\(page)")
        XCTAssertFalse(page.contains("No item selected"))
        XCTAssertFalse(page.contains("No items"))
        // No item's name is on the page: it is counts.
        XCTAssertFalse(page.contains("Trendyol"))

        panes.show(.reused)
        try await turn()
        let listed = said(in: window.contentView)
        XCTAssertFalse(listed.contains("Password Strength"))
        XCTAssertTrue(listed.contains("Reused Passwords"), "\(listed)")
        XCTAssertTrue(listed.contains { $0.contains("Trendyol") }, "\(listed)")
        XCTAssertTrue(listed.contains { $0.contains("Hepsiburada") })
    }

    // MARK: Show Items

    func testShowItemsOnReusedListsTheTwoDemoLoginsAndNothingElse() async throws {
        let store = await unlocked()
        let panes = Panes(store: store)
        // A category that neither of them is in, left over from another row.
        panes.choose(.card)
        panes.select(.passwordHealth)
        XCTAssertTrue(panes.showsDashboard)
        XCTAssertTrue(panes.list.isEmpty)

        panes.show(.reused)
        XCTAssertFalse(panes.showsDashboard)
        XCTAssertEqual(panes.selection, .passwordHealth)
        XCTAssertEqual(panes.watched, .reused)
        XCTAssertEqual(panes.list.entries.map(\.item.name), ["Hepsiburada", "Trendyol"])
        XCTAssertEqual(panes.list.sections.map(\.heading), ["H", "T"])
        // And the category is still his when he leaves.
        XCTAssertEqual(panes.category, .card)

        // The list can be read and filtered like any other.
        panes.select(item: panes.list.entries[1].id)
        XCTAssertEqual(panes.detail?.title, "Trendyol")
        panes.beginFilter()
        panes.filter = "hepsi"
        XCTAssertEqual(panes.list.entries.map(\.item.name), ["Hepsiburada"])
        XCTAssertNil(panes.selectedItem)
    }

    func testEachCardListsWhatItCounted() async throws {
        let store = await unlocked()
        let panes = Panes(store: store)
        let watch = try XCTUnwrap(store.watch)
        for card in WatchCard.counted {
            panes.show(card)
            XCTAssertEqual(Set(panes.list.entries.map(\.id)), Set(watch.entries(of: card).map(\.id)), card.title)
            XCTAssertEqual(panes.list.entries.count, Dashboard(watch).cards.first { $0.kind == card }?.count)
        }
        XCTAssertEqual(panes.list.entries.map(\.item.name), ["Bonus Kart"])
    }

    func testTheRowAgainAndGoingBackAreThePage() async throws {
        let store = await unlocked()
        let panes = Panes(store: store)
        panes.select(.passwordHealth)
        panes.show(.weak)
        let forum = try XCTUnwrap(panes.list.entries.first { $0.item.name == "Eski forum" })
        panes.select(item: forum.id)

        XCTAssertTrue(panes.goBack())
        XCTAssertEqual(panes.watched, .weak)
        XCTAssertNil(panes.selectedItem)
        XCTAssertTrue(panes.goBack())
        XCTAssertTrue(panes.showsDashboard)
        XCTAssertTrue(panes.goBack())
        XCTAssertEqual(panes.selection, .allItems)
        XCTAssertNil(panes.watched)

        XCTAssertTrue(panes.goForward())
        XCTAssertTrue(panes.showsDashboard)
        XCTAssertTrue(panes.goForward())
        XCTAssertTrue(panes.goForward())
        XCTAssertEqual(panes.watched, .weak)
        XCTAssertEqual(panes.selectedItem?.id, forum.id)
        XCTAssertFalse(panes.canGoForward)

        panes.click(.passwordHealth)
        XCTAssertTrue(panes.showsDashboard)
        XCTAssertNil(panes.selectedItem)
        panes.show(.weak)
        panes.select(.favorites)
        XCTAssertNil(panes.watched)
        XCTAssertFalse(panes.showsDashboard)
    }

    func testASearchOverThePageIsTheWholeVaultsAndEndsOnThePage() async throws {
        let store = await unlocked()
        let panes = Panes(store: store)
        panes.select(.passwordHealth)
        panes.query = "git"
        XCTAssertFalse(panes.showsDashboard)
        XCTAssertFalse(panes.list.isEmpty)
        panes.endSearch()
        XCTAssertTrue(panes.showsDashboard)

        // Over a card's items it comes back to them.
        panes.show(.unsecured)
        panes.query = "git"
        XCTAssertFalse(panes.list.entries.contains { $0.item.name == "Eski forum" })
        panes.endSearch()
        XCTAssertEqual(panes.list.entries.map(\.item.name), ["Eski forum"])
    }

    func testACardsListIsTheLastCountAndNotTheOneItWasOpenedOn() async throws {
        let backend = backend()
        let store = await unlocked(backend)
        let panes = Panes(store: store)
        panes.show(.reused)
        let trendyol = try XCTUnwrap(panes.list.entries.first { $0.item.name == "Trendyol" })
        panes.select(item: trendyol.id)
        XCTAssertEqual(panes.list.entries.count, 2)

        // One of the two that share is given a password of its own.
        var vault = DemoVault.objects()
        let place = try XCTUnwrap(vault.items.firstIndex { $0["name"]?.string == "Trendyol" })
        vault.items[place] = vault.items[place].setting(["login", "password"], to: .string("v9#Kq2mT!x7RbW4pZs8L"))
        backend.incoming = vault
        await store.sync()
        // The count before it answers until the new one is in.
        XCTAssertEqual(panes.list.entries.count, 2)
        await store.counting?.value
        try await turn()

        XCTAssertTrue(panes.list.isEmpty)
        XCTAssertNil(panes.selectedItem, "an item no card lists was left in the details")
        XCTAssertEqual(panes.watched, .reused)
        XCTAssertEqual(Dashboard(store.watch).cards.first?.count, 0)
    }

    func testAWindowOfOneItemIsNeverThePage() async throws {
        let store = await unlocked()
        let panes = Panes(store: store)
        let one = panes.pinned(to: try XCTUnwrap(store.shelves.all.first).id)
        one.select(.passwordHealth)
        XCTAssertFalse(one.showsDashboard)
        XCTAssertNotNil(one.selectedItem)
    }

    func testTheLockLeavesThePageNothingToCount() async throws {
        let store = await unlocked()
        let panes = Panes(store: store)
        panes.show(.reused)
        XCTAssertEqual(panes.list.entries.count, 2)
        await store.lock()
        XCTAssertNil(store.watch)
        XCTAssertTrue(panes.listed.isEmpty)
        XCTAssertEqual(Dashboard(store.watch).cards.map(\.count), [nil, nil, nil, nil])
    }

    // MARK: The drawings

    func testEveryCardHasADrawingThatStaysInsideItsRect() {
        let rect = CGRect(origin: CGPoint(x: 10, y: 20), size: Metrics.watchDrawing)
        var seen: Set<String> = []
        for card in WatchCard.allCases {
            let path = WatchDrawing(card: card).path(in: rect)
            XCTAssertFalse(path.isEmpty, card.title)
            XCTAssertTrue(rect.insetBy(dx: -0.5, dy: -0.5).contains(path.boundingRect), "\(card.title) \(path.boundingRect)")
            seen.insert(path.description)
        }
        XCTAssertEqual(seen.count, WatchCard.allCases.count, "two cards have the same drawing")
    }
}
