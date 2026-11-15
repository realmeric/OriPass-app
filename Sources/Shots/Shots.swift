import AppKit
import os
import SwiftUI

/// What a run of `make shots` wrote and what it could not.
struct ShotReport: Codable, Equatable {
    struct Problem: Codable, Equatable {
        let surface: String
        /// Nil when the run itself went wrong before any surface was drawn.
        var appearance: String?
        let reason: String
    }

    var written: [String] = []
    /// The icon as the bundle carries it, at each of `AppIcon.renders`.
    var icons: [String] = []
    var problems: [Problem] = []
    /// Calls on the backend while the surfaces were being drawn. A view reads
    /// the store and never the backend, so this is nought.
    var requests = 0
    /// Processes this one had started by the time it was done. Also nought:
    /// the demo vault is held in memory and there is no `bw` behind it.
    var children = 0

    var isClean: Bool { problems.isEmpty && requests == 0 && children == 0 }
}

/// No session can see a window, so `OP_DEMO=shots` renders every surface in
/// `Surface.all` from the demo vault to `shots/<surface>-<appearance>.png`,
/// in light and in dark, and again at the compact density as
/// `shots/<surface>-compact-<appearance>.png`, and writes
/// `shots/report.json` beside them. A
/// builder reads the PNGs back the way it would have looked at the screen.
///
/// Each shot is a hosting view in a window that is never ordered in, cached
/// into a bitmap. Nothing is read off the screen, so no screen recording
/// permission is asked for. The files show canaries, which is what they are
/// for, and `shots/` is ignored by git.
@MainActor
enum Shots {
    static let appearances: [(name: String, appearance: NSAppearance.Name)] = [
        ("light", .aqua), ("dark", .darkAqua),
    ]

    /// The four a surface is drawn in: each appearance, comfortable and
    /// then compact. The comfortable two keep the names they always had.
    static let looks: [(name: String, appearance: NSAppearance.Name, density: Density)] =
        Density.allCases.flatMap { density in
            appearances.map { name, appearance in
                (density == .comfortable ? name : "\(density.rawValue)-\(name)", appearance, density)
            }
        }

    enum Failure: Error {
        case noBitmap
        /// A text field still had another field's height after every
        /// attempt at laying the surface out: the height of a line of its
        /// face, and the one it has.
        case misfitField(line: CGFloat, height: CGFloat)
        case brokenOnPurpose
    }

    /// Unlocks the demo vault behind `backend`, draws `surfaces` into
    /// `directory` and leaves the report there too. An `icon` is drawn
    /// beside them.
    static func write(_ surfaces: [Surface], from backend: FakeBackend,
                      into directory: URL, icon: NSImage? = nil) async -> ShotReport {
        var report = ShotReport()
        // One moment for the whole run, so the foot of the sidebar says the
        // same in the last shot as in the first.
        let began = Date()
        // The breach check and the list of sites that take a code are on
        // while the vault is counted, so their cards are there for the
        // surfaces that are of them, and off for every other.
        let asks = OSAllocatedUnfairLock(initialState: true)
        let asksTwoFactor = OSAllocatedUnfairLock(initialState: true)
        let store = VaultStore(backend: backend, now: { began },
                               breaches: DemoBreaches.checker { asks.withLock { $0 } },
                               twoFactor: DemoTwoFactor.checker { asksTwoFactor.withLock { $0 } })
        await store.unlock(password: SecretBytes(DemoVault.password))
        // The unlock's own sync is the vault's business and not a surface's.
        await store.backgroundSync?.value
        // The levels arrive behind the items, and a shot is of them arrived.
        await store.scoring?.value
        await store.indexing?.value
        await store.counting?.value
        asks.withLock { $0 = false }
        asksTwoFactor.withLock { $0 = false }
        let asked = backend.calls.count
        // A one-time code is drawn as it stood at one moment, the same one
        // in every run.
        CodeRow.still = CodeRow.shotMoment
        defer { CodeRow.still = nil }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            report.problems.append(.init(surface: "shots", reason: String(describing: error)))
        }
        if store.state != .unlocked {
            report.problems.append(.init(surface: "shots", reason: "the demo vault did not unlock"))
        }

