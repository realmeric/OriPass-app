import Foundation

/// A sink that posts nothing and keeps what it was sent, for a test and for
/// the canary's tour, which forgets it again before the lock.
@MainActor
final class FakeSink: KeySink, Redacted {
    private(set) var keys: [Key] = []
    private(set) var pids: Set<pid_t> = []
    /// Run after each key, so a test can change what is in front part of
    /// the way through.
    var afterKey: ((Int) -> Void)?

    nonisolated var redactedLabel: String { "FakeSink" }

    /// The characters alone, with Tab and Return as themselves.
    var typed: String {
        keys.map { key in
            switch key {
            case .text(let character): return character
            case .tab: return "\t"
            case .enter: return "\r"
            }
        }.joined()
    }

    func post(_ key: Key, to pid: pid_t) {
        keys.append(key)
        pids.insert(pid)
        afterKey?(keys.count)
    }

    func forget() {
        keys = []
        pids = []
    }
}

/// A screen that is as it is told to be.
@MainActor
final class FakeForeground: Foreground {
    var frontPID: pid_t?
    var holdsModifier = false
    var caret = Caret.plain

    init(frontPID: pid_t? = nil) {
        self.frontPID = frontPID
    }

    func caret(in app: FrontApp) -> Caret { caret }
}

/// A grant that is as it is told to be, and counts what it was asked.
@MainActor
final class FakeAccessibility: Accessibility {
    var isTrusted: Bool
    private(set) var asked = 0
    private(set) var opened = 0

    init(isTrusted: Bool = true) {
        self.isTrusted = isTrusted
    }

    func ask() { asked += 1 }
    func openSettings() { opened += 1 }
}

/// A default browser that is as it is told to be, and keeps the addresses
/// it was handed instead of opening them.
@MainActor
final class FakeSites: SiteOpener {
    var browser: String?
    private(set) var opened: [URL] = []

    init(browser: String? = "com.kagi.kagimacOS") {
        self.browser = browser
    }

    func open(_ url: URL) -> String? {
        guard let browser else { return nil }
        opened.append(url)
        return browser
    }

    func forget() {
        opened = []
    }
}
