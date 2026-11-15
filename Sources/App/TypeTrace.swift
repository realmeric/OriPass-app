import AppKit
import QuartzCore

/// `OP_DEMO=type`: Quick Access over two thousand invented items, on the
/// screen, with a word put into its field a letter at a time, and a line
/// for each letter that says how long the main thread was at it: from the
/// letter reaching the model to the run loop going back to sleep, which is
/// after the search, the list laid out again and the commit to the window
/// server (`docs/notes.md`, "Timing"). A letter whose time is under the
/// display's refresh interval is on the screen in the frame after it.
///
/// Each line has the time on the clock and the time the main thread spent
/// running. They part when the Mac is busy with something else, and the
/// second is the app's own doing.
///
/// The panel is ordered in and not given the keys, so nothing typed at the
/// Mac meanwhile goes into it, and it is up for about three seconds.
@MainActor
enum TypeTrace {
    /// The start of some titles, the inside of others, and then letters that
    /// are in every username and every host, which is the most there is to
    /// find and to draw.
    static let words = ["ilgaz", "man", "inv", "scroll 19"]

    private static var traced: QuickAccess?

    static func run() async {
        let backend = FakeBackend(items: ScrollTrace.items(), folders: [], password: DemoVault.password)
        backend.lastSync = Date()
        let store = VaultStore(backend: backend)
        let quick = QuickAccess(door: Door(store: store), present: { $0.orderFrontRegardless() })
        traced = quick
        await store.unlock(password: SecretBytes(DemoVault.password))
        await store.indexing?.value
        quick.show()
        // A second for the panel to arrive, as it has when a letter is typed.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let hertz = quick.panel.screen?.maximumFramesPerSecond ?? 60
        let frame = 1000 / Double(hertz)

        var times: [Double] = []
        var worked: [Double] = []
        for word in words {
            var typed = ""
            for letter in word {
                typed.append(letter)
                let took = await type(typed, into: quick)
                times.append(took.whole)
                worked.append(took.running)
                Demo.say("type: \"\(typed)\" \(ms(took.whole)) ms, \(ms(took.running)) running, "
                    + "\(ms(took.model)) to the list, \(quick.rows.count) listed")
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            _ = await type("", into: quick)
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        let late = times.filter { $0 >= frame }.count
        let busy = worked.filter { $0 >= frame }.count
        Demo.say("type: \(store.shelves.all.count) items, \(times.count) letters, a frame is \(ms(frame)) ms "
            + "at \(hertz) Hz")
        Demo.say("type: on the clock, median \(ms(median(times))) ms, longest \(ms(times.max() ?? 0)) ms, "
            + "\(late) over a frame")
        Demo.say("type: running, median \(ms(median(worked))) ms, longest \(ms(worked.max() ?? 0)) ms, "
            + "\(busy) over a frame")
        exit(late == 0 ? 0 : 1)
    }

    private static func ms(_ time: Double) -> String { String(format: "%.1f", time) }

    private static func median(_ times: [Double]) -> Double { times.sorted()[times.count / 2] }

    /// The seconds this thread has spent running, asleep and waiting left
    /// out.
    private static var running: Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000_000
    }

    /// The milliseconds from the field's text changing to the main run loop
    /// having nothing left to do about it, how many of them the thread was
    /// running for, and how many went by before the model had its new list.
    private static func type(_ text: String, into quick: QuickAccess) async
        -> (whole: Double, running: Double, model: Double) {
        await withCheckedContinuation { waiting in
            let began = CACurrentMediaTime()
            let ran = running
            var model = 0.0
            // After everything else that runs before the loop sleeps, the
            // commit of the layers among it.
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue,
                                                              false, CFIndex.max) { _, _ in
                waiting.resume(returning: ((CACurrentMediaTime() - began) * 1000, (running - ran) * 1000, model))
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            quick.field?.stringValue = text
            quick.query = text
            model = (CACurrentMediaTime() - began) * 1000
        }
    }
}
