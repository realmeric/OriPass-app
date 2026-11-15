import AppKit

/// Whether the app has a Dock icon and a menu bar of its own, which follows
/// from whether a window is open.
///
/// The panel and the hot keys have to outlive the last window, so closing it
/// does not quit (`AppDelegate`). What is left to decide is whether the app
/// then goes on being in the Dock. With the switch off it becomes an
/// accessory app, which has no icon and no menus of its own, and with no
/// mark in the bar either it would have nothing on screen at all, so the Dock
/// stays whatever the switch says.
@MainActor
final class Presence {
    private let choices: () -> MenuBarChoices
    private let hasWindow: () -> Bool
    private let setPolicy: (NSApplication.ActivationPolicy) -> Void
    private(set) var policy: NSApplication.ActivationPolicy
    /// How many times AppKit has asked whether to quit now that the last
    /// window is gone, for the tour to read.
    private(set) var lastWindowClosings = 0

    /// A test gives its own windows and its own application; the app's are
    /// `NSApp`'s.
    init(choices: @escaping () -> MenuBarChoices,
         hasWindow: @escaping () -> Bool = Presence.appHasWindow,
         policy: NSApplication.ActivationPolicy = .regular,
         setPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { _ = NSApp.setActivationPolicy($0) }) {
        self.choices = choices
        self.hasWindow = hasWindow
        self.policy = policy
        self.setPolicy = setPolicy
    }

    /// A window the app lays out in: not a panel, and not the strip the mark
    /// stands in. One that is minimised is in the Dock and is still open.
    static func appHasWindow() -> Bool {
        NSApp.windows.contains { ($0.isVisible || $0.isMiniaturized) && $0.canBecomeMain }
    }

    static func wanted(_ choices: MenuBarChoices, hasWindow: Bool) -> NSApplication.ActivationPolicy {
        hasWindow || choices.keepsDock || !choices.showsMark ? .regular : .accessory
    }

    func update() {
        apply(Self.wanted(choices(), hasWindow: hasWindow()))
    }

    /// A window is about to be shown, which cannot be done by an app with no
    /// Dock icon.
    func willShowWindow() {
        apply(.regular)
    }

    /// A window closes while it is still counted as open, so the answer is
    /// had a turn later.
    func windowClosed() {
        DispatchQueue.main.async { [weak self] in self?.update() }
    }

    /// AppKit's own word that the last window has closed. The answer is
    /// never to quit.
    func lastWindowClosed() {
        lastWindowClosings += 1
        windowClosed()
    }

    private func apply(_ wanted: NSApplication.ActivationPolicy) {
        guard wanted != policy else { return }
        policy = wanted
        setPolicy(wanted)
    }
}
