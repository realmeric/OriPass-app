import AppKit

/// `OP_DEMO=quick`: the panel shown and put away ten times, as the hot key
/// would do it, with a line for each that says how long it was from the call
/// to the refresh its first frame was due on (`docs/notes.md`, "Timing").
/// The same ten are in the log as signposts named `quick-access`. The panel
/// is on screen for a third of a second each time, and the app quits when
/// it is done.
@MainActor
enum QuickTrace {
    static let presses = 10

    private static var running: QuickAccess?

    static func run() async {
        let quick = QuickAccess(door: Door(store: VaultStore(backend: DemoVault.backend())))
        running = quick
        // A second for the launch to be over, as it is when a key is pressed.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var times: [Double] = []
        var stayed = true
        var hadKeys = true

        for press in 1...presses {
            let shown: Double = await withCheckedContinuation { waiting in
                quick.drawn = { waiting.resume(returning: $0 * 1000) }
                quick.toggle()
            }
            quick.drawn = nil
            times.append(shown)
            try? await Task.sleep(nanoseconds: 300_000_000)
            stayed = stayed && NSWorkspace.shared.frontmostApplication?.processIdentifier == front
            hadKeys = hadKeys && quick.panel.isKeyWindow && quick.panel.firstResponder is NSTextView
            Demo.say("quick: press \(press), \(String(format: "%.1f", shown)) ms")
            quick.toggle()
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        let sorted = times.sorted()
        Demo.say("quick: \(presses) presses, median \(String(format: "%.1f", sorted[presses / 2])) ms, "
            + "longest \(String(format: "%.1f", sorted[presses - 1])) ms")
        Demo.say("quick: the app in front \(stayed ? "stayed" : "changed"), and it was "
            + "\(front == getpid() ? "this one" : "another")")
        Demo.say("quick: the field \(hadKeys ? "had" : "did not have") the keys each time")
        exit(0)
    }
}
