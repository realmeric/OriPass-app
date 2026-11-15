import AppKit
import SwiftUI

/// The one window, as the delegate shows it and as a shot renders it, so the
/// two cannot drift apart: no title, the content under the title bar, and the
/// traffic lights left where the sidebar's top will be.
@MainActor
enum MainWindow {
    /// The name the frame is kept under in the defaults. Only the delegate's
    /// window is given it: a test's or a shot's would write to the real
    /// defaults.
    static let frameName = "main"

    static func make(remembersFrameAs frameName: String? = nil) -> NSWindow {
        let window = VaultWindow(
            contentRect: NSRect(origin: .zero, size: Metrics.windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty toolbar, for what it does to the title bar: the traffic
        // lights come down and in, to the middle of the height the app's own
        // toolbar is drawn at beside them. Nothing is ever put in it.
        let toolbar = NSToolbar(identifier: "main")
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.contentMinSize = Metrics.windowMinimum
        // Restoration writes what was on screen to disk (D6). The frame is
        // four numbers and is the one thing kept.
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        if let frameName {
            window.center()
            window.setFrameAutosaveName(frameName)
        }
        return window
    }
}
