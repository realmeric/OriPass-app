import SwiftUI
import XCTest
@testable import OriPass

@MainActor
final class BannerTests: XCTestCase {
    private func unlocked() async -> VaultStore {
        let vault = DemoVault.objects()
        let backend = FakeBackend(items: vault.items, folders: vault.folders, password: DemoVault.password)
        // Synced a minute ago, so no sync is running behind the count.
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        await store.counting?.value
        return store
    }

    private func panes(on title: String, _ store: VaultStore) throws -> Panes {
        let panes = Panes(store: store)
        panes.select(item: try XCTUnwrap(store.shelves.all.first { $0.item.name == title }?.id))
        return panes
    }

    // MARK: Which, and in what order

    func testTheOrderNamesEveryCardOnceSoANewCardHasToTakeAPlaceInIt() {
        XCTAssertEqual(Set(WatchCard.seriousFirst), Set(WatchCard.allCases))
        XCTAssertEqual(WatchCard.seriousFirst.count, WatchCard.allCases.count)
    }

    func testAnItemOnOneListHasOneBannerAndOnTwoHasBothTheMoreSeriousFirst() async throws {
        let store = await unlocked()
        XCTAssertEqual(try panes(on: "Trendyol", store).banners.map(\.card), [.reused])
        XCTAssertEqual(try panes(on: "Hepsiburada", store).banners.map(\.card), [.reused])
        XCTAssertEqual(try panes(on: "Çiçeksepeti", store).banners.map(\.card), [.weak])
        XCTAssertEqual(try panes(on: "Bonus Kart", store).banners.map(\.card), [.expiring])

        // On the weak list and the unsecured one, and the card order of the
        // dashboard (weak before unsecured) is not the order it is told in.
        let watch = try XCTUnwrap(store.watch)
        XCTAssertTrue(WatchCard.allCases.firstIndex(of: .weak)! < WatchCard.allCases.firstIndex(of: .unsecured)!)
        XCTAssertEqual(try panes(on: "Eski forum", store).banners.map(\.card), [.unsecured, .weak])

        // Whatever the lists hold, the banners are the cards it is on.
        for entry in store.shelves.all {
            let on = WatchCard.seriousFirst.filter { watch.entries(of: $0).contains { $0.id == entry.id } }
            XCTAssertEqual(watch.banners(for: entry, now: Date()).map(\.card), on, entry.item.name)
        }
    }

    func testAnItemOnNoListHasNoBannerAndNothingIsSaidOnceTheVaultIsLocked() async throws {
        let store = await unlocked()
        let clean = try XCTUnwrap(store.shelves.all.first { entry in
            WatchCard.allCases.allSatisfy { !(store.watch?.entries(of: $0).contains { $0.id == entry.id } ?? false) }
        })
        let panes = Panes(store: store)
        panes.select(item: clean.id)
        XCTAssertTrue(panes.banners.isEmpty, clean.item.name)

        panes.select(item: try XCTUnwrap(store.shelves.all.first { $0.item.name == "Trendyol" }?.id))
        await store.lock()
        XCTAssertTrue(panes.banners.isEmpty)
    }

    // MARK: What they say and what the button does

    func testEachBannerIsOneSentenceAndTheButtonsAreEditUseHttpsAndNone() async throws {
        let store = await unlocked()
        let reused = try panes(on: "Trendyol", store).banners
        XCTAssertEqual(reused.map(\.sentence), [Banner.reused])
        XCTAssertEqual(reused.map(\.act), [.edit])
        XCTAssertEqual(try panes(on: "Çiçeksepeti", store).banners.map(\.act), [.edit])
        XCTAssertEqual(try panes(on: "Eski forum", store).banners.map(\.act), [.secure, .edit])
        XCTAssertEqual(try panes(on: "Eski forum", store).banners.map(\.sentence), [Banner.unsecured, Banner.weak])
        XCTAssertEqual(try panes(on: "Bonus Kart", store).banners.map(\.act), [nil])
        XCTAssertEqual(Banner.Act.edit.name, "Edit")
        XCTAssertEqual(Banner.Act.secure.name, "Use https")
        for sentence in [Banner.reused, Banner.weak, Banner.unsecured, Banner.expired, Banner.expiring] {
            let lowered = sentence.lowercased()
            XCTAssertFalse(lowered.contains("1password") || lowered.contains("bitwarden"), sentence)
            XCTAssertFalse(sentence.contains("\n"), sentence)
        }
    }

    func testACardThatHasRunOutSaysSoAndOneThatWillSaysThat() async throws {
        let store = await unlocked()
        let card = try XCTUnwrap(store.shelves.all.first { $0.item.name == "Bonus Kart" }).item
        guard case .card(let payload) = card.payload,
              let lapse = Watch.lapse(month: payload.expMonth, year: payload.expYear) else {
            return XCTFail("the demo's card has no date")
        }
        let day: TimeInterval = 86_400
        XCTAssertEqual(Banner(.expiring, for: card, now: lapse.addingTimeInterval(day)).sentence, Banner.expired)
        XCTAssertEqual(Banner(.expiring, for: card, now: lapse.addingTimeInterval(-day)).sentence, Banner.expiring)
        XCTAssertNil(Banner(.expiring, for: card, now: lapse).act)
    }

