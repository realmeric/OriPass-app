import AppKit
import SwiftUI

/// Where Large Type is put. The panes ask for it and are told when it has
/// gone; a test hands them something that only remembers.
@MainActor
protocol LargeTypeStage: AnyObject {
    func show(_ value: LargeType, closed: @escaping () -> Void)
    func close()
}

/// Large Type as a panel across the middle of the screen, over every other
/// window. Esc, a click anywhere and the panel losing the keys each put it
/// away, and so does whoever asked for it: another item, the lock (D6).
@MainActor
final class LargeTypePanel: LargeTypeStage {
    private var panel: Panel?
    private var closed: (() -> Void)?

    var isUp: Bool { panel?.isVisible == true }

    func show(_ value: LargeType, closed: @escaping () -> Void) {
        close()
        let screen = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(origin: .zero, size: Metrics.windowSize)
        let panel = Self.make(value, within: screen) { [weak self] in self?.close() }
        self.panel = panel
        self.closed = closed
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard let panel else { return }
        // Before it is ordered out: losing the keys comes back here.
        self.panel = nil
        let closed = self.closed
        self.closed = nil
        panel.dismiss = nil
        panel.orderOut(nil)
        // The value goes with the view, not when the panel is next used.
        panel.contentView = nil
        closed?()
    }

    /// The panel, sized to the value and centred in `frame`, and not shown.
    static func make(_ value: LargeType, within frame: NSRect, dismiss: @escaping () -> Void) -> Panel {
        let fit = value.fit(width: frame.width * Metrics.largeTypeShare, height: frame.height * Metrics.largeTypeShare)
        let origin = CGPoint(x: frame.midX - fit.size.width / 2, y: frame.midY - fit.size.height / 2)
        let panel = Panel(contentRect: NSRect(origin: origin, size: fit.size),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.dismiss = dismiss
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = Palette.none
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: LargeTypeView(value: value, perLine: fit.perLine))
        return panel
    }

    final class Panel: NSPanel {
        var dismiss: (() -> Void)?

        override var canBecomeKey: Bool { true }

        /// Here and not in a view, so a click on a character counts as much
        /// as one beside it.
        override func sendEvent(_ event: NSEvent) {
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                dismiss?()
            case .keyDown where event.keyCode == Self.escape:
                dismiss?()
            default:
                super.sendEvent(event)
            }
        }

        override func cancelOperation(_ sender: Any?) {
            dismiss?()
        }

        override func resignKey() {
            super.resignKey()
            dismiss?()
        }

        private static let escape: UInt16 = 53
    }
}
