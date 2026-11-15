import AppKit
import SwiftUI
import XCTest
@testable import OriPass

@MainActor
final class PaneKeysTests: XCTestCase {
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
        Metrics.zoom = Zoom.actual.factor
    }

    private func demo() async -> VaultStore {
        let backend = DemoVault.backend()
        // Synced a minute ago, so no sync is running behind the panes.
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        return store
    }

    private func panes() async -> Panes {
        Panes(store: await demo(), clipboard: Clipboard(pasteboard: pasteboard))
    }

    private func choose(_ title: String, in panes: Panes) throws {
        let entry = try XCTUnwrap(panes.list.entries.first { $0.item.name == title }, "no \(title)")
        panes.click(item: entry.id)
    }

    private func hosted(_ view: some View, width: CGFloat = Metrics.windowSize.width) -> NSWindow {
        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: view)
        window.setContentSize(CGSize(width: width, height: Metrics.windowSize.height))
        window.layoutIfNeeded()
        return window
    }

    private func key(_ characters: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, characters: characters,
                                       charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
    }

    private func catcher(in view: NSView?) -> ListKeys.Catcher? {
        guard let view else { return nil }
        if let found = view as? ListKeys.Catcher { return found }
        return view.subviews.lazy.compactMap { self.catcher(in: $0) }.first
    }

    // MARK: Between the columns

    func testLeftAndRightMoveTheKeysBetweenTheThreeColumns() async throws {
        let panes = await panes()
        XCTAssertEqual(panes.focus, .list)
        XCTAssertFalse(panes.showsFocus, "no ring until a key has moved")

        try choose("GitHub", in: panes)
        panes.press(.right)
        XCTAssertEqual(panes.focus, .details)
        XCTAssertTrue(panes.showsFocus)
        XCTAssertEqual(panes.reading.cursor, "username")
        panes.press(.right)
        XCTAssertEqual(panes.focus, .details, "there is nothing to the right of the details")

        panes.press(.left)
        XCTAssertEqual(panes.focus, .list)
        XCTAssertNil(panes.reading.cursor)
        panes.press(.left)
        XCTAssertEqual(panes.focus, .sidebar)
        panes.press(.left)
        XCTAssertEqual(panes.focus, .sidebar)
        panes.press(.right)
        XCTAssertEqual(panes.focus, .list)
    }

    func testWithNoItemChosenRightChoosesTheFirstAndGoesIntoIt() async throws {
        let panes = await panes()
        panes.press(.right)
        XCTAssertTrue(panes.selectedItem === panes.list.entries[0])
        XCTAssertEqual(panes.focus, .details)
    }

    func testLeftStaysInTheListWhileTheSidebarIsFoldedAway() async throws {
        let panes = await panes()
        let window = hosted(PanesView(panes: panes))
        XCTAssertTrue(panes.sidebarIsOut)
        panes.press(.left)
        XCTAssertEqual(panes.focus, .sidebar)

        // ⇧⌘D takes the sidebar and the keys that were in it.
        panes.toggleSidebar()
        XCTAssertEqual(panes.focus, .list)
        try await Task.sleep(nanoseconds: 100_000_000)
        window.layoutIfNeeded()
        XCTAssertFalse(panes.sidebarIsOut)
        panes.press(.left)
        XCTAssertEqual(panes.focus, .list)

        // And so does a window too narrow for three columns.
        panes.toggleSidebar()
        try await Task.sleep(nanoseconds: 100_000_000)
        window.layoutIfNeeded()
        XCTAssertTrue(panes.sidebarIsOut)
        panes.press(.left)
        XCTAssertEqual(panes.focus, .sidebar)
        window.setContentSize(CGSize(width: Metrics.windowMinimum.width, height: Metrics.windowSize.height))
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(panes.sidebarIsOut)
        XCTAssertEqual(panes.focus, .list)
    }

    // MARK: Within one

    func testUpAndDownInTheSidebarWalkTheRowsAsTheyAreDrawn() async throws {
        let panes = await panes()
        panes.press(.left)
        var walked: [SidebarRow] = [panes.selection]
        for _ in 0..<20 {
            panes.press(.down)
            if panes.selection == walked.last { break }
            walked.append(panes.selection)
        }
        XCTAssertEqual(walked, panes.sidebarRows)
        XCTAssertEqual(walked.first, .allItems)
        XCTAssertEqual(walked.last, .trash)
        XCTAssertTrue(walked.contains(.vault(panes.vaults[0].id)))
        XCTAssertFalse(panes.canGoBack, "a walk with the arrows is one visit")

        panes.press(.up)
        XCTAssertEqual(panes.selection, panes.sidebarRows[panes.sidebarRows.count - 2])
    }

    func testFoldedShutTheArrowsStepOverTheVaults() async throws {
        let panes = await panes()
        panes.selectVault(at: 1)
        panes.toggleVaults()
        panes.press(.left)
        panes.press(.up)
        XCTAssertEqual(panes.selection, .passwordHealth)
        panes.press(.down)
        XCTAssertEqual(panes.selection, panes.lowerRows[0])
        XCTAssertFalse(panes.sidebarRows.contains { if case .vault = $0 { return true } else { return false } })
    }

    func testUpAndDownInTheDetailsWalkTheFieldsThatCanBeCopied() async throws {
        let panes = await panes()
        try choose("GitHub", in: panes)
        let stops = try XCTUnwrap(panes.detail?.stops)
        XCTAssertEqual(stops.first, "username")
        XCTAssertEqual(stops.last, ItemDetail.notesRow)
        XCTAssertTrue(stops.contains(ItemDetail.passwordRow))
        XCTAssertFalse(stops.contains("passkey"), "a passkey's row holds nothing to copy")

        panes.press(.right)
        var walked = [panes.reading.cursor]
        for _ in 1..<stops.count {
            panes.press(.down)
            walked.append(panes.reading.cursor)
        }
        XCTAssertEqual(walked, stops)
        panes.press(.down)
        XCTAssertEqual(panes.reading.cursor, stops.last, "the last field is the end")
        let chosen = panes.selectedItem
        XCTAssertTrue(panes.selectedItem === chosen, "the list did not move under the details")
    }

    // MARK: Return and Space

    func testReturnGoesFromTheSidebarIntoTheListAndFromTheListIntoTheDetails() async throws {
        let panes = await panes()
        panes.press(.left)
        panes.press(.down)
        XCTAssertEqual(panes.selection, .favorites)
        panes.press(.enter)
        XCTAssertEqual(panes.focus, .list)
        XCTAssertTrue(panes.selectedItem === panes.list.entries[0])
        panes.press(.space)
        XCTAssertEqual(panes.focus, .details)
        XCTAssertNotNil(panes.reading.cursor)
    }

    func testReturnOnAFieldCopiesItAndTheValueIsOnThePasteboard() async throws {
        let panes = await panes()
        try choose("GitHub", in: panes)
        panes.press(.right)
        panes.press(.down)
        XCTAssertEqual(panes.reading.cursor, ItemDetail.passwordRow)
        panes.press(.enter)
        XCTAssertEqual(panes.reading.copied, ItemDetail.passwordRow)
        XCTAssertEqual(pasteboard.string(forType: .string), panes.detail?.value(of: ItemDetail.passwordRow))
        XCTAssertFalse(panes.reading.revealed.contains(ItemDetail.passwordRow), "copied, and still under its dots")
        panes.acknowledging?.cancel()
    }

    func testASpaceInsideATypedWordIsALetterAndAfterAPauseItIsReturn() async throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let panes = Panes(store: await demo(), now: { clock })
        let window = hosted(PanesView(panes: panes))
        try await Task.sleep(nanoseconds: 50_000_000)
        let catcher = try XCTUnwrap(catcher(in: window.contentView))

        for letter in ["a", "p", "p", "l", "e", " ", "a"] {
            catcher.keyDown(with: try key(letter))
            clock += 0.1
        }
        XCTAssertEqual(panes.selectedItem?.item.name, "Apple Account")
        XCTAssertEqual(panes.focus, .list)

        clock += Panes.typingPause + 0.1
        catcher.keyDown(with: try key(" "))
        XCTAssertEqual(panes.focus, .details)
        XCTAssertEqual(panes.selectedItem?.item.name, "Apple Account")
    }

    func testTheArrowsReachThePanesThroughTheListsOwnView() async throws {
        let panes = await panes()
        let window = hosted(PanesView(panes: panes))
        try await Task.sleep(nanoseconds: 50_000_000)
        let catcher = try XCTUnwrap(catcher(in: window.contentView))
        catcher.keyDown(with: try key("\u{F701}"))
        catcher.keyDown(with: try key("\u{F703}"))
        XCTAssertEqual(panes.focus, .details)
        catcher.keyDown(with: try key("\u{F702}"))
        catcher.keyDown(with: try key("\u{F702}"))
        XCTAssertEqual(panes.focus, .sidebar)
        catcher.keyDown(with: try key("\r"))
        XCTAssertEqual(panes.focus, .list)
    }

    // MARK: What the pointer and another item do to it

    func testAClickTakesTheRingAndPutsTheKeysWhereItLanded() async throws {
        let panes = await panes()
        try choose("GitHub", in: panes)
        panes.press(.right)
        XCTAssertTrue(panes.showsFocus)

        panes.click(.favorites)
        XCTAssertEqual(panes.focus, .sidebar)
        XCTAssertFalse(panes.showsFocus)
        XCTAssertNil(panes.reading.cursor)
        try choose("Google", in: panes)
        XCTAssertEqual(panes.focus, .list)
    }

    func testAnotherItemTakesTheKeysBackToTheList() async throws {
        let panes = await panes()
        try choose("GitHub", in: panes)
        panes.press(.right)
        panes.press(.down)
        let entry = try XCTUnwrap(panes.list.entries.first { $0.item.name == "Google" })
        panes.select(item: entry.id)
        XCTAssertNil(panes.reading.cursor)
        panes.press(.down)
        XCTAssertEqual(panes.focus, .list)
        XCTAssertNotEqual(panes.selectedItem?.id, entry.id, "the arrow moved the list, not a field")
    }

    // MARK: The three sizes

    func testTheSizeGoesThroughThreeStepsAndScalesMetricsAndFonts() async throws {
        let door = Door(store: await demo(), defaults: defaults)
        let commands = WindowCommands(door: door)
        let menu = NSMenu()
        commands.install(in: menu, before: nil)
        func item(_ key: String) throws -> NSMenuItem {
            try XCTUnwrap(menu.items.compactMap(\.submenu).flatMap(\.items).first {
                $0.keyEquivalent == key && $0.keyEquivalentModifierMask == .command
            })
        }
        func press(_ key: String) throws -> Bool {
            let item = try item(key)
            guard commands.validateMenuItem(item), let action = item.action else { return false }
            return NSApp.sendAction(action, to: item.target, from: item)
        }

        XCTAssertEqual(door.zoom, .actual)
        XCTAssertEqual(Metrics.gap, 12)
        XCTAssertFalse(try press("0"), "it is at its actual size already")

        XCTAssertTrue(try press("+"))
        XCTAssertEqual(door.zoom, .large)
        XCTAssertEqual(Metrics.gap, 14)
        XCTAssertEqual(Metrics.listIcon, 37)
        XCTAssertEqual(Fonts.lockFieldNative.pointSize, 16)
        XCTAssertFalse(try press("+"), "three steps and no fourth")
        XCTAssertEqual(SettingsStore(defaults: defaults).load().look.zoom, .large)

        XCTAssertTrue(try press("-"))
        XCTAssertEqual(door.zoom, .actual)
        XCTAssertTrue(try press("-"))
        XCTAssertEqual(door.zoom, .small)
        XCTAssertEqual(Metrics.gap, 11)
        XCTAssertEqual(Fonts.lockFieldNative.pointSize, 13)
        XCTAssertFalse(try press("-"))

        XCTAssertTrue(try press("0"))
        XCTAssertEqual(door.zoom, .actual)
        XCTAssertEqual(Metrics.zoom, 1)
        XCTAssertEqual(Zoom.allCases.count, 3)
    }

    func testTheSizeIsRememberedAndOnlyTheAppAsksForIt() async throws {
        let store = await demo()
        Door(store: store, defaults: defaults).zoom(to: .small)
        Metrics.zoom = 1

        let next = Door(store: store, defaults: defaults)
        XCTAssertEqual(next.zoom, .actual, "a door is at the actual size until it is told to look")
        XCTAssertEqual(Metrics.zoom, 1)
        next.restoreZoom()
        XCTAssertEqual(next.zoom, .small)
        XCTAssertEqual(Metrics.zoom, Zoom.small.factor)
    }

    func testAnotherSizeDrawsTheWindowAgainAndKeepsWhatItShowed() async throws {
        let door = Door(store: await demo(), defaults: defaults)
        let panes = try XCTUnwrap(door.panes)
        try choose("GitHub", in: panes)
        let window = hosted(DoorView(door: door))
        try await Task.sleep(nanoseconds: 50_000_000)
        let before = try XCTUnwrap(catcher(in: window.contentView))

        door.zoom(to: .large)
        try await Task.sleep(nanoseconds: 100_000_000)
        window.layoutIfNeeded()
        let after = try XCTUnwrap(catcher(in: window.contentView))
        XCTAssertFalse(before === after, "the views were made again at the new size")
        XCTAssertTrue(door.panes === panes)
        XCTAssertEqual(panes.selectedItem?.item.name, "GitHub")
        XCTAssertTrue(said(in: window.contentView).contains("GitHub"))
    }
}
