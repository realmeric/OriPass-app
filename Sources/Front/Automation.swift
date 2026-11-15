import AppKit

/// Whether macOS lets this app ask a browser for its tab, which is its
/// Automation list's to say, a browser at a time.
enum AutomationGrant: Equatable {
    case allowed, refused
    /// The system has not put its question yet: it does at the first tab
    /// asked for.
    case notAsked
    /// The system says nothing about an app that is not open.
    case notRunning
    case unknown

    var words: String {
        switch self {
        case .allowed: return "Allowed"
        case .refused: return "Not allowed"
        case .notAsked: return "Not asked yet"
        case .notRunning: return "Not open"
        case .unknown: return "Not known"
        }
    }
}

/// Who says how each browser stands. The app's is `SystemAutomation`; a
/// test's, a shot's and the tour's say what they were told to.
protocol Automation {
    func grant(for browser: Browser) async -> AutomationGrant
    /// The list in System Settings the switches are in.
    func openSettings()
}

/// The system's own answer, asked for without its question being put: with
/// `askUserIfNeeded` false nothing is raised, and a browser never asked is
/// said to need consent.
struct SystemAutomation: Automation {
    static let settings = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"

    func grant(for browser: Browser) async -> AutomationGrant {
        await withCheckedContinuation { answered in
            DispatchQueue.global(qos: .userInitiated).async {
                let target = NSAppleEventDescriptor(bundleIdentifier: browser.bundleID)
                let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(kAECoreSuite),
                                                                   AEEventID(kAEGetData), false)
                switch Int(status) {
                case Int(noErr): answered.resume(returning: .allowed)
                case errAEEventNotPermitted: answered.resume(returning: .refused)
                case errAEEventWouldRequireUserConsent: answered.resume(returning: .notAsked)
                case procNotFound: answered.resume(returning: .notRunning)
                default: answered.resume(returning: .unknown)
                }
            }
        }
    }

    func openSettings() {
        guard let url = URL(string: Self.settings) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// One that answers from a table.
final class FakeAutomation: Automation {
    var grants: [Browser: AutomationGrant]
    private(set) var opened = 0

    init(_ grants: [Browser: AutomationGrant] = [:]) {
        self.grants = grants
    }

    func grant(for browser: Browser) async -> AutomationGrant { grants[browser] ?? .notRunning }
    func openSettings() { opened += 1 }
}
