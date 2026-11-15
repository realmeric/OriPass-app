import AppKit

/// Every choice the app offers, in one value, each with its default beside
/// it. A new one is a line here and a room in the settings window, and
/// nothing else: no key of its own, no fallback written a second time.
///
/// Nothing in it is a secret, and `SettingsTests` holds the names to that.
/// It is written to the defaults as one JSON value (`SettingsStore`).
///
/// A part reads itself field by field, so a field that is missing, or holds
/// something of another type, or a word a newer build wrote, takes its
/// default and the fields beside it are kept.
struct Settings: Codable, Equatable {
    var lock = LockChoices()
    var clipboard = ClipboardChoices()
    var details = DetailChoices()
    var privacy = PrivacyChoices()
    var fill = FillChoices()
    var menuBar = MenuBarChoices()
    var shortcuts = ShortcutChoices()
    var list = ListChoices()
    var look = LookChoices()
    var engine = EngineChoices()
    var browser = BrowserChoices()
    var ssh = SSHChoices()

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Settings()
        lock = container.value(.lock, or: fallback.lock)
        clipboard = container.value(.clipboard, or: fallback.clipboard)
        details = container.value(.details, or: fallback.details)
        privacy = container.value(.privacy, or: fallback.privacy)
        fill = container.value(.fill, or: fallback.fill)
        menuBar = container.value(.menuBar, or: fallback.menuBar)
        shortcuts = container.value(.shortcuts, or: fallback.shortcuts)
        list = container.value(.list, or: fallback.list)
        look = container.value(.look, or: fallback.look)
        engine = container.value(.engine, or: fallback.engine)
        browser = container.value(.browser, or: fallback.browser)
        ssh = container.value(.ssh, or: fallback.ssh)
    }
}

// MARK: - The lock

/// When the vault shuts by itself, and how long a finger opens it for.
struct LockChoices: Codable, Equatable {
    var onSleep = true
    var onScreenLock = true
    var onScreenSaver = true
    var onUserSwitch = true
    var onQuit = true
    var whenIdle = true
    /// Minutes without a key or a pointer event anywhere on the Mac.
    var idleMinutes = 10
    /// D7's fourteen days: how old the sealed password may be and still open.
    var fingerDays = 14
    /// His answer to whether a finger should open the vault. Nil until he
    /// has been asked, which is once.
    var unlockWithFinger: Bool?

    var fingerLifetime: TimeInterval { TimeInterval(fingerDays) * 24 * 60 * 60 }

    func locks(_ condition: LockPolicy.Condition) -> Bool {
        switch condition {
        case .sleep: return onSleep
        case .screenLocked: return onScreenLock
        case .screenSaver: return onScreenSaver
        case .userSwitched: return onUserSwitch
        case .quit: return onQuit
        case .idle: return whenIdle
        }
    }

    mutating func set(_ condition: LockPolicy.Condition, to locks: Bool) {
        switch condition {
        case .sleep: onSleep = locks
        case .screenLocked: onScreenLock = locks
        case .screenSaver: onScreenSaver = locks
        case .userSwitched: onUserSwitch = locks
        case .quit: onQuit = locks
        case .idle: whenIdle = locks
        }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = LockChoices()
        onSleep = container.value(.onSleep, or: fallback.onSleep)
        onScreenLock = container.value(.onScreenLock, or: fallback.onScreenLock)
        onScreenSaver = container.value(.onScreenSaver, or: fallback.onScreenSaver)
        onUserSwitch = container.value(.onUserSwitch, or: fallback.onUserSwitch)
        onQuit = container.value(.onQuit, or: fallback.onQuit)
        whenIdle = container.value(.whenIdle, or: fallback.whenIdle)
        idleMinutes = container.value(.idleMinutes, or: fallback.idleMinutes)
        fingerDays = container.value(.fingerDays, or: fallback.fingerDays)
        unlockWithFinger = try? container.decodeIfPresent(Bool.self, forKey: .unlockWithFinger)
    }
}

