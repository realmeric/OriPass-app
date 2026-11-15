import AppKit
import SwiftUI
import XCTest
@testable import OriPass

@MainActor
final class HistoryTests: XCTestCase {
    private func demo() async -> VaultStore {
        let backend = DemoVault.backend()
        // Synced a minute ago, so no sync is running behind the panes.
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        return store
    }

    private func id(_ title: String, in panes: Panes) throws -> String {
        try XCTUnwrap(panes.store.shelves.all.first { $0.item.name == title }, "no \(title)").id
    }

    // MARK: The places

    func testBackAndForwardWalkThePlacesInTheOrderTheyWereVisited() {
        var history = History(at: "a")
        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
        XCTAssertNil(history.goBack())
        XCTAssertNil(history.goForward())

        history.visit("b")
        history.visit("c")
        XCTAssertEqual(history.goBack(), "b")
        XCTAssertEqual(history.goBack(), "a")
        XCTAssertNil(history.goBack())
        XCTAssertEqual(history.here, "a")
        XCTAssertEqual(history.goForward(), "b")
        XCTAssertEqual(history.goForward(), "c")
        XCTAssertNil(history.goForward())
        XCTAssertEqual(history.here, "c")
    }

    func testANewVisitCutsOffTheForwardHalf() {
        var history = History(at: "a")
        history.visit("b")
        history.visit("c")
        XCTAssertEqual(history.goBack(), "b")
        XCTAssertTrue(history.canGoForward)

        history.visit("d")
        XCTAssertFalse(history.canGoForward)
        XCTAssertNil(history.goForward())
        XCTAssertEqual(history.goBack(), "b")
        XCTAssertEqual(history.goForward(), "d")
    }

    func testStayingPutIsNotAVisitAndAMoveIsTheSameVisit() {
        var history = History(at: "a")
        history.visit("a")
        XCTAssertFalse(history.canGoBack)

        history.visit("b")
        history.amend("c")
        XCTAssertEqual(history.here, "c")
        XCTAssertEqual(history.behind, ["a"])
        XCTAssertEqual(history.goBack(), "a")
        XCTAssertEqual(history.goForward(), "c")
    }

    func testItForgetsTheOldestPlacePastItsLimit() {
        var history = History(at: 0)
        let limit = History<Int>.limit
        for place in 1...(limit + 20) { history.visit(place) }
        XCTAssertEqual(history.behind.count, limit)
        XCTAssertEqual(history.behind.first, 20)
    }

    // MARK: The window

    func testTheWindowGoesBackToTheRowAndTheItemAndForwardAgain() async throws {
        let panes = Panes(store: await demo())
        XCTAssertFalse(panes.canGoBack)
        XCTAssertFalse(panes.goBack())

        let github = try id("GitHub", in: panes)
        panes.click(item: github)
        panes.select(.favorites)
        let google = try id("Google", in: panes)
        panes.click(item: google)
        panes.select(.trash)
        XCTAssertNil(panes.selectedItem)

        XCTAssertTrue(panes.goBack())
        XCTAssertEqual(panes.selection, .favorites)
        XCTAssertEqual(panes.selectedItem?.id, google)
        XCTAssertTrue(panes.goBack())
        XCTAssertEqual(panes.selection, .favorites)
        XCTAssertEqual(panes.selectedItem?.id, github, "GitHub is a favourite, and came along to the row")
        XCTAssertTrue(panes.goBack())
        XCTAssertEqual(panes.selection, .allItems)
        XCTAssertEqual(panes.selectedItem?.id, github)
        XCTAssertTrue(panes.goBack())
        XCTAssertNil(panes.selectedItem)
        XCTAssertFalse(panes.goBack())

        XCTAssertTrue(panes.canGoForward)
        for _ in 0..<4 { XCTAssertTrue(panes.goForward()) }
        XCTAssertEqual(panes.selection, .trash)
        XCTAssertFalse(panes.goForward())
    }

    func testSomewhereNewAfterGoingBackLeavesNothingToGoForwardTo() async throws {
        let panes = Panes(store: await demo())
        panes.select(.favorites)
        panes.select(.trash)
        XCTAssertTrue(panes.goBack())
        XCTAssertTrue(panes.canGoForward)

        panes.selectVault(at: 0)
        XCTAssertFalse(panes.canGoForward)
        XCTAssertTrue(panes.goBack())
        XCTAssertEqual(panes.selection, .favorites)
    }

