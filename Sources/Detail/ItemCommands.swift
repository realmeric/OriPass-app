import AppKit

/// What the keys do to the item in the details (`docs/look.md`, "The
/// keyboard"): ⌘C copies its username or its type's first field, ⇧⌘C its
/// password, ⌥⌘C its one-time code as it stands at that instant, and ⌘R shows
/// or hides every hidden field. ⌘N raises the sheet a new item is chosen
/// from, Password Generator raises the generator by itself (`Generator`),
/// ⌘E turns the details into a form and ⌘S saves it (`Editor`). ⌘C is the Edit menu's own Copy, which comes
/// here when nothing with a selection of its own is in the way. The rest
/// are an Item menu, which ends in ⌘O, a window of the item's own, ⇧⌘F, which
/// opens its website and arms a fill (`ArmedFill`), and ⌘Delete, which
/// deletes it (`ItemMenu`). Delete alone archives, and is the list's key and
/// no menu's, since a menu would take it from every field.
///
/// They are done to the item in the window that has the keys: one of the
/// windows of one item, or the main one. With the keys in any other
/// window, the settings' or a preview's, or in none, they are done to
/// nothing and their rows are grey: ⌘Delete pressed over the settings
/// used to send the item selected behind them to Recently Deleted.
@MainActor
final class ItemCommands: NSObject, NSMenuItemValidation {
    private let door: Door
    /// Whether the keys are in a field, where ⌘Delete rubs out a line.
    private let isTyping: () -> Bool

    /// Whether the main window is the one with the keys. The settings
    /// window, a preview, a panel and no window at all are none of the
    /// vault's, and a key pressed there is not about the item behind it.
    private let mainHasKeys: () -> Bool

    init(door: Door, mainHasKeys: @escaping () -> Bool = { true },
         isTyping: @escaping () -> Bool = { NSApp.keyWindow?.firstResponder is NSText }) {
        self.door = door
        self.isTyping = isTyping
        self.mainHasKeys = mainHasKeys
    }

    private var panes: Panes? {
        door.panes?.windows?.inFront ?? (mainHasKeys() ? door.panes : nil)
    }

    func menu() -> NSMenu {
        let menu = NSMenu(title: "Item")
        let new = KeyTable.item(.newItem, title: "New Item…", action: #selector(newFromMenu(_:)), target: self)
        // It has no key in the table this app's keys are taken from.
        let generator = NSMenuItem(title: "Password Generator…", action: #selector(generatorFromMenu(_:)),
                                   keyEquivalent: "")
        generator.target = self
        let edit = KeyTable.item(.edit, action: #selector(editFromMenu(_:)), target: self)
        let save = KeyTable.item(.save, action: #selector(saveFromMenu(_:)), target: self)
        let password = KeyTable.item(.copyPassword, title: "Copy Password",
                                     action: #selector(copyPasswordFromMenu(_:)), target: self)
        let code = KeyTable.item(.copyCode, title: "Copy One-Time Code", action: #selector(copyCodeFromMenu(_:)),
                                 target: self)
        let reveal = KeyTable.item(.reveal, title: "Reveal", action: #selector(revealFromMenu(_:)), target: self)
        let window = KeyTable.item(.openWindow, title: ItemAct.openWindow.name,
                                   action: #selector(openWindowFromMenu(_:)), target: self)
        let fill = KeyTable.item(.openAndFill, title: "Open Website and Fill",
                                 action: #selector(openAndFillFromMenu(_:)), target: self)
        let delete = KeyTable.item(.delete, title: ItemAct.delete.name, action: #selector(deleteFromMenu(_:)),
                                   target: self)
        [new, generator, .separator(), edit, save, .separator(), password, code, .separator(), reveal, .separator(), window, fill, .separator(),
         delete].forEach(menu.addItem)
        return menu
    }

    /// Before the Window menu, and so before Vault when Vault is put in
    /// after it.
    func install(in mainMenu: NSMenu, before windowMenu: NSMenu? = NSApp.windowsMenu) {
        let host = NSMenuItem(title: "Item", action: nil, keyEquivalent: "")
        host.submenu = menu()
        let window = mainMenu.items.firstIndex { $0.submenu === windowMenu }
        mainMenu.insertItem(host, at: window ?? mainMenu.items.count)
    }

    /// Whether ⌘C has anything to copy.
    var canCopy: Bool { panes?.detail?.primaryRow != nil }

    @discardableResult
    func copyPrimary() -> Bool { panes?.copyPrimary() ?? false }

    @discardableResult
    func copyPassword() -> Bool { panes?.copyPassword() ?? false }

    @discardableResult
    func copyCode() -> Bool { panes?.copyCode() ?? false }

    func toggleRevealed() { panes?.toggleRevealed() }

    @discardableResult
    func openWindow() -> Bool { door.panes?.openWindow() ?? false }

    @discardableResult
    func openAndFill() -> Bool { panes?.openAndFill() ?? false }

    /// The main window's, whichever window has the keys.
    @discardableResult
    func newItem() -> Bool { door.panes?.beginNew() ?? false }

    /// By itself over the main window, whichever window has the keys.
    @discardableResult
    func generate() -> Bool { door.panes?.beginGenerating(for: .alone) ?? false }

    @discardableResult
    func edit() -> Bool { panes?.beginEdit() ?? false }

    @discardableResult
    func save() -> Task<Void, Never>? { panes?.saveEdit() }

    @discardableResult
    func delete() -> Bool { panes?.deleteSelected() ?? false }

    @objc private func copyPasswordFromMenu(_ sender: Any?) { copyPassword() }
    @objc private func copyCodeFromMenu(_ sender: Any?) { copyCode() }
    @objc private func revealFromMenu(_ sender: Any?) { toggleRevealed() }
    @objc private func openWindowFromMenu(_ sender: Any?) { openWindow() }
    @objc private func openAndFillFromMenu(_ sender: Any?) { openAndFill() }
    @objc private func deleteFromMenu(_ sender: Any?) { delete() }
    @objc private func newFromMenu(_ sender: Any?) { newItem() }
    @objc private func generatorFromMenu(_ sender: Any?) { generate() }
    @objc private func editFromMenu(_ sender: Any?) { edit() }
    @objc private func saveFromMenu(_ sender: Any?) { save() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copyPasswordFromMenu(_:)):
            return panes?.detail?.passwordRowID != nil
        case #selector(copyCodeFromMenu(_:)):
            return panes?.detail?.codeRowID != nil
        case #selector(revealFromMenu(_:)):
            item.title = panes?.isAllRevealed == true ? "Conceal" : "Reveal"
            return panes?.canReveal == true
        case #selector(newFromMenu(_:)), #selector(generatorFromMenu(_:)):
            return door.panes != nil
        case #selector(editFromMenu(_:)):
            return panes?.canEdit == true
        case #selector(saveFromMenu(_:)):
            return panes?.editor?.canSave == true
        case #selector(openWindowFromMenu(_:)):
            // The main window's item, whichever window has the keys.
            return door.panes?.itemActs.joined().contains(.openWindow) == true
        case #selector(openAndFillFromMenu(_:)):
            return panes?.canOpenAndFill == true
        case #selector(deleteFromMenu(_:)):
            let act = panes?.itemActs.joined().first(where: \.isRed)
            item.title = (act ?? .delete).name
            return panes?.canDeleteSelected == true && !isTyping()
        default:
            return true
        }
    }
}
