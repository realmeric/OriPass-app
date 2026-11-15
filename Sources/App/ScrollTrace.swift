import AppKit
import QuartzCore
import SwiftUI

/// `OP_DEMO=scroll`: two thousand invented items in the real window, the
/// item list driven down and back up for ten seconds at sixty rows a second,
/// and a line that says how many frames the display asked for and how many
/// the main thread was late to (`docs/notes.md`, "The item list"). The
/// window is on screen while it runs, because a display link ticks for
/// nothing else, and the app quits when it is done.
@MainActor
final class ScrollTrace: NSObject {
    static let itemCount = 2000
    static let seconds: CFTimeInterval = 10
    /// Points a second.
    static var speed: CGFloat { Metrics.listRow * 60 }

    /// Logins with a name, a username, a host of their own and two dates and nothing else, spread
    /// over the alphabet and over four years.
    static func items(_ count: Int = itemCount) -> [JSONValue] {
        let names = ["Çarşı", "Ilgaz", "İş", "Öğle", "Şube", "Ümit", "Akım", "Bulut", "Cam", "Dere", "Eser",
                     "Fener", "Gölge", "Harita", "Jeton", "Kule", "Liman", "Mavi", "Nokta", "Orman", "Pusula",
                     "Rota", "Sahil", "Tuna", "Uzay", "Vadi", "Yaka", "Zemin"]
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        return (0..<count).map { n in
            .object([
                "object": .string("item"), "id": .string(String(format: "5c011000-0000-4000-8000-%012d", n)),
                "organizationId": .null, "folderId": .null, "type": .int(1), "reprompt": .int(0),
                "name": .string("\(names[n % names.count]) \(n / names.count + 1)"), "notes": .null,
                "favorite": .bool(n % 7 == 0), "collectionIds": .array([]), "passwordHistory": .null,
                "creationDate": .string(VaultDate.string(start.addingTimeInterval(-Double(n) * 61_000))),
                "revisionDate": .string(VaultDate.string(start.addingTimeInterval(-Double((n * 37) % count) * 61_000))),
                "deletedDate": .null, "archivedDate": .null,
                "login": .object(["username": .string("user\(n)@scroll.invalid"), "password": .null,
                                  "totp": .null,
                                  "uris": .array([.object(["uri": .string("https://site\(n).scroll.invalid"),
                                                           "match": .null])]),
                                  "fido2Credentials": .array([])]),
            ])
        }
    }

    private let window: NSWindow
    private var scroller: NSScrollView?
    private var link: CADisplayLink?
    private var began: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var frames = 0
    private var late = 0
    private var longest: CFTimeInterval = 0
    private var frame: CFTimeInterval = 0
    private var deepest: CGFloat = 0
    private var hasStalled = false

    private let icons: IconStore

    private struct Silent: IconFetcher {
        func fetch(host: String) async -> IconAnswer { .none }
    }

    private init(window: NSWindow, icons: IconStore) {
        self.window = window
        self.icons = icons
    }

    private static var running: ScrollTrace?

    static func run() async {
        let backend = FakeBackend(items: items(), folders: [], password: DemoVault.password)
        backend.lastSync = Date()
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        // Every row has a host nobody has an icon for, and the store counts
        // the requests it makes, which a row that scrolled past must not.
        let icons = IconStore(fetcher: Silent(), directory: nil)
        let panes = Panes(store: store, icons: icons)
        if let key = ProcessInfo.processInfo.environment["OP_SCROLL_SORT"].flatMap(ItemList.Key.init) {
            panes.order(by: key)
        }
        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: PanesView(panes: panes))
        window.center()
        window.makeKeyAndOrderFront(nil)
        // A second for the window to arrive and the first rows to be laid out.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let trace = ScrollTrace(window: window, icons: icons)
        running = trace
        trace.start()
    }

    private static func scrollViews(in view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        return ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }

    private func start() {
        // The list's is the tall one; the sidebar scrolls too, over a few rows.
        scroller = Self.scrollViews(in: window.contentView)
            .max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
        guard let scroller, let host = window.contentView else {
            Demo.say("scroll: no scroll view in the window")
            exit(1)
        }
        Demo.say("scroll: \(Self.itemCount) items, \(Int(scroller.documentView?.frame.height ?? 0)) points of list")
        let link = host.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        if began == 0 {
            began = link.timestamp
            last = link.timestamp
            frame = link.targetTimestamp - link.timestamp
            return
        }
        // A callback the main thread was late for comes with the time of a
        // later refresh, and the ones between were never drawn.
        let interval = link.timestamp - last
        last = link.timestamp
        frames += 1
        longest = max(longest, interval)
        late += max(0, Int((interval / frame).rounded()) - 1)

        let elapsed = link.timestamp - began
        guard elapsed < Self.seconds else {
            link.invalidate()
            let hertz = Int((1 / frame).rounded())
            Demo.say("scroll: \(frames) frames in \(String(format: "%.1f", elapsed)) s at \(hertz) Hz, "
                + "\(late) dropped, longest \(String(format: "%.1f", longest * 1000)) ms, "
                + "\(Int(deepest)) points down and back")
            Demo.say("scroll: \(icons.requests) icon requests for \(Int(deepest / Metrics.listRow)) rows passed")
            exit(0)
        }
        guard let scroller, let document = scroller.documentView else { return }
        let reach = max(0, document.frame.height - scroller.contentView.bounds.height)
        // Down for the first half and back up for the second.
        let half = Self.seconds / 2
        let travelled = Self.speed * CGFloat(elapsed < half ? elapsed : Self.seconds - elapsed)
        scroller.contentView.setBoundsOrigin(NSPoint(x: 0, y: min(reach, travelled)))
        scroller.reflectScrolledClipView(scroller.contentView)
        deepest = max(deepest, scroller.contentView.bounds.minY)

        #if DEBUG
        // `OP_SCROLL_STALL=1` holds the main thread for three frames once,
        // so the count can be seen to find a frame that was dropped.
        if !hasStalled, elapsed > half, ProcessInfo.processInfo.environment["OP_SCROLL_STALL"] != nil {
            hasStalled = true
            Thread.sleep(forTimeInterval: frame * 3)
        }
        #endif
    }
}