// MARK: - The pasteboard

/// D15's two figures.
struct ClipboardChoices: Codable, Equatable {
    /// How long a copy stays before it is taken off again.
    var clearSeconds: Double = 90
    /// Kept off Universal Clipboard. Off, a copy reaches his other devices.
    var staysOnThisMac = true

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ClipboardChoices()
        clearSeconds = container.value(.clearSeconds, or: fallback.clearSeconds)
        staysOnThisMac = container.value(.staysOnThisMac, or: fallback.staysOnThisMac)
    }
}

// MARK: - The details

struct DetailChoices: Codable, Equatable {
    /// Holding ⌥ shows every hidden field for as long as it is held.
    var revealWithOption = false

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revealWithOption = container.value(.revealWithOption, or: DetailChoices().revealWithOption)
    }
}

// MARK: - What leaves this Mac

/// D14's switch and D13's two. The icons are on, as they are in the official
/// apps; the other two are requests he did not make by clicking, and are off
/// until he says so. The last is what is written to the system (D6), and is
/// off until he finds a page needs it (`PasskeyOffer`).
struct PrivacyChoices: Codable, Equatable {
    var siteIcons = true
    var breachCheck = false
    var twoFactorCheck = false
    var passkeysInSystemList = false

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = PrivacyChoices()
        siteIcons = container.value(.siteIcons, or: fallback.siteIcons)
        breachCheck = container.value(.breachCheck, or: fallback.breachCheck)
        twoFactorCheck = container.value(.twoFactorCheck, or: fallback.twoFactorCheck)
        passkeysInSystemList = container.value(.passkeysInSystemList, or: fallback.passkeysInSystemList)
    }
}

// MARK: - Filling

struct FillChoices: Codable, Equatable {
    /// "Return after the password".
    var pressesReturn = false

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pressesReturn = container.value(.pressesReturn, or: FillChoices().pressesReturn)
    }
}

// MARK: - The menu bar

/// The two switches the mark and the Dock icon answer to (`Presence`).
struct MenuBarChoices: Codable, Equatable {
    /// The mark is in the menu bar.
    var showsMark = true
    /// The Dock icon stays when no window is open.
    var keepsDock = true

    init() {}

    init(showsMark: Bool, keepsDock: Bool) {
        self.showsMark = showsMark
        self.keepsDock = keepsDock
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = MenuBarChoices()
        showsMark = container.value(.showsMark, or: fallback.showsMark)
        keepsDock = container.value(.keepsDock, or: fallback.keepsDock)
    }
}

// MARK: - The keys that work from any app

struct ShortcutChoices: Codable, Equatable {
    /// Only what somebody has changed, by the action's own name. An action
    /// that is absent takes its `fallback`, so a key added later is not
    /// unbound on a Mac that has settings already.
    var bound: [String: HotKey] = [:]

    /// What is written for an action he has taken the key away from, since
    /// an absent one means the default.
    private static let none = HotKey(key: 0, carbon: 0)

    func key(for action: HotKeyAction) -> HotKey? {
        guard let chosen = bound[action.rawValue] else { return action.fallback }
        return chosen == Self.none ? nil : chosen
    }

    /// Nil takes the key away, which for Show OriPass is where it starts.
    mutating func set(_ action: HotKeyAction, to key: HotKey?) {
        bound[action.rawValue] = key ?? Self.none
    }

    /// Back to the action's own default.
    mutating func forget(_ action: HotKeyAction) {
        bound.removeValue(forKey: action.rawValue)
    }

    /// What `HotKeys.apply` is given.
    var all: [HotKeyAction: HotKey] {
        Dictionary(uniqueKeysWithValues: HotKeyAction.allCases.compactMap { action in
            key(for: action).map { (action, $0) }
        })
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bound = container.value(.bound, or: [:])
    }
}

