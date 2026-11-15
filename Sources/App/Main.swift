import SwiftUI

@main
struct OriPassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Before there is an application at all: this run is a test's helper
        // and never shows anything.
        if Demo.choice == "child" { DemoChild.run() }
        if Demo.choice == "canaries" {
            DemoVault.canaries.forEach(Demo.say)
            // And what a breach check makes of each of them: the part of
            // its SHA-1 that is never sent, in both cases a hex string is
            // written in. A whole hash written anywhere holds it.
            for canary in DemoVault.canaries {
                let suffix = BreachMark(canary).suffix
                Demo.say(suffix)
                Demo.say(suffix.lowercased())
            }
            exit(0)
        }
    }

    var body: some Scene {
        // The delegate owns the window, because it has to be swapped for the
        // lock screen and torn down on lock (D6), and a `WindowGroup` would
        // restore it. `App` insists on a scene, so it gets one that never
        // opens.
        SwiftUI.Settings { EmptyView() }
            // The scene's own Settings item would open that empty view, so
            // this one stands where it stood, on the same key, and raises
            // the delegate's window. It is made here and not put in by
            // AppKit as the other menus are: the app's own menu is SwiftUI's
            // to build again, and an item added to it is gone when it does.
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { delegate.showSettings(nil) }
                        .keyboardShortcut(KeyEquivalent(Character(KeyTable[.settings].strokes[0].key)),
                                          modifiers: .command)
                }
            }
    }
}
