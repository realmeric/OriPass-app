import AppKit

/// One press: a key and what is held with it. A menu item's key equivalent
/// and a key event at the window both come down to one of these, so the two
/// can be laid beside each other.
struct Stroke: Hashable {
    static let up = "\u{F700}"
    static let down = "\u{F701}"
    static let left = "\u{F702}"
    static let right = "\u{F703}"
    static let enter = "\r"
    static let space = " "
    static let escape = "\u{1B}"
    static let delete = "\u{8}"

    /// As `NSMenuItem.keyEquivalent` has it: lower case, and empty for a
    /// modifier held by itself.
    let key: String
    private let held: UInt

    init(_ key: String, _ modifiers: NSEvent.ModifierFlags = []) {
        self.key = key
        held = modifiers.intersection(Self.counted).rawValue
    }

    /// A key going down, with the arrows' own flags and Caps Lock left out.
    init?(_ event: NSEvent) {
        let key: String
        switch event.specialKey {
        case .delete?, .backspace?: key = Self.delete
        case .carriageReturn?, .enter?, .newline?: key = Self.enter
        default: key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        }
        guard !key.isEmpty else { return nil }
        self.init(key, event.modifierFlags)
    }

    private static let counted: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: held) }

    /// What is drawn on the caps, in the order a menu writes them.
    var caps: [String] {
        var caps: [String] = []
        if modifiers.contains(.control) { caps.append("⌃") }
        if modifiers.contains(.option) { caps.append("⌥") }
        if modifiers.contains(.shift) { caps.append("⇧") }
        if modifiers.contains(.command) { caps.append("⌘") }
        switch key {
        case "": break
        case Self.up: caps.append("↑")
        case Self.down: caps.append("↓")
        case Self.left: caps.append("←")
        case Self.right: caps.append("→")
        case Self.enter: caps.append("Return")
        case Self.space: caps.append("Space")
        case Self.escape: caps.append("Esc")
        case Self.delete: caps.append("Delete")
        default: caps.append(key.uppercased())
        }
        return caps
    }

    var symbols: String { caps.joined() }
}

/// A key the window takes with nothing held, wherever the keys are in it.
/// The list's own view catches them (`ListKeys`) and the panes decide what
/// each means for the column that has the keys (`Panes.press`).
enum PaneKey: CaseIterable {
    case up, down, left, right, enter, space, escape, delete

    var stroke: Stroke {
        switch self {
        case .up: return Stroke(Stroke.up)
        case .down: return Stroke(Stroke.down)
        case .left: return Stroke(Stroke.left)
        case .right: return Stroke(Stroke.right)
        case .enter: return Stroke(Stroke.enter)
        case .space: return Stroke(Stroke.space)
        case .escape: return Stroke(Stroke.escape)
        case .delete: return Stroke(Stroke.delete)
        }
    }

    /// The row of the table it is drawn in.
    var command: KeyCommand.ID {
        switch self {
        case .up, .down: return .rows
        case .left, .right: return .sections
        case .enter, .space: return .activate
        case .escape: return .dismiss
        case .delete: return .archive
        }
    }

    init?(_ stroke: Stroke) {
        guard let key = Self.allCases.first(where: { $0.stroke == stroke }) else { return nil }
        self = key
    }
}

/// One row of the keyboard table (`docs/look.md`, "The keyboard").
struct KeyCommand: Identifiable {
    enum ID: String, CaseIterable {
        case quickAccess, lock, autofill
        case settings, shortcuts, search, filter, allItems, vaults, back, forward, sidebar
        case zoomIn, zoomOut, actualSize
        case rows, sections, activate, dismiss
        case copy, copyPassword, copyCode, openAndFill, openWindow, newItem, edit, save
        case reveal, peek, archive, delete
    }

    /// The headings the sheet files its rows under.
    enum Section: String, CaseIterable {
        case window = "The window"
        case moving = "Moving about"
        case item = "The item"
        case anywhere = "Anywhere in the app"
    }

    /// How the app comes to hear of it: an item of its own in the menu bar,
    /// the Edit menu's Copy, the app menu's Settings (both of which the
    /// scene makes and the delegate answers), a key at the window, a
    /// modifier held down, or a key taken from the whole system
    /// (`HotKeyAction`). Lock is a menu item and also a hot key; this says
    /// only the first.
    enum Bound {
        case menu, editMenu, appMenu, keys, held, hotKey
    }

    let id: ID
    /// What the sheet says it does, and the menu's item unless the menu has
    /// a word that changes.
    var name: String
    let section: Section
    var strokes: [Stroke]
    let bound: Bound
    /// The card that will make it work. The sheet draws no row that has one.
    var waits: String?
    /// The strokes are the first and the last of a run, ⌘2 to ⌘9.
    var isRun = false
}