// MARK: - The list

/// The order and the category the item list was left in.
struct ListChoices: Codable, Equatable {
    var sort = ItemList.Key.title
    var isReversed = false
    var category = ItemList.Category.all

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ListChoices()
        sort = container.value(.sort, or: fallback.sort)
        isReversed = container.value(.isReversed, or: fallback.isReversed)
        category = container.value(.category, or: fallback.category)
    }
}

// MARK: - The look

/// Light, dark, or whatever the Mac is.
enum Theme: String, Codable, CaseIterable {
    case system, light, dark

    /// What `NSApp.appearance` is set to. Nil follows the system.
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

struct LookChoices: Codable, Equatable {
    var theme = Theme.system
    var density = Density.comfortable
    /// ⌘+, ⌘- and ⌘0, as the app was left.
    var zoom = Zoom.actual

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = LookChoices()
        theme = container.value(.theme, or: fallback.theme)
        density = container.value(.density, or: fallback.density)
        zoom = container.value(.zoom, or: fallback.zoom)
    }
}

// MARK: - The engine

struct EngineChoices: Codable, Equatable {
    /// Where `bw` is, when it is not where `BwBinary` looks. Empty is
    /// Homebrew's and then `PATH`.
    var bwPath = ""

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bwPath = container.value(.bwPath, or: EngineChoices().bwPath)
    }
}

// MARK: - The door for the browser

/// The origins the card has been answered about (`BrowserDoor`). An origin
/// in neither list has not been seen.
struct BrowserChoices: Codable, Equatable {
    var allowed: [String] = []
    var denied: [String] = []
    /// Whether Orion is told where the host is (`BrowserHosts`).
    var inOrion = false
    /// The hosts a toast was told never to ask on (`SaveDoor`): a host and
    /// nothing else.
    var neverSave: [String] = []

    func answer(for origin: String) -> Bool? {
        if denied.contains(origin) { return false }
        return allowed.contains(origin) ? true : nil
    }

    mutating func answer(_ origin: String, allowed isAllowed: Bool) {
        allowed.removeAll { $0 == origin }
        denied.removeAll { $0 == origin }
        if isAllowed { allowed.append(origin) } else { denied.append(origin) }
    }

    /// As if it had never been seen, so the card asks again the next time
    /// it comes. Nothing but the card puts an origin in.
    mutating func forget(_ origin: String) {
        allowed.removeAll { $0 == origin }
        denied.removeAll { $0 == origin }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowed = container.value(.allowed, or: [])
        denied = container.value(.denied, or: [])
        inOrion = container.value(.inOrion, or: false)
        neverSave = container.value(.neverSave, or: [])
    }
}

// MARK: - The SSH agent

/// How long a yes to one key for one app lasts.
enum SSHApproval: String, Codable, CaseIterable {
    case eachUse, tenMinutes, untilLock

    /// Nil is not held at all.
    var window: TimeInterval? {
        switch self {
        case .eachUse: return nil
        case .tenMinutes: return 10 * 60
        case .untilLock: return .infinity
        }
    }
}

/// `SSHAgent`, which is off until switched on, since it is a second thing
/// a locked app listens for.
/// The phone that may answer what a pass leaves to the card (OP-88): what it
/// calls itself and its public key, which is nothing secret.
struct SSHPhone: Codable, Equatable {
    let name: String
    let publicKey: Data
}

struct SSHChoices: Codable, Equatable {
    var isOn = false
    var approval = SSHApproval.tenMinutes
    var phone: SSHPhone?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = SSHChoices()
        isOn = container.value(.isOn, or: fallback.isOn)
        approval = container.value(.approval, or: fallback.approval)
        phone = container.value(.phone, or: fallback.phone)
    }
}

private extension KeyedDecodingContainer {
    /// The field, or its default when it is missing or will not read. One
    /// bad field costs that field.
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}
