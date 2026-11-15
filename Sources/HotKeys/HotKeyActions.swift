import AppKit

/// What each hot key does, in one place that a test can hold: the four
/// things the app can be asked from anywhere.
@MainActor
struct HotKeyActions {
    let quick: QuickAccess
    let door: Door
    let lock: LockCommands
    /// Brings the main window forward. The delegate owns the window.
    let showApp: () -> Void

    @discardableResult
    func perform(_ action: HotKeyAction) -> Task<Void, Never>? {
        switch action {
        case .quickAccess:
            quick.toggle()
        case .lock:
            // Locked already, or never opened: there is nothing to shut,
            // and a key pressed in another app should not wake the engine.
            guard door.store.state == .unlocked || door.store.state == .unlocking else { return nil }
            return lock.lock()
        case .showApp:
            showApp()
        case .fill:
            quick.autofill()
        }
        return nil
    }
}
