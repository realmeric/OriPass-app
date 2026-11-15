import AppKit

/// What the mark's menu holds, from `docs/look.md` "The menu bar": Open the
/// app, Open Quick Access with its key beside it, a rule, Lock, Settings and
/// Quit, and over Lock while any pass stands how many and Revoke All. The rows are a value, so that the menu and the shot of it are made
/// from one list and cannot disagree about what is in it.
@MainActor
final class MarkMenu: NSObject {
    enum Command: Int, CaseIterable {
        case openApp, openQuick, passes, revokePasses, lock, settings, quit
    }

    struct Row: Equatable {
        /// Nil for the rule.
        let command: Command?
        let title: String
        /// The key, as it is drawn beside the title.
        let caps: [String]
        let isEnabled: Bool
        /// The key as a menu item has it, when there is one.
        let stroke: Stroke?

        static let rule = Row(command: nil, title: "", caps: [], isEnabled: false, stroke: nil)
    }

    private let door: Door
    private let quick: QuickAccess
    private let lock: LockCommands
    private let showApp: () -> Void
    private let quickKey: () -> HotKey?
    /// What raises the settings window. Without it the row is grey.
    private let showSettings: (() -> Void)?

    /// `quickKey` is what Quick Access is on now, which is what is written
    /// beside it, and nothing at all when the system refused it.
    init(door: Door, quick: QuickAccess, lock: LockCommands, showApp: @escaping () -> Void,
         showSettings: (() -> Void)? = nil, quickKey: @escaping () -> HotKey?) {
        self.showSettings = showSettings
        self.door = door
        self.quick = quick
        self.lock = lock
        self.showApp = showApp
        self.quickKey = quickKey
    }

    /// The key a menu item draws for a hot key. A key with no letter that
    /// can be written is drawn as its words by the shot and not at all in
    /// the menu.
    static func stroke(for hotKey: HotKey) -> Stroke? {
        let letter = HotKey.letter(for: hotKey.key)
        guard letter.count == 1 else { return nil }
        return Stroke(letter.lowercased(), hotKey.flags)
    }

    func rows() -> [Row] {
        let key = quickKey()
        let stroke = key.flatMap(Self.stroke(for:))
        return [
            Row(command: .openApp, title: "Open \(AppInfo.name)", caps: [], isEnabled: true, stroke: nil),
            Row(command: .openQuick, title: "Open Quick Access", caps: key?.caps ?? [],
                isEnabled: true, stroke: stroke),
            .rule,
        ] + passRows + [
            Row(command: .lock, title: "Lock", caps: [], isEnabled: door.store.state == .unlocked, stroke: nil),
            Row(command: .settings, title: "Settings", caps: [], isEnabled: showSettings != nil, stroke: nil),
            Row(command: .quit, title: "Quit", caps: [], isEnabled: true, stroke: nil),
        ]
    }

    /// Nothing unless a pass stands, so the menu is what it was without one.
    private var passRows: [Row] {
        guard let running = AgentPasses.running(door.passes.standing.count) else { return [] }
        return [
            Row(command: .passes, title: running, caps: [], isEnabled: false, stroke: nil),
            Row(command: .revokePasses, title: "Revoke All", caps: [], isEnabled: true, stroke: nil),
            .rule,
        ]
    }

    func menu() -> NSMenu {
        let menu = NSMenu(title: AppInfo.name)
        menu.autoenablesItems = false
        for row in rows() {
            guard let command = row.command else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: row.title, action: nil, keyEquivalent: row.stroke?.key ?? "")
            item.keyEquivalentModifierMask = row.stroke?.modifiers ?? []
            item.identifier = Self.identifier(command)
            item.isEnabled = row.isEnabled
            switch command {
            case .quit:
                // The application's own, so that quitting goes down the
                // road every quit goes, to the delegate that shuts the
                // child first (`AppDelegate.applicationShouldTerminate`).
                item.action = #selector(NSApplication.terminate(_:))
                item.target = NSApp
            default:
                item.action = #selector(chosen(_:))
                item.target = self
                item.tag = command.rawValue
            }
            menu.addItem(item)
        }
        return menu
    }

    static func identifier(_ command: Command) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("menubar.\(command)")
    }

    func perform(_ command: Command) {
        switch command {
        case .openApp: showApp()
        case .openQuick: quick.show()
        case .passes: break
        case .revokePasses: door.passes.endAll()
        case .lock: lock.lock()
        case .settings: showSettings?()
        case .quit: NSApp.terminate(nil)
        }
    }

    /// What a click on the mark does.
    func clickOnMark() {
        quick.toggle()
    }

    @objc private func chosen(_ sender: NSMenuItem) {
        guard let command = Command(rawValue: sender.tag) else { return }
        perform(command)
    }
}
