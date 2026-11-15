import AppKit
import Combine

/// What the View menu does to the window: ⇧⌘D folds the sidebar away and
/// brings it back, ⌘F puts the caret in the toolbar's search field, ⌥⌘F
/// turns the item list's header into a field, ⌘1 is All Items and ⌘2 to ⌘9
/// are the vaults in the sidebar's order, ⌘[ and ⌘] go back and forward, and
/// ⌘+, ⌘- and ⌘0 are the three sizes (`docs/look.md`, "The keyboard"). ⌘/,
/// the table of all of them, goes in the Help menu when there is one. Every
/// key is read from `KeyTable`. There are panes only while the vault is
/// open, so on the lock screen everything but the sizes is grey and the
/// vaults are not in the menu at all.
@MainActor
final class WindowCommands: NSObject, NSMenuItemValidation {
    private let door: Door
    /// All Items, then one for each of ⌘2 to ⌘9, a vault's name on it while
    /// there is such a vault and the vault is open.
    private(set) var rowItems: [NSMenuItem] = []
    private var watching: Set<AnyCancellable> = []

    init(door: Door) {
        self.door = door
        super.init()
        rowItems = (1...9).map { digit in
            let item = digit == 1
                ? KeyTable.item(.allItems, action: #selector(selectRowFromMenu(_:)), target: self)
                : KeyTable.item(.vaults, stroke: digit - 2, title: "", action: #selector(selectRowFromMenu(_:)),
                                target: self)
            item.tag = digit
            item.isHidden = digit > 1
            return item
        }
        // Both publish before they change, so the names are read a turn
        // later, when the shelves are the new ones.
        door.$panes.map { _ in () }.merge(with: door.store.$revision.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.nameVaults() }
            .store(in: &watching)
        // That turn is too long for a lock: the names are out of the menu
        // before whoever locked the vault is told it is locked. The panes
        // are gone by the time this is posted.
        NotificationCenter.default.publisher(for: VaultStore.didLock, object: door.store)
            .sink { [weak self] _ in self?.nameVaults() }
            .store(in: &watching)
    }

    /// A lock takes the names out of the menu with everything else.
    func nameVaults() {
        let vaults = door.panes?.vaults ?? []
        for item in rowItems.dropFirst() {
            let vault = vaults.indices.contains(item.tag - 2) ? vaults[item.tag - 2] : nil
            item.title = vault?.name ?? ""
            item.isHidden = vault == nil
        }
    }

    func sidebarItem() -> NSMenuItem {
        KeyTable.item(.sidebar, title: "Hide Sidebar", action: #selector(toggleSidebarFromMenu(_:)), target: self)
    }

    func searchItem() -> NSMenuItem {
        KeyTable.item(.search, action: #selector(searchFromMenu(_:)), target: self)
    }

    func filterItem() -> NSMenuItem {
        KeyTable.item(.filter, title: "Find in List", action: #selector(filterFromMenu(_:)), target: self)
    }

    /// Back and forward, then the three sizes, each group after a rule.
    func laterItems() -> [NSMenuItem] {
        [
            .separator(),
            KeyTable.item(.back, action: #selector(backFromMenu(_:)), target: self),
            KeyTable.item(.forward, action: #selector(forwardFromMenu(_:)), target: self),
            .separator(),
            KeyTable.item(.zoomIn, title: "Zoom In", action: #selector(zoomInFromMenu(_:)), target: self),
            KeyTable.item(.zoomOut, title: "Zoom Out", action: #selector(zoomOutFromMenu(_:)), target: self),
            KeyTable.item(.actualSize, title: "Actual Size", action: #selector(actualSizeFromMenu(_:)),
                          target: self),
        ]
    }

    func shortcutsItem() -> NSMenuItem {
        KeyTable.item(.shortcuts, title: "Keyboard Shortcuts", action: #selector(shortcutsFromMenu(_:)),
                      target: self)
    }

    /// At the top of the View menu, which is made before the Window menu if
    /// the app has none.
    func install(in mainMenu: NSMenu, before windowMenu: NSMenu? = NSApp.windowsMenu) {
        let view: NSMenu
        if let found = mainMenu.items.first(where: { $0.submenu?.title == "View" })?.submenu {
            view = found
            if !view.items.isEmpty { view.insertItem(.separator(), at: 0) }
        } else {
            view = NSMenu(title: "View")
            let host = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
            host.submenu = view
            let window = mainMenu.items.firstIndex { $0.submenu === windowMenu }
            mainMenu.insertItem(host, at: window ?? mainMenu.items.count)
        }
        view.insertItem(sidebarItem(), at: 0)
        view.insertItem(searchItem(), at: 1)
        view.insertItem(filterItem(), at: 2)
        view.insertItem(.separator(), at: 3)
        for (index, item) in (rowItems + laterItems()).enumerated() {
            view.insertItem(item, at: 4 + index)
        }
        if let help = mainMenu.items.first(where: { $0.submenu?.title == "Help" })?.submenu {
            help.insertItem(shortcutsItem(), at: 0)
        } else {
            view.insertItem(.separator(), at: 4 + rowItems.count + laterItems().count)
            view.insertItem(shortcutsItem(), at: 5 + rowItems.count + laterItems().count)
        }
    }

    /// False when there is no such row: locked, or fewer vaults than the key.
    @discardableResult
    func selectRow(_ digit: Int) -> Bool {
        guard let panes = door.panes else { return false }
        if digit == 1 {
            panes.select(.allItems)
            return true
        }
        return panes.selectVault(at: digit - 2)
    }

    @objc private func selectRowFromMenu(_ sender: NSMenuItem) { selectRow(sender.tag) }

    func toggleSidebar() {
        door.panes?.toggleSidebar()
    }

    @objc private func toggleSidebarFromMenu(_ sender: Any?) { toggleSidebar() }

    @objc private func searchFromMenu(_ sender: Any?) { door.panes?.beginSearch() }

    @objc private func filterFromMenu(_ sender: Any?) { door.panes?.beginFilter() }

    @objc private func backFromMenu(_ sender: Any?) { door.panes?.goBack() }

    @objc private func forwardFromMenu(_ sender: Any?) { door.panes?.goForward() }

    @objc private func zoomInFromMenu(_ sender: Any?) { door.zoom(to: door.zoom.larger) }

    @objc private func zoomOutFromMenu(_ sender: Any?) { door.zoom(to: door.zoom.smaller) }

    @objc private func actualSizeFromMenu(_ sender: Any?) { door.zoom(to: .actual) }

    @objc private func shortcutsFromMenu(_ sender: Any?) { door.panes?.toggleKeys() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(selectRowFromMenu(_:)) {
            return item.tag == 1 ? door.panes != nil : (door.panes?.vaults.count ?? 0) > item.tag - 2
        }
        switch item.action {
        case #selector(backFromMenu(_:)): return door.panes?.canGoBack == true
        case #selector(forwardFromMenu(_:)): return door.panes?.canGoForward == true
        case #selector(zoomInFromMenu(_:)): return door.zoom.larger != nil
        case #selector(zoomOutFromMenu(_:)): return door.zoom.smaller != nil
        case #selector(actualSizeFromMenu(_:)): return door.zoom != .actual
        case #selector(shortcutsFromMenu(_:)): return door.panes != nil
        default: break
        }
        if item.action == #selector(searchFromMenu(_:)) { return door.panes != nil }
        if item.action == #selector(filterFromMenu(_:)) { return door.panes?.isSearching == false }
        guard item.action == #selector(toggleSidebarFromMenu(_:)) else { return true }
        item.title = door.panes?.wantsSidebar == false ? "Show Sidebar" : "Hide Sidebar"
        return door.panes != nil
    }
}