    func testAWalkDownTheListWithTheArrowsIsOneVisit() async throws {
        let panes = Panes(store: await demo())
        panes.click(item: panes.list.entries[0].id)
        for _ in 0..<5 { panes.press(.down) }
        let reached = try XCTUnwrap(panes.selectedItem?.id)
        XCTAssertEqual(reached, panes.list.entries[5].id)
        XCTAssertEqual(panes.history.behind.count, 1, "the click, and nothing for the five steps")

        panes.select(.trash)
        XCTAssertTrue(panes.goBack())
        XCTAssertEqual(panes.selectedItem?.id, reached, "back is where the walk ended")
    }

    func testAnItemFoundBySearchIsGoneBackToInAllItems() async throws {
        let store = await demo()
        await store.indexing?.value
        let panes = Panes(store: store)
        panes.selectVault(at: 0)
        let vault = panes.selection
        panes.query = "github"
        panes.submitSearch()
        let found = try XCTUnwrap(panes.selectedItem?.id)

        panes.select(.trash)
        XCTAssertTrue(panes.goBack())
        XCTAssertEqual(panes.selection, .allItems)
        XCTAssertEqual(panes.selectedItem?.id, found)
        XCTAssertEqual(panes.query, "")
        XCTAssertTrue(panes.goBack())
        XCTAssertEqual(panes.selection, vault)
    }

    func testGoingBackToAnItemTheCategoryHidesBringsEveryCategoryBack() async throws {
        let panes = Panes(store: await demo())
        panes.click(item: try id("GitHub", in: panes))
        panes.select(.trash)
        panes.choose(.card)
        XCTAssertTrue(panes.goBack())
        XCTAssertEqual(panes.category, .all)
        XCTAssertEqual(panes.selectedItem?.item.name, "GitHub")
    }

    func testAWindowOfOneItemKeepsNoHistory() async throws {
        let panes = Panes(store: await demo())
        let pinned = panes.pinned(to: try id("GitHub", in: panes))
        pinned.select(.trash)
        XCTAssertFalse(pinned.canGoBack)
    }

    func testTheLockForgetsWhereTheWindowHasBeen() async throws {
        let store = await demo()
        let door = Door(store: store)
        let panes = try XCTUnwrap(door.panes)
        panes.click(item: try id("GitHub", in: panes))
        panes.select(.favorites)
        XCTAssertTrue(panes.canGoBack)
        weak var old = door.panes

        await store.lock()
        XCTAssertNil(door.panes)
        await store.unlock(password: SecretBytes(DemoVault.password))
        let opened = try XCTUnwrap(door.panes)
        XCTAssertFalse(opened === old)
        XCTAssertFalse(opened.canGoBack)
        XCTAssertFalse(opened.canGoForward)
        XCTAssertEqual(opened.history.here, Visit(row: .allItems, item: nil))
    }

    func testTheChevronsAreGreyUntilThereIsSomewhereToGo() async throws {
        let panes = Panes(store: await demo())
        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: PanesView(panes: panes))
        window.setContentSize(Metrics.windowSize)
        window.layoutIfNeeded()
        XCTAssertEqual(enabled("Back", in: window), false)
        XCTAssertEqual(enabled("Forward", in: window), false)

        panes.select(.favorites)
        try await Task.sleep(nanoseconds: 50_000_000)
        window.layoutIfNeeded()
        XCTAssertEqual(enabled("Back", in: window), true)
        XCTAssertEqual(enabled("Forward", in: window), false)

        panes.goBack()
        try await Task.sleep(nanoseconds: 50_000_000)
        window.layoutIfNeeded()
        XCTAssertEqual(enabled("Back", in: window), false)
        XCTAssertEqual(enabled("Forward", in: window), true)
    }

    /// Whether the button accessibility calls `label` can be pressed, and
    /// nil when the window has no such button.
    private func enabled(_ label: String, in window: NSWindow) -> Bool? {
        func find(_ element: Any?, depth: Int = 0) -> Bool? {
            guard let element = element as? NSAccessibilityElementProtocol & NSObjectProtocol, depth < 40 else {
                return nil
            }
            let object = element as AnyObject
            let selector = NSSelectorFromString("accessibilityLabel")
            if object.responds(to: selector),
               object.perform(selector)?.takeUnretainedValue() as? String == label,
               let isEnabled = object.isAccessibilityEnabled?() {
                return isEnabled
            }
            for child in (object as? NSAccessibilityProtocol)?.accessibilityChildren() ?? [] {
                if let found = find(child, depth: depth + 1) { return found }
            }
            return nil
        }
        return find(window.contentView)
    }
}
