import AppKit
import Carbon.HIToolbox

/// The things a key can do from anywhere in the system.
enum HotKeyAction: String, CaseIterable, Codable {
    case quickAccess
    case lock
    case showApp
    /// Last, because a key's id with Carbon is its place here.
    case fill

    var title: String {
        switch self {
        case .quickAccess: return "Open Quick Access"
        case .lock: return "Lock"
        case .showApp: return "Show OriPass"
        case .fill: return "Fill the app in front"
        }
    }

    /// What the key is until `ShortcutChoices` says otherwise. The one place
    /// the defaults are written. Show OriPass has none: a key nobody asked
    /// for is a key some other app loses.
    var fallback: HotKey? {
        switch self {
        case .quickAccess:
            return HotKey(key: UInt32(kVK_ANSI_Backslash), carbon: UInt32(cmdKey | optionKey))
        case .lock:
            return HotKey(key: UInt32(kVK_ANSI_L), carbon: UInt32(cmdKey | shiftKey))
        case .showApp:
            return nil
        case .fill:
            return HotKey(key: UInt32(kVK_ANSI_Backslash), carbon: UInt32(cmdKey))
        }
    }

    /// The row of the keyboard table this action's default is.
    var command: KeyCommand.ID? {
        switch self {
        case .quickAccess: return .quickAccess
        case .lock: return .lock
        case .showApp: return nil
        case .fill: return .autofill
        }
    }
}

/// One combination, in the numbers Carbon wants and the words a person reads.
struct HotKey: Codable, Equatable, Hashable {
    /// A virtual key code, which is the key's place on the board rather than
    /// the letter printed on it: the same physical key on every layout.
    var key: UInt32
    /// Carbon's own modifier mask, which is not `NSEvent`'s.
    var carbon: UInt32

    var flags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbon & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbon & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbon & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        return mask
    }

    /// "⌥⌘\", in the order the menu bar writes them.
    var words: String { caps.joined() }

    /// The same one cap at a time, as a row of keys is drawn.
    var caps: [String] {
        var caps: [String] = []
        if carbon & UInt32(controlKey) != 0 { caps.append("⌃") }
        if carbon & UInt32(optionKey) != 0 { caps.append("⌥") }
        if carbon & UInt32(shiftKey) != 0 { caps.append("⇧") }
        if carbon & UInt32(cmdKey) != 0 { caps.append("⌘") }
        return caps + [Self.letter(for: key)]
    }

    /// What an American board prints on the key, for the codes anybody
    /// binds. A code with no name here is shown as its number rather than
    /// guessed at. On another layout the key prints something else: the
    /// code at `kVK_ANSI_Backslash` prints a comma on this Mac's Turkish one.
    static func letter(for key: UInt32) -> String {
        let named: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_Space: "Space", kVK_Return: "Return", kVK_Escape: "Esc",
            kVK_Tab: "Tab", kVK_ANSI_Slash: "/", kVK_ANSI_Period: ".",
            kVK_ANSI_Comma: ",", kVK_ANSI_Backslash: "\\",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16",
            kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
        ]
        return named[Int(key)] ?? "#\(key)"
    }
}

/// Why a combination was not taken.
enum HotKeyRefusal: Equatable {
    /// Nothing but ⌘, or nothing at all: the system and every text field on
    /// this Mac already use those.
    case notEnoughModifiers
    /// One of the handful every Mac reserves.
    case reserved(String)
    /// Already bound to something else here.
    case taken(HotKeyAction)
    /// Carbon said no, which is what it says when another app, or another
    /// registration in this one, already holds the combination.
    case systemRefused(OSStatus)

    var words: String {
        switch self {
        case .notEnoughModifiers:
            return "Needs Control or Option as well, or Command and Shift together, "
                + "or it would swallow the key everywhere."
        case let .reserved(what):
            return "\(what) belongs to the system on every Mac."
        case let .taken(action):
            return "Already used for \(action.title.lowercased())."
        case .systemRefused:
            return "Another app has it."
        }
    }
}

/// Whether a combination may be taken at all, before Carbon is asked.
///
/// Carbon will happily hand over ⌘C system-wide, and an app that takes it has
/// broken copy in every other app on the Mac. So the refusal is ours, not the
/// system's: the system has no opinion until it is too late.
enum HotKeyRules {
    /// The ones no app may have, as the system uses them.
    static let reserved: [(key: Int, modifiers: NSEvent.ModifierFlags, name: String)] = [
        (kVK_ANSI_C, .command, "⌘C"), (kVK_ANSI_V, .command, "⌘V"),
        (kVK_ANSI_X, .command, "⌘X"), (kVK_ANSI_Z, .command, "⌘Z"),
        (kVK_ANSI_A, .command, "⌘A"), (kVK_ANSI_S, .command, "⌘S"),
        (kVK_ANSI_Q, .command, "⌘Q"), (kVK_ANSI_W, .command, "⌘W"),
        (kVK_Space, .command, "⌘Space"), (kVK_Tab, .command, "⌘Tab"),
        (kVK_ANSI_Z, [.command, .shift], "⇧⌘Z"), (kVK_ANSI_Q, [.command, .shift], "⇧⌘Q"),
        (kVK_ANSI_3, [.command, .shift], "⇧⌘3"), (kVK_ANSI_4, [.command, .shift], "⇧⌘4"),
        (kVK_ANSI_5, [.command, .shift], "⇧⌘5"),
        (kVK_Escape, [.command, .option], "⌥⌘Esc"), (kVK_ANSI_Q, [.command, .control], "⌃⌘Q"),
    ]