/// Every key the app answers to, once. The menus make their items from it
/// (`KeyTable.item`), the window's catcher takes the keys it lists and no
/// others, and the sheet behind ⌘/ draws the rows of it that work. So the
/// sheet cannot name a key the app does not have, and `KeyTableTests` holds
/// the other half: that every row of it is bound, and to one thing.
///
/// The keys here are a US keyboard's. In the menu bar AppKit moves some of
/// them for the keyboard in use, ⌘[ to ⌘Ğ on a Turkish one, and the sheet
/// draws a row as the menu bar has it (`asBound`).
enum KeyTable {
    static let all: [KeyCommand] = [
        menu(.shortcuts, "Keyboard shortcuts", .window, "/", .command),
        menu(.search, "Search", .window, "f", .command),
        menu(.filter, "Find in the list", .window, "f", [.command, .option]),
        menu(.allItems, "All Items", .window, "1", .command),
        KeyCommand(id: .vaults, name: "The vaults, in order", section: .window,
                   strokes: (2...9).map { Stroke(String($0), .command) }, bound: .menu, isRun: true),
        menu(.back, "Back", .window, "[", .command),
        menu(.forward, "Forward", .window, "]", .command),
        menu(.sidebar, "Hide or show the sidebar", .window, "d", [.command, .shift]),
        menu(.zoomIn, "Zoom in", .window, "+", .command),
        menu(.zoomOut, "Zoom out", .window, "-", .command),
        menu(.actualSize, "Actual size", .window, "0", .command),
        KeyCommand(id: .settings, name: "Settings", section: .window,
                   strokes: [Stroke(",", .command)], bound: .appMenu),

        keys(.rows, "The row above or below", .moving),
        keys(.sections, "The column to the left or right", .moving),
        keys(.activate, "Go in, or copy the field", .moving),
        keys(.dismiss, "Close a menu, clear the search", .moving),

        KeyCommand(id: .copy, name: copyName(forUsername: nil), section: .item,
                   strokes: [Stroke("c", .command)], bound: .editMenu),
        menu(.copyPassword, "Copy the password", .item, "c", [.command, .shift]),
        menu(.copyCode, "Copy the one-time code", .item, "c", [.command, .option]),
        menu(.reveal, "Reveal or conceal the hidden fields", .item, "r", .command),
        KeyCommand(id: .peek, name: "Reveal them while it is held", section: .item,
                   strokes: [Stroke("", .option)], bound: .held),
        menu(.openWindow, "Open in a new window", .item, "o", .command),
        menu(.openAndFill, "Open the website and fill", .item, "f", [.command, .shift]),
        menu(.newItem, "New item", .item, "n", .command),
        menu(.edit, "Edit", .item, "e", .command),
        menu(.save, "Save", .item, "s", .command),
        keys(.archive, "Move to the Archive", .item),
        menu(.delete, "Delete", .item, Stroke.delete, .command),

        menu(.lock, "Lock", .anywhere, "l", [.command, .shift]),
        KeyCommand(id: .quickAccess, name: "Quick Access", section: .anywhere,
                   strokes: [Stroke("\\", [.command, .option])], bound: .hotKey),
        KeyCommand(id: .autofill, name: "Fill the app in front", section: .anywhere,
                   strokes: [Stroke("\\", .command)], bound: .hotKey),
    ]

    private static func menu(_ id: KeyCommand.ID, _ name: String, _ section: KeyCommand.Section, _ key: String,
                             _ modifiers: NSEvent.ModifierFlags, waits: String? = nil) -> KeyCommand {
        KeyCommand(id: id, name: name, section: section, strokes: [Stroke(key, modifiers)], bound: .menu,
                   waits: waits)
    }

    /// A row for the bare keys that say they belong to it.
    private static func keys(_ id: KeyCommand.ID, _ name: String, _ section: KeyCommand.Section) -> KeyCommand {
        KeyCommand(id: id, name: name, section: section,
                   strokes: PaneKey.allCases.filter { $0.command == id }.map(\.stroke), bound: .keys)
    }

    /// What ⌘C's row says, the username by the word for the one it is
    /// handed (`Login.word`).
    static func copyName(forUsername username: String?) -> String {
        "Copy the \(Login.word(forUsername: username)) or the first field"
    }

    static subscript(id: KeyCommand.ID) -> KeyCommand {
        guard let command = all.first(where: { $0.id == id }) else {
            preconditionFailure("no row for \(id.rawValue) in the key table")
        }
        return command
    }

    /// The rows that do something today.
    static var working: [KeyCommand] { all.filter { $0.waits == nil } }

    /// A menu item on the row's key. `stroke` picks one of a run's.
    static func item(_ id: KeyCommand.ID, stroke: Int = 0, title: String? = nil, action: Selector,
                     target: AnyObject) -> NSMenuItem {
        let command = self[id]
        let stroke = command.strokes[stroke]
        let item = NSMenuItem(title: title ?? command.name, action: action, keyEquivalent: stroke.key)
        item.keyEquivalentModifierMask = stroke.modifiers
        item.target = target
        item.identifier = name(id, stroke: command.strokes.firstIndex(of: stroke) ?? 0)
        return item
    }

    /// What an item made here is called, so it can be found again whatever
    /// key AppKit has since given it.
    static func name(_ id: KeyCommand.ID, stroke: Int = 0) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("key.\(id.rawValue).\(stroke)")
    }

    static func item(_ id: KeyCommand.ID, stroke: Int = 0, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        let wanted = name(id, stroke: stroke)
        for item in menu.items {
            if item.identifier == wanted { return item }
            if let found = self.item(id, stroke: stroke, in: item.submenu) { return found }
        }
        return nil
    }

    /// The row with the keys its items have in `menu`, which is the menu
    /// bar's: a key AppKit moved for the keyboard is drawn where it went. A
    /// row with no item there is as the table has it.
    static func asBound(_ command: KeyCommand, in menu: NSMenu?) -> KeyCommand {
        guard command.bound == .menu, menu != nil else { return command }
        var bound = command
        bound.strokes = command.strokes.indices.map { place in
            item(command.id, stroke: place, in: menu).map { Stroke($0.keyEquivalent, $0.keyEquivalentModifierMask) }
                ?? command.strokes[place]
        }
        return bound
    }
}
