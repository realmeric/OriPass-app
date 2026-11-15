import AppKit
import SwiftUI

/// The settings window, as the app shows it and as a shot renders it: one
/// size, no title drawn, and the traffic lights over the list of rooms as
/// the main window has them over its sidebar.
@MainActor
enum SettingsWindow {
    static func make() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Metrics.settingsWindow),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // For the Window menu and for VoiceOver. It is not drawn.
        window.title = "Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        let toolbar = NSToolbar(identifier: "settings")
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        return window
    }
}

/// Whatever asks for the settings: ⌘, by way of the delegate, the mark's
/// menu and the account's. The window is made the first time it is asked
/// for and kept, so it comes back on the room it was left on.
@MainActor
final class SettingsCommands: NSObject, NSWindowDelegate {
    let rooms: Rooms
    private(set) var window: NSWindow?
    /// What puts it on the screen, and what is told before it is shown and
    /// after it has closed (`Presence`). A test shows nothing.
    private let present: (NSWindow) -> Void
    private let willShow: () -> Void
    private let didClose: () -> Void

    init(rooms: Rooms, present: @escaping (NSWindow) -> Void = { _ in },
         willShow: @escaping () -> Void = {}, didClose: @escaping () -> Void = {}) {
        self.rooms = rooms
        self.present = present
        self.willShow = willShow
        self.didClose = didClose
    }

    /// On `room` when one is named, and otherwise where it was left.
    func show(_ room: Room? = nil) {
        if let room { rooms.room = room }
        let window = self.window ?? make()
        self.window = window
        willShow()
        if !window.isVisible { window.center() }
        present(window)
        rooms.look()
    }

    private func make() -> NSWindow {
        let window = SettingsWindow.make()
        window.contentView = NSHostingView(rootView: RoomsView(rooms: rooms))
        window.delegate = self
        return window
    }

    /// He is back, perhaps from System Settings.
    func windowDidBecomeKey(_ notification: Notification) {
        rooms.look()
    }

    /// A question left up is not waiting when the window comes back.
    func windowWillClose(_ notification: Notification) {
        rooms.cancelSignOut()
        didClose()
    }
}