    static func refusal(for hotKey: HotKey, taken: [HotKeyAction: HotKey],
                        by action: HotKeyAction) -> HotKeyRefusal? {
        let flags = hotKey.flags
        if let reserved = reserved.first(where: { $0.key == Int(hotKey.key) && $0.modifiers == flags }) {
            return .reserved(reserved.name)
        }
        // ⌘ alone is every menu on the Mac, and a bare key is every text
        // field: a global hot key needs Control or Option in it, or Command
        // and Shift together, which is how Lock has always been written.
        // An action's own default is let through: ⌘\ is the fill's in the
        // table this app keeps (D16), and it is the one key with ⌘ alone.
        let enough = flags.contains(.control) || flags.contains(.option)
            || (flags.contains(.command) && flags.contains(.shift))
        guard enough || hotKey == action.fallback else { return .notEnoughModifiers }
        if let other = taken.first(where: { $0.value == hotKey && $0.key != action }) {
            return .taken(other.key)
        }
        return nil
    }
}

/// The hot keys, registered with Carbon.
///
/// `RegisterEventHotKey` is the only public way to consume a key everywhere
/// without Accessibility: an event tap needs the permission, and a global
/// monitor sees the key but cannot stop it reaching the app underneath.
///
/// Registered for as long as the app runs, locked or not: a key that only
/// worked while the vault was open could not be the one that opens it.
@MainActor
final class HotKeys {
    /// What to do when one fires.
    var onFire: ((HotKeyAction) -> Void)?

    /// Seconds from the key going down to the handler running, for the last
    /// press. Carbon stamps its event with the time the key arrived.
    private(set) var lastDelay: TimeInterval?

    /// What `apply` was last given and could not take.
    private(set) var refused: [HotKeyAction: HotKeyRefusal] = [:]

    private var registered: [HotKeyAction: (ref: EventHotKeyRef, key: HotKey)] = [:]
    private var handler: EventHandlerRef?
    private var registration: Instruments.Registration?
    /// Carbon calls back with an id, so the ids are ours to hand out.
    private static let signature = OSType(0x4F50_4B59)

    var bound: [HotKeyAction: HotKey] { registered.mapValues(\.key) }

    deinit {
        MainActor.assumeIsolated { unregisterAll() }
    }

    /// Register what is chosen, replacing whatever was registered before, by
    /// this object, even if it is the same key again.
    ///
    /// Returns what it could not take, so the app can say so rather than the
    /// binding quietly doing nothing.
    @discardableResult
    func apply(_ wanted: [HotKeyAction: HotKey]) -> [HotKeyAction: HotKeyRefusal] {
        installHandlerIfNeeded()
        unregisterAll(keepingHandler: true)

        var refused: [HotKeyAction: HotKeyRefusal] = [:]
        for action in HotKeyAction.allCases {
            guard let hotKey = wanted[action] else { continue }
            if let refusal = HotKeyRules.refusal(for: hotKey, taken: wanted, by: action) {
                refused[action] = refusal
                continue
            }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature,
                                   id: UInt32(HotKeyAction.allCases.firstIndex(of: action) ?? 0))
            let status = RegisterEventHotKey(hotKey.key, hotKey.carbon, id,
                                             GetEventDispatcherTarget(), 0, &ref)
            guard status == noErr, let ref else {
                refused[action] = .systemRefused(status)
                continue
            }
            registered[action] = (ref, hotKey)
        }
        self.refused = refused
        if !refused.isEmpty {
            Log.app.notice("\(refused.count, privacy: .public) shortcuts were refused")
        }
        return refused
    }

    func unregisterAll(keepingHandler: Bool = false) {
        for (_, each) in registered { UnregisterEventHotKey(each.ref) }
        registered = [:]
        guard !keepingHandler else { return }
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        registration = nil
    }

    /// What to tell him about a combination that was not taken, in a
    /// sentence of its own, or nil when everything asked for was taken.
    static func report(_ refused: [HotKeyAction: HotKeyRefusal],
                       asked wanted: [HotKeyAction: HotKey]) -> String? {
        let lines = HotKeyAction.allCases.compactMap { action -> String? in
            guard let refusal = refused[action], let key = wanted[action] else { return nil }
            return "\(key.words) for \(action.title.lowercased()): \(refusal.words)"
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let this = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            // Stamped when the key arrived, on the clock `NSEvent`'s
            // timestamps use, so the difference is the wait for this thread.
            let delay = ProcessInfo.processInfo.systemUptime - GetEventTime(event)
            let keys = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { keys.fire(id, delay: delay) }
            return noErr
        }, 1, &spec, this, &handler)
        registration = Instruments.register("hot-keys", kind: .observer, owner: "HotKeys")
    }

    func fire(_ id: EventHotKeyID, delay: TimeInterval = 0) {
        guard id.signature == Self.signature,
              Int(id.id) < HotKeyAction.allCases.count else { return }
        let action = HotKeyAction.allCases[Int(id.id)]
        lastDelay = delay
        Log.signposter.emitEvent("hot-key", "\(Int(delay * 1000), privacy: .public) ms from the key")
        Log.app.debug("hot key \(action.rawValue, privacy: .public)")
        onFire?(action)
    }

    /// What Carbon would hand the handler when `action`'s key goes down. A
    /// test sends it to the dispatcher, which is the whole of the path from
    /// the system's event to `onFire` short of the keyboard.
    static func press(_ action: HotKeyAction) -> OSStatus {
        var event: EventRef?
        var status = CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0,
                                 EventAttributes(kEventAttributeNone), &event)
        guard status == noErr, let event else { return status }
        defer { ReleaseEvent(event) }
        var id = EventHotKeyID(signature: signature,
                               id: UInt32(HotKeyAction.allCases.firstIndex(of: action) ?? 0))
        status = SetEventParameter(event, EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id)
        guard status == noErr else { return status }
        return SendEventToEventTarget(event, GetEventDispatcherTarget())
    }
}