        for surface in surfaces {
            for (name, appearance, density) in looks {
                let file = "\(surface.name)-\(name).png"
                // `Metrics` is the whole app's, so the next surface gets
                // the actual size back, and the room.
                Metrics.zoom = surface.zoom.factor
                Metrics.density = density
                defer {
                    Metrics.zoom = Zoom.actual.factor
                    Metrics.density = .comfortable
                }
                asks.withLock { $0 = surface.asksBreaches }
                asksTwoFactor.withLock { $0 = surface.asksTwoFactor }
                defer {
                    asks.withLock { $0 = false }
                    asksTwoFactor.withLock { $0 = false }
                }
                // A pool for each, and then a turn of the run loop, which is
                // where AppKit finishes with a window that has been let go.
                // Without the two, every window made here is alive until
                // the last surface is drawn, and AppKit warns of it at the
                // hundred and first.
                try? await Task.sleep(nanoseconds: 1)
                autoreleasepool {
                    do {
                        let png = try shoot(try surface.build(store), size: surface.size, appearance: appearance,
                                            isBare: surface.isBare, in: surface.frame?())
                        try png.write(to: directory.appendingPathComponent(file))
                        report.written.append(file)
                    } catch {
                        report.problems.append(.init(surface: surface.name, appearance: name,
                                                     reason: String(describing: error)))
                    }
                }
            }
        }

        if let icon {
            for points in AppIcon.renders {
                let file = AppIcon.file(points)
                do {
                    try AppIcon.png(of: icon, points: points).write(to: directory.appendingPathComponent(file))
                    report.icons.append(file)
                } catch {
                    report.problems.append(.init(surface: file, reason: String(describing: error)))
                }
            }
        }

