import AppKit
import SwiftUI
import XCTest
@testable import OriPass

@MainActor
final class ItemIconTests: XCTestCase {
    private func login(_ n: Int, _ name: String, address: String?, type: Int = 1) -> JSONValue {
        .object([
            "object": .string("item"), "id": .string(String(format: "icon-%04d", n)), "type": .int(Int64(type)),
            "name": .string(name), "favorite": .bool(false), "reprompt": .int(0),
            "creationDate": .string("2026-01-01T00:00:00.000Z"), "revisionDate": .string("2026-01-01T00:00:00.000Z"),
            "login": .object(["username": .null, "password": .null, "totp": .null,
                              "uris": .array(address.map { [.object(["uri": .string($0), "match": .null])] } ?? [])]),
            "card": .object(["brand": .string("Visa"), "number": .null]),
        ])
    }

    private func store(_ items: [JSONValue]) async -> VaultStore {
        let backend = FakeBackend(items: items, folders: [], password: DemoVault.password)
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        return store
    }

    private func turn(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func views<Wanted: NSView>(_ type: Wanted.Type, in view: NSView?) -> [Wanted] {
        guard let view else { return [] }
        return ((view as? Wanted).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    /// The colours down the middle of the icons' column in a shot of the
    /// list, which is where each row's icon is.
    private func iconColumn(of panes: Panes) throws -> [NSColor] {
        let png = try Shots.shoot(AnyView(PanesView(panes: panes)), size: Metrics.windowSize, appearance: .aqua)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
        let x = Int((Metrics.sidebarWidth + Metrics.close + Metrics.gap + Metrics.listIcon / 2) * scale)
        return (0..<bitmap.pixelsHigh).compactMap { bitmap.colorAt(x: x, y: $0) }
    }

    private func contains(_ colours: [NSColor], _ wanted: NSColor) -> Bool {
        colours.contains {
            abs($0.redComponent - wanted.redComponent) < 0.03 && abs($0.greenComponent - wanted.greenComponent) < 0.03
                && abs($0.blueComponent - wanted.blueComponent) < 0.03
        }
    }

    func testALoginWearsItsSitesIconAndTheOtherTypesWearTheirCategorysMark() async throws {
        let items = [login(1, "Site", address: "https://icon.example.com/login"),
                     login(2, "Card", address: nil, type: 3)]
        let icons = IconStore(fetcher: nil, directory: nil)
        icons.seed(["icon.example.com": tinyPNG(0.15)])
        let panes = Panes(store: await store(items), icons: icons)

        let colours = try iconColumn(of: panes)
        XCTAssertTrue(contains(colours, NSColor(srgbRed: 0.15, green: 128.0 / 255, blue: 179.0 / 255, alpha: 1)), "the site's icon")
        XCTAssertTrue(contains(colours, Palette.nsColor(0x1A66E0)), "the card's mark")
    }

    func testWithoutAnIconTheLoginWearsATile() async throws {
        let items = [login(1, "Site", address: "https://icon.example.com/login")]
        // The picture is in memory and the switch is off.
        let icons = IconStore(fetcher: nil, directory: nil, isOn: { false })
        icons.seed(["icon.example.com": tinyPNG(0.15)])
        let panes = Panes(store: await store(items), icons: icons)
        let colours = try iconColumn(of: panes)
        XCTAssertFalse(contains(colours, NSColor(srgbRed: 0.15, green: 128.0 / 255, blue: 179.0 / 255, alpha: 1)))

        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: PanesView(panes: panes))
        window.setContentSize(Metrics.windowSize)
        window.layoutIfNeeded()
        XCTAssertTrue(said(in: window.contentView).contains("Site"))
        window.close()
    }

    func testAnIconArrivesInTheRowThatIsAlreadyDrawn() async throws {
        let items = [login(1, "Site", address: "https://late.example.com")]
        let fetcher = CountingFetcher { _ in .image(tinyPNG(0.15)) }
        let icons = IconStore(fetcher: fetcher, directory: nil, settle: 0.01)
        let panes = Panes(store: await store(items), icons: icons)
        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: PanesView(panes: panes))
        window.setContentSize(Metrics.windowSize)
        window.layoutIfNeeded()
        try await turn(0.4)
        XCTAssertEqual(fetcher.hosts, ["late.example.com"])
        XCTAssertNotNil(icons.cached("late.example.com"))
        window.close()
    }

    /// Two thousand rows with a host each, the list flung down it and left at
    /// rest. The network is asked about the rows it stopped on and a few
    /// the settle did not catch, and not about the hundreds it passed.
    func testScrollingPastTwoThousandRowsAsksOnlyAboutTheOnesThatStay() async throws {
        let items = (0..<2000).map { login($0, "Row \(String(format: "%04d", $0))", address: "https://site\($0).example.com") }
        let fetcher = CountingFetcher { _ in .none }
        let icons = IconStore(fetcher: fetcher, directory: nil, settle: 0.3)
        let panes = Panes(store: await store(items), icons: icons)
        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: PanesView(panes: panes))
        window.setContentSize(Metrics.windowSize)
        window.layoutIfNeeded()
        try await turn(0.1)
        window.layoutIfNeeded()

        let scroller = try XCTUnwrap(views(NSScrollView.self, in: window.contentView)
            .max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        let document = try XCTUnwrap(scroller.documentView)
        XCTAssertGreaterThan(document.frame.height, 1500 * Metrics.listRow)

        // Twenty rows every 20 ms: eleven hundred rows in a second.
        for step in 1...55 {
            scroller.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step) * 20 * Metrics.listRow))
            scroller.reflectScrolledClipView(scroller.contentView)
            window.layoutIfNeeded()
            try await turn(0.02)
        }
        let during = fetcher.hosts.count
        try await turn(0.8)
        let after = fetcher.hosts

        XCTAssertLessThanOrEqual(during, 3, "asked while the rows were moving")
        XCTAssertGreaterThan(after.count, 0, "asked about no row at all, so the test shows nothing")
        XCTAssertLessThan(after.count, 60, "\(after.count) hosts asked about")
        // The hosts asked about are the ones near where the list stopped.
        let stopped = 55 * 20
        let numbers = after.compactMap { Int($0.dropFirst(4).prefix { $0.isNumber }) }
        XCTAssertTrue(numbers.allSatisfy { abs($0 - stopped) < 60 }, "\(numbers.sorted())")
        window.close()
    }
}