    func testTheHttpsFormKeepsTheRestOfTheAddressAndLeavesTheOthersAlone() {
        XCTAssertEqual(Watch.secured("http://forum.example.org/login"), "https://forum.example.org/login")
        XCTAssertEqual(Watch.secured("  HTTP://Forum.example.org:8080/a?b=c "), "https://Forum.example.org:8080/a?b=c")
        XCTAssertEqual(Watch.secured("https://forum.example.org"), "https://forum.example.org")
        XCTAssertEqual(Watch.secured("forum.example.org"), "forum.example.org")
        XCTAssertEqual(Watch.secured("androidapp://com.example"), "androidapp://com.example")
        XCTAssertFalse(Watch.isUnsecured(Watch.secured("http://a.example")))
    }

    func testUseHttpsOpensTheFormWithTheAddressChangedAndSendsNothing() async throws {
        let store = await unlocked()
        let panes = try panes(on: "Eski forum", store)
        let before = try XCTUnwrap(panes.selectedItem).item.login?.uris.map(\.uri)
        XCTAssertEqual(before, ["http://forum.example.org/login"])

        panes.perform(banner: .secure)
        let editor = try XCTUnwrap(panes.editor)
        XCTAssertEqual(editor.form.addresses.map(\.uri), ["https://forum.example.org/login"])
        XCTAssertTrue(editor.isDirty)
        // The item is as it was until Save, and leaving asks first.
        XCTAssertEqual(try XCTUnwrap(store.entry(id: editor.id)).item.login?.uris.map(\.uri), before)
        panes.cancelEdit()
        XCTAssertTrue(panes.isAskingToDiscard)
        panes.discardEdit()
        XCTAssertNil(panes.editor)
        XCTAssertEqual(panes.banners.map(\.card), [.unsecured, .weak])
    }

    func testEditOpensTheFormAsItWasAndTheBannersLoseTheirButtonsMeanwhile() async throws {
        let store = await unlocked()
        let panes = try panes(on: "Trendyol", store)
        panes.perform(banner: .edit)
        let editor = try XCTUnwrap(panes.editor)
        XCTAssertFalse(editor.isDirty)
        XCTAssertEqual(panes.banners.map(\.act), [nil])
    }

    func testSavingTheSecuredFormTakesTheItemOffTheUnsecuredList() async throws {
        let store = await unlocked()
        let panes = try panes(on: "Eski forum", store)
        panes.perform(banner: .secure)
        await panes.saveEdit()?.value
        await store.counting?.value
        XCTAssertNil(panes.editor)
        XCTAssertEqual(panes.banners.map(\.card), [.weak])
    }

    func testTheBannersAreWorkedOutOncePerItemAndCountAndNotPerRead() async throws {
        let store = await unlocked()
        let panes = try panes(on: "Eski forum", store)
        for _ in 0..<50 { XCTAssertEqual(panes.banners.map(\.card), [.unsecured, .weak]) }
        XCTAssertEqual(panes.tellings, 1)

        // Another item is another look through the lists, and one only.
        panes.select(item: try XCTUnwrap(store.shelves.all.first { $0.item.name == "Trendyol" }?.id))
        for _ in 0..<50 { XCTAssertEqual(panes.banners.map(\.card), [.reused]) }
        XCTAssertEqual(panes.tellings, 2)

        // So is a count, which may have moved the item off a list.
        store.recount()
        await store.counting?.value
        for _ in 0..<50 { _ = panes.banners }
        XCTAssertEqual(panes.tellings, 3)

        // The form takes the buttons, which is the banners made again.
        panes.perform(banner: .edit)
        for _ in 0..<50 { XCTAssertEqual(panes.banners.map(\.act), [nil]) }
        XCTAssertEqual(panes.tellings, 4)
    }

    func testThePageIsMadeOncePerCountAndNotPerRead() async throws {
        let store = await unlocked()
        let panes = Panes(store: store)
        panes.select(.passwordHealth)
        for _ in 0..<50 { XCTAssertEqual(panes.dashboard, Dashboard(store.watch, cards: store.cards)) }
        XCTAssertEqual(panes.pagings, 1)
        store.recount()
        await store.counting?.value
        for _ in 0..<50 { _ = panes.dashboard }
        XCTAssertEqual(panes.pagings, 2)
    }

    // MARK: Drawn

    func testTheDetailsSayItAndTheButtonIsThere() async throws {
        let store = await unlocked()
        let panes = try panes(on: "Eski forum", store)
        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: PanesView(panes: panes))
        window.setContentSize(Metrics.windowSize)
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        let heard = said(in: window.contentView)
        XCTAssertTrue(heard.contains { $0.contains(Banner.unsecured) }, "\(heard)")
        XCTAssertTrue(heard.contains { $0.contains(Banner.weak) })
        XCTAssertTrue(heard.contains("Use https"), "\(heard)")
        XCTAssertTrue(heard.contains("Edit"))
        let first = heard.firstIndex { $0.contains(Banner.unsecured) }
        let second = heard.firstIndex { $0.contains(Banner.weak) }
        XCTAssertLessThan(try XCTUnwrap(first), try XCTUnwrap(second))
    }
}