        report.requests = backend.calls.count - asked
        report.children = childCount
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(report).write(to: directory.appendingPathComponent(reportName))
        sweep(directory, keeping: Set(report.written + report.icons + [reportName]))
        return report
    }

    static let reportName = "report.json"

    /// A shot of a surface that is no longer drawn goes, and so does
    /// anything else shaped like one of this run's files. Each file is
    /// written over the one before it and nothing is deleted first: `shots/`
    /// is in iCloud Drive, which answers a file deleted and made again in
    /// the same minute by keeping both, the older as "report 2.json".
    private static func sweep(_ directory: URL, keeping written: Set<String>) {
        let found = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in found where !written.contains(name) && (name.hasSuffix(".png") || name.hasSuffix(".json")) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// One view in the main window's frame, traffic lights and all, as a PNG.
    /// A bare one is in a window with no frame, as a panel is, and one that
    /// brings its own window is in that.
    static func shoot(_ view: AnyView, size: CGSize, appearance: NSAppearance.Name,
                      isBare: Bool = false, in frame: NSWindow? = nil) throws -> Data {
        let window = frame ?? (isBare
            ? NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered,
                       defer: false)
            : MainWindow.make())
        if isBare {
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = Palette.none
        }
        // A dynamic colour is resolved by the appearance of the view drawing
        // it, and a window that is not on screen has only the one it is given.
        window.appearance = NSAppearance(named: appearance)
        // The toolbar's height is safe area at the top of the window, and a
        // fixed height that kept out of it would be drawn that much too
        // tall, with its foot off the bottom of the shot.
        let sized = view.frame(width: size.width, height: size.height).ignoresSafeArea()
        var host = NSHostingView(rootView: sized)
        // On a busy Mac the first layout now and then leaves a text field
        // with the height of another one: a title in a 24 point face in
        // the 16 points of a body field, drawn as the top half of its
        // letters. A window on screen is put right at its next turn. A
        // turn here lets the caret into a form as well, some of the time,
        // and then no two shots are the same. So a surface with such a
        // field in it is laid out again in a view of its own, and one
        // that never comes right is a problem and no file
        // (`docs/notes.md`, "Shots").
        //
        // A hosting view that is still alive is what makes a misfit last:
        // with every one of them kept to the end of a run, a field that
        // was wrong once was wrong in all eight. So the view that failed is
        // out of the window and its pool is drained before the next is
        // made, and the one the shot was taken from leaves its window as
        // this returns, without waiting for AppKit to be done with the
        // window.
        let isOwn = frame == nil
        defer { if isOwn { window.contentView = nil } }
        for attempt in 1...attempts {
            let misfit = autoreleasepool {
                window.contentView = host
                window.setContentSize(size)
                host.layoutSubtreeIfNeeded()
                return misfitField(in: host)
            }
            guard let misfit else { break }
            window.contentView = nil
            guard attempt < attempts else { throw misfit }
            host = NSHostingView(rootView: sized)
        }

        // The content view's parent is the window's own frame, which is where
        // the traffic lights are.
        let frame = host.superview ?? host
        guard let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else {
            throw Failure.noBitmap
        }
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        // The cache is in the display's own colour space, where the accent is
        // not the number `Palette` gives it. In sRGB a pixel can be read
        // against the palette, on this Mac's screen or any other.
        let matched = bitmap.converting(to: .sRGB, renderingIntent: .default) ?? bitmap
        // The conversion forgets that two pixels are a point.
        matched.size = bitmap.size
        guard let png = matched.representation(using: .png, properties: [:]) else {
            throw Failure.noBitmap
        }
        return png
    }

    /// Three were needed once in sixty-four runs of the forms on a Mac kept
    /// busy, and never four.
    static let attempts = 8

    /// The first text field under `view` whose height is not a line of
    /// its own face, as the failure it would be.
    static func misfitField(in view: NSView) -> Failure? {
        if let field = view as? NSTextField, field.frame.height > 0, let font = field.font {
            let line = NSLayoutManager().defaultLineHeight(for: font)
            // A point either way is how SwiftUI leaves one face of them.
            if abs(line - field.frame.height) > 1 { return .misfitField(line: line, height: field.frame.height) }
        }
        return view.subviews.lazy.compactMap(misfitField(in:)).first
    }

    /// How many processes have this one as their parent.
    static var childCount: Int {
        var pids = [pid_t](repeating: 0, count: Int(PATH_MAX))
        let bytes = proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        return max(0, Int(bytes)) / MemoryLayout<pid_t>.stride
    }

    /// `OP_DEMO=shots`: every registered surface into `OP_SHOTS_DIR`, then
    /// out, with a status `make shots` can fail on.
    static func run() async -> Never {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: environment["OP_SHOTS_DIR"] ?? "shots")
        var surfaces = Surface.all
        #if DEBUG
        // `OP_SHOT_BROKEN=1 make shots` must fail, naming this surface.
        if environment["OP_SHOT_BROKEN"] != nil {
            surfaces.append(Surface(name: "broken-on-purpose", size: Metrics.windowSize) { _ in
                throw Failure.brokenOnPurpose
            })
        }
        #endif

        let icon = AppIcon.image
        var report = await write(surfaces, from: DemoVault.backend(), into: directory, icon: icon)
        if icon == nil {
            report.problems.append(.init(surface: AppIcon.name, reason: "the bundle carries no icon"))
        }
        Demo.say("shots: \(report.written.count) written to \(directory.path), and the icon at \(report.icons.count) sizes")
        for problem in report.problems {
            Demo.say("shots: PROBLEM \(problem.surface) \(problem.appearance ?? ""): \(problem.reason)")
        }
        if report.requests > 0 { Demo.say("shots: PROBLEM \(report.requests) calls on the backend while drawing") }
        if report.children > 0 { Demo.say("shots: PROBLEM \(report.children) children started") }
        exit(report.isClean ? 0 : 1)
    }
}
