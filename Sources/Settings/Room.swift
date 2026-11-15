import Foundation

/// A room of the settings window (`docs/look.md`, "Settings"), in the order
/// its sidebar lists them.
///
/// `fields` is every field of `Settings` the room has a control for, by the
/// name `Settings` gives it, and each control is drawn under that name.
/// `SettingsRoomTests` holds both ways: a field with no room fails it, and
/// so does a room that names a field and draws nothing for it.
enum Room: String, CaseIterable, Identifiable {
    case general, appearance, security, privacy, filling, developer, account, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .security: return "Security"
        case .privacy: return "Privacy"
        case .filling: return "Filling"
        case .developer: return "Developer"
        case .account: return "Account"
        case .about: return "About"
        }
    }

    var glyph: Glyph {
        switch self {
        case .general: return .settings
        case .appearance: return .appearance
        case .security: return .lock
        case .privacy: return .privacy
        case .filling: return .keyboard
        case .developer: return .sshKey
        case .account: return .login
        case .about: return .info
        }
    }

    var fields: [String] {
        switch self {
        case .general:
            return ["menuBar.showsMark", "menuBar.keepsDock", "shortcuts.bound"]
        case .appearance:
            return ["look.theme", "look.density", "look.zoom"]
        case .security:
            return ["lock.unlockWithFinger", "lock.fingerDays", "lock.onSleep", "lock.onScreenLock",
                    "lock.onScreenSaver", "lock.onUserSwitch", "lock.onQuit", "lock.whenIdle", "lock.idleMinutes",
                    "clipboard.clearSeconds", "clipboard.staysOnThisMac", "details.revealWithOption"]
        case .privacy:
            return ["privacy.siteIcons", "privacy.breachCheck", "privacy.twoFactorCheck", "privacy.passkeysInSystemList"]
        case .filling:
            return ["fill.pressesReturn", "browser.inOrion"]
        case .developer:
            return ["ssh.isOn", "ssh.approval", "ssh.phone"]
        case .account:
            return ["engine.bwPath"]
        case .about:
            return []
        }
    }

    /// The three that are chosen where they are used, in the item list's
    /// own two menus, and would be a second place to set the same thing
    /// here.
    static let setInTheList = ["list.sort", "list.isReversed", "list.category"]

    /// The two the card over the browser writes and the one the toast does.
    /// The Filling room lists what is in them and takes an origin or a host
    /// out, and never puts one in.
    static let setOnTheCard = ["browser.allowed", "browser.denied", "browser.neverSave"]

    /// What each row of segments offers. A number written into the file by
    /// hand that is none of these is kept, and lights no segment.
    static let fingerDays = [1, 7, 14, 30]
    static let idleMinutes = [1, 5, 10, 15, 30, 60]
    static let clearSeconds: [Double] = [30, 60, 90, 120, 300]
}

extension SSHApproval {
    var word: String {
        switch self {
        case .eachUse: return "Each use"
        case .tenMinutes: return "10 minutes"
        case .untilLock: return "Until the lock"
        }
    }
}

extension Theme {
    var word: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

extension Density {
    var word: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .compact: return "Compact"
        }
    }
}

extension Zoom {
    var word: String {
        switch self {
        case .small: return "Small"
        case .actual: return "Actual"
        case .large: return "Large"
        }
    }
}

extension LockPolicy.Condition {
    /// The row it has under "Lock by itself", in the order they are drawn.
    static let rooms: [(condition: LockPolicy.Condition, field: String, words: String)] = [
        (.sleep, "lock.onSleep", "When the Mac sleeps"),
        (.screenLocked, "lock.onScreenLock", "When the screen locks"),
        (.screenSaver, "lock.onScreenSaver", "When the screen saver starts"),
        (.userSwitched, "lock.onUserSwitch", "When another user switches in"),
        (.quit, "lock.onQuit", "When \(AppInfo.name) quits"),
        (.idle, "lock.whenIdle", "When the Mac has been idle"),
    ]
}
