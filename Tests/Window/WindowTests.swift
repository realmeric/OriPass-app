import AppKit
import SwiftUI
import XCTest
@testable import OriPass

@MainActor
final class WindowTests: XCTestCase {
    private func demo() -> VaultStore {
        let backend = DemoVault.backend()
        // Synced a minute ago, so no sync is running behind the panes.
        backend.lastSync = Date().addingTimeInterval(-60)
        return VaultStore(backend: backend)
    }

    /// The panes in a window that is never shown, at a width.
    private func hosted(_ panes: Panes, width: CGFloat) -> NSWindow {
        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: PanesView(panes: panes))
        window.setContentSize(CGSize(width: width, height: Metrics.windowSize.height))
        window.layoutIfNeeded()
        return window
    }

    private func turn(_ seconds: Double = 0.05) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func views<Wanted: NSView>(_ type: Wanted.Type, in view: NSView?) -> [Wanted] {
        guard let view else { return [] }
        return (view as? Wanted).map { [$0] } ?? [] + view.subviews.flatMap { views(type, in: $0) }
    }

    /// The sidebar's material is the one AppKit view in the panes, so its
    /// frame is where the sidebar is.
    private func sidebar(in window: NSWindow) -> NSRect? {
        views(NSVisualEffectView.self, in: window.contentView).first { $0.material == .sidebar }
            .map { $0.convert($0.bounds, to: nil) }
    }

    // MARK: The three widths

    func testAtItsOwnSizeTheWindowHasTheWidthsTheColumnsWouldLike() {
        let layout = PaneLayout(width: Metrics.windowSize.width, wantsSidebar: true)
        XCTAssertEqual(layout.sidebar, Metrics.sidebarWidth)
        XCTAssertEqual(layout.list, Metrics.listWidth)
        XCTAssertEqual(layout.detail, Metrics.windowSize.width - Metrics.sidebarWidth - Metrics.listWidth)
        // The still's proportions: about a quarter, a little more than a
        // quarter, and the rest.
        XCTAssertEqual(layout.sidebar / Metrics.windowSize.width, 0.236, accuracy: 0.01)
        XCTAssertEqual(layout.list / Metrics.windowSize.width, 0.29, accuracy: 0.01)
    }

    func testAtNoWidthTheWindowAllowsDoTwoColumnsOverlapOrGoUnderTheirMinimum() {
        for width in stride(from: Metrics.windowMinimum.width, through: 2400, by: 1) {
            for wantsSidebar in [true, false] {
                let layout = PaneLayout(width: width, wantsSidebar: wantsSidebar)
                // They fill the window and no more, so none lies over another.
                XCTAssertEqual(layout.sidebar + layout.list + layout.detail, width, "at \(width)")
                XCTAssertGreaterThanOrEqual(layout.list, Metrics.listMinimum, "at \(width)")
                XCTAssertGreaterThanOrEqual(layout.detail, Metrics.detailMinimum, "at \(width)")
                if layout.showsSidebar {
                    XCTAssertGreaterThanOrEqual(layout.sidebar, Metrics.sidebarMinimum, "at \(width)")
                    XCTAssertTrue(wantsSidebar)
                }
            }
        }
    }

    func testANarrowingWindowTakesFromTheDetailsThenTheListThenTheSidebar() {
        let wide = Metrics.sidebarWidth + Metrics.listWidth + Metrics.detailMinimum
        XCTAssertEqual(PaneLayout(width: wide, wantsSidebar: true),
                       PaneLayout(width: wide + 100, wantsSidebar: true).with(detail: Metrics.detailMinimum))

        let listGave = PaneLayout(width: wide - 10, wantsSidebar: true)
        XCTAssertEqual(listGave.sidebar, Metrics.sidebarWidth)
        XCTAssertEqual(listGave.list, Metrics.listWidth - 10)

        let sidebarGave = PaneLayout(width: PaneLayout.narrowestWithSidebar + 10, wantsSidebar: true)
        XCTAssertEqual(sidebarGave.sidebar, Metrics.sidebarMinimum + 10)
        XCTAssertEqual(sidebarGave.list, Metrics.listMinimum)
        XCTAssertEqual(sidebarGave.detail, Metrics.detailMinimum)
    }

    func testPastTheThreeMinimumsTheSidebarFoldsFirst() {
        let last = PaneLayout(width: PaneLayout.narrowestWithSidebar, wantsSidebar: true)
        XCTAssertEqual(last.sidebar, Metrics.sidebarMinimum)

        let folded = PaneLayout(width: PaneLayout.narrowestWithSidebar - 1, wantsSidebar: true)
        XCTAssertFalse(folded.showsSidebar)
        // The other two are given back what they had lost to it.
        XCTAssertEqual(folded.list, Metrics.listWidth)
        XCTAssertGreaterThan(folded.detail, Metrics.detailMinimum)

        // The window's own minimum is under the three minimums, so there the
        // sidebar is folded and the two that are left have room.
        XCTAssertLessThan(Metrics.windowMinimum.width, PaneLayout.narrowestWithSidebar)
        XCTAssertGreaterThanOrEqual(Metrics.windowMinimum.width, Metrics.listMinimum + Metrics.detailMinimum)
    }

    // MARK: In the window

    func testTheSidebarInTheWindowIsAsWideAsTheLayoutSays() async throws {
        let store = demo()
        let panes = Panes(store: store)
        let window = hosted(panes, width: Metrics.windowSize.width)
        try await turn()
        let frame = try XCTUnwrap(sidebar(in: window))
        XCTAssertEqual(frame.minX, 0)
        XCTAssertEqual(frame.width, Metrics.sidebarWidth)
        // Under the title bar too: the traffic lights are over it.
        XCTAssertEqual(frame.height, Metrics.windowSize.height)

        window.setContentSize(CGSize(width: PaneLayout.narrowestWithSidebar, height: Metrics.windowSize.height))
        window.layoutIfNeeded()
        try await turn()
        XCTAssertEqual(sidebar(in: window)?.width, Metrics.sidebarMinimum)

        window.setContentSize(Metrics.windowMinimum)
        window.layoutIfNeeded()
        try await turn()
        XCTAssertNil(sidebar(in: window), "the sidebar is still in a window too narrow for it")
    }

    func testTheKeyFoldsTheSidebarAwayAndBringsItBack() async throws {
        let store = demo()
        let door = Door(store: store)
        let commands = WindowCommands(door: door)
        let item = commands.sidebarItem()
        XCTAssertEqual(item.keyEquivalent, "d")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertFalse(commands.validateMenuItem(item), "there is no sidebar behind the lock screen")

        await store.unlock(password: SecretBytes(DemoVault.password))
        let panes = try XCTUnwrap(door.panes)
        let window = hosted(panes, width: Metrics.windowSize.width)
        try await turn()
        XCTAssertNotNil(sidebar(in: window))
        XCTAssertTrue(commands.validateMenuItem(item))
        XCTAssertEqual(item.title, "Hide Sidebar")

        commands.toggleSidebar()
        try await turn(Motion.slide.duration * 3)
        XCTAssertNil(sidebar(in: window))
        XCTAssertTrue(commands.validateMenuItem(item))
        XCTAssertEqual(item.title, "Show Sidebar")

        commands.toggleSidebar()
        try await turn(Motion.slide.duration * 3)
        XCTAssertEqual(sidebar(in: window)?.width, Metrics.sidebarWidth)

        // A window that opens again opens with its sidebar out: the fold is
        // the panes' and goes with them.
        commands.toggleSidebar()
        await store.lock()
        await store.unlock(password: SecretBytes(DemoVault.password))
        XCTAssertEqual(door.panes?.wantsSidebar, true)
    }

    func testTheItemGoesToTheTopOfTheViewMenuAndMakesOneIfThereIsNone() {
        let door = Door(store: demo())
        let rows = ["", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
        // Back and forward, and the three sizes.
        let later = ["", "[", "]", "", "+", "-", "0"]
        func menu(_ titles: [String]) -> NSMenu {
            let main = NSMenu()
            for title in titles {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = NSMenu(title: title)
                main.addItem(item)
            }
            return main
        }

        let without = menu(["App", "Edit", "Window", "Help"])
        WindowCommands(door: door).install(in: without, before: without.items[2].submenu)
        XCTAssertEqual(without.items.map(\.title), ["App", "Edit", "View", "Window", "Help"])
        XCTAssertEqual(without.items[2].submenu?.items.map(\.keyEquivalent), ["d", "f", "f"] + rows + later)
        // The table of keys is the Help menu's when there is one.
        XCTAssertEqual(without.items[4].submenu?.items.map(\.keyEquivalent), ["/"])

        let with = menu(["App", "Edit", "View", "Window", "Help"])
        with.items[2].submenu?.addItem(withTitle: "Enter Full Screen", action: nil, keyEquivalent: "f")
        WindowCommands(door: door).install(in: with, before: with.items[3].submenu)
        XCTAssertEqual(with.items.map(\.title), ["App", "Edit", "View", "Window", "Help"])
        XCTAssertEqual(with.items[2].submenu?.items.map(\.keyEquivalent), ["d", "f", "f"] + rows + later + ["", "f"])
    }

    // MARK: What the window keeps

    func testTheWindowIsNotRestoredAndRemembersNoFrameUnlessToldTheName() {
        let window = MainWindow.make()
        XCTAssertFalse(window.isRestorable)
        XCTAssertEqual(window.frameAutosaveName, "")
        XCTAssertEqual(window.contentMinSize, Metrics.windowMinimum)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(window.titleVisibility, .hidden)
    }

    func testTheTrafficLightsStandOverTheSidebarInTheMiddleOfTheToolbarsHeight() throws {
        let window = hosted(Panes(store: demo()), width: Metrics.windowSize.width)
        let frame = try XCTUnwrap(window.contentView?.superview)
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try XCTUnwrap(window.standardWindowButton(kind))
            let place = button.convert(button.bounds, to: frame)
            XCTAssertEqual(frame.bounds.maxY - place.midY, Metrics.toolbarHeight / 2, accuracy: 1)
            XCTAssertLessThan(place.maxX, Metrics.sidebarMinimum)
            // And clear of a toolbar that starts where the sidebar was.
            XCTAssertLessThan(place.maxX, Metrics.trafficLights)
        }
    }
}

private extension PaneLayout {
    func with(detail: CGFloat) -> PaneLayout {
        PaneLayout(width: sidebar + list + detail, wantsSidebar: showsSidebar)
    }
}
