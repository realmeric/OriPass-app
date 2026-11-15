import AppKit

/// The menu bar's two ways to shut the vault: Lock on ⇧⌘L, which keeps the
/// seal for the next finger, and Lock and Forget, which deletes it so that
/// the next unlock is the password, typed (D7). The global key is OP-32's; this one works
/// while the app is in front.
@MainActor
final class LockCommands: NSObject, NSMenuItemValidation {
    private let door: Door

    init(door: Door) {
        self.door = door
    }

    func menu() -> NSMenu {
        let menu = NSMenu(title: "Vault")
        let lock = KeyTable.item(.lock, action: #selector(lockFromMenu(_:)), target: self)
        let forget = NSMenuItem(title: "Lock and Forget", action: #selector(lockAndForgetFromMenu(_:)),
                                keyEquivalent: "")
        forget.target = self
        menu.addItem(lock)
        menu.addItem(forget)
        return menu
    }

    /// Before the Window menu, where a document app keeps its own.
    func install(in mainMenu: NSMenu, before windowMenu: NSMenu? = NSApp.windowsMenu) {
        let host = NSMenuItem(title: "Vault", action: nil, keyEquivalent: "")
        host.submenu = menu()
        let window = mainMenu.items.firstIndex { $0.submenu === windowMenu }
        mainMenu.insertItem(host, at: window ?? mainMenu.items.count)
    }

    @discardableResult
    func lock() -> Task<Void, Never> {
        Task { await door.store.lock() }
    }

    @discardableResult
    func lockAndForget() -> Task<Void, Never> {
        Task { await door.lockAndForget() }
    }

    @objc private func lockFromMenu(_ sender: Any?) { lock() }
    @objc private func lockAndForgetFromMenu(_ sender: Any?) { lockAndForget() }

    /// There is nothing to lock when it is locked, but there is something to
    /// forget for as long as a seal is on disk.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(lockFromMenu(_:)): return door.store.state == .unlocked
        case #selector(lockAndForgetFromMenu(_:)): return door.store.state == .unlocked || door.hasSeal
        default: return true
        }
    }
}
