import AppKit
import SwiftUI

/// The mark in the menu bar.
///
/// A click opens Quick Access. A right click, or a click with Control held,
/// drops the menu instead, which is made again at every opening so that
/// Lock is grey or not as the vault is when somebody looks, and the key
/// beside Open Quick Access is the one the system holds today.
///
/// Ported from OriNotch's, which has the menu on every click. A status item
/// answers no timer and listens to nothing until it is clicked, so it is not
/// in `Instruments`, and a locked app keeps it beside the hot keys (D18).
@MainActor
final class StatusItem: NSObject {
    private var item: NSStatusItem?
    private let click: () -> Void
    private let menu: () -> NSMenu

    /// `click` is what a plain click does, and `menu` is asked for each time
    /// the other kind drops it.
    init(click: @escaping () -> Void, menu: @escaping () -> NSMenu) {
        self.click = click
        self.menu = menu
    }

    var isShowing: Bool { item != nil }

    /// What a click is, from the event that made it: the right button or the
    /// left with Control held is the menu's, and anything else is a plain
    /// click. A click made by code, with no event, is a plain one.
    static func opensMenu(_ type: NSEvent.EventType?, _ flags: NSEvent.ModifierFlags) -> Bool {
        type == .rightMouseUp || type == .rightMouseDown || flags.contains(.control)
    }

    func show() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.glyph
            button.toolTip = AppInfo.name
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel(AppInfo.name)
        }
        self.item = item
    }

    func hide() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    /// What a click on the mark does, for the tour, which has no hand.
    func performClick() {
        item?.button?.performClick(nil)
    }

    @objc private func clicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        guard Self.opensMenu(event?.type, event?.modifierFlags ?? []) else {
            click()
            return
        }
        // A status item with a menu opens it on every click, so the menu is
        // given for the one click and taken away again.
        guard let item else { return }
        item.menu = menu()
        item.button?.performClick(nil)
        item.menu = nil
    }

    /// The app's own mark, filled with the even-odd rule so that its three
    /// dots are holes, as a template: the bar colours it, light or dark,
    /// highlighted or not. Drawn from the same shape as the lock screen's.
    static var glyph: NSImage {
        let side = Metrics.menuBarMark
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            let path = NSBezierPath(cgPath: AppMark().path(in: rect).cgPath)
            path.windingRule = .evenOdd
            Palette.templateInk.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
