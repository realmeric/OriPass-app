import AppKit
import SwiftUI

/// The window Quick Access is drawn in: no frame, over full-screen apps and
/// on every Space, and able to take the keys without its app coming to the
/// front.
///
/// `.nonactivatingPanel` is what leaves the app in front where it is, and it
/// has to be in the style mask the panel is made with: the window server is
/// told once. `canBecomeKey` is what a panel with no title bar says no to
/// unless asked, and without it nothing typed would arrive.
final class QuickPanel: NSPanel {
    /// Esc, when no input method wanted it first.
    var escape: (() -> Void)?
    /// Any other key going down, before the field has it. True when it was
    /// the panel's own: an arrow, Return, or a ⌘ key that must not reach
    /// the menu bar, whose items are the main window's.
    var keys: ((NSEvent) -> Bool)?
    /// The keys went somewhere else: another window of this app's, or a
    /// click in another app's.
    var lostKeys: (() -> Void)?

    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Over another app's floating panels, under a menu and under the
        // sheet that asks for a finger. After `isFloatingPanel`, which
        // sets a level of its own.
        isFloatingPanel = true
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isOpaque = false
        backgroundColor = Palette.none
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        // Restoration would write what was typed to disk (D6).
        isRestorable = false
        // Ordering in is the whole of showing it, with no fade to wait for
        // (D18).
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The content, in a plain view of the panel's own size. A hosting view
    /// as the content view itself would give SwiftUI a say in how large the
    /// window is.
    func hold<Content: View>(_ content: Content) {
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        contentView = container
        // Laid out now, while nobody is waiting, and not at the first press.
        hosting.layoutSubtreeIfNeeded()
    }

    /// Here and not in the field, whose editor would end the editing and
    /// keep the text. A composition that is under way is the input method's
    /// to cancel, and its arrows and its Return are its own too.
    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown, !isComposing else { return super.sendEvent(event) }
        if event.keyCode == Self.escapeKey {
            escape?()
        } else if keys?(event) != true {
            super.sendEvent(event)
        }
    }

    /// A ⌘ key is offered here first and to the menu bar next, and only then
    /// sent as a key going down. ⌘O has to be stopped on the way.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, !isComposing, event.keyCode != Self.escapeKey else {
            return super.performKeyEquivalent(with: event)
        }
        return keys?(event) == true || super.performKeyEquivalent(with: event)
    }

    private var isComposing: Bool { (firstResponder as? NSTextView)?.hasMarkedText() == true }

    override func cancelOperation(_ sender: Any?) {
        escape?()
    }

    override func resignKey() {
        super.resignKey()
        lostKeys?()
    }

    private static let escapeKey: UInt16 = 53
}

/// Where the panel goes: across the middle of the screen the pointer is on,
/// its top edge a third of the way down.
enum QuickPlace {
    /// `screens` are frames in the one space every screen shares, the first
    /// of them the screen with the menu bar. A pointer that is on none of
    /// them, between two displays that do not touch, gets the first.
    static func frame(of size: CGSize, pointer: CGPoint, screens: [NSRect]) -> NSRect {
        guard let screen = screens.first(where: { $0.contains(pointer) }) ?? screens.first else {
            return NSRect(origin: .zero, size: size)
        }
        let top = screen.maxY - screen.height * Metrics.quickFall
        // Whole points, or the window is a fraction wider than what was
        // laid out in it.
        return NSRect(x: (screen.midX - size.width / 2).rounded(), y: (top - size.height).rounded(),
                      width: size.width, height: size.height)
    }
}
