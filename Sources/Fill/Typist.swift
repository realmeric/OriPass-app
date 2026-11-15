import Foundation

/// One key going down and coming up again in another app.
enum Key: Equatable, Redacted {
    /// One character, which the event carries as its own text, so the
    /// keyboard's layout has no say in it.
    case text(String)
    case tab, enter

    /// Which kind, and never which character: it may be a password's.
    var redactedLabel: String {
        switch self {
        case .text: return "Key.text"
        case .tab: return "Key.tab"
        case .enter: return "Key.enter"
        }
    }
}

/// Where a key goes. The app's is `EventKeys`, which posts it to a process;
/// a test's and the tour's is `FakeSink`, which posts nothing.
@MainActor
protocol KeySink: AnyObject {
    func post(_ key: Key, to pid: pid_t)
}

/// What the typist has to know of the screen before a key goes anywhere.
/// The app's is `SystemForeground`.
@MainActor
protocol Foreground: AnyObject {
    /// The app in front now.
    var frontPID: pid_t? { get }
    /// Whether ⌘, ⇧, ⌥ or ⌃ is still held on the keyboard. The key that
    /// asked for the fill had one of them, and a letter typed under ⌘ is a
    /// menu's.
    var holdsModifier: Bool { get }
    /// Where the caret in that app is.
    func caret(in app: FrontApp) -> Caret
}

/// What the system says of the field the caret is in.
enum Caret: Equatable {
    /// A password's field, or a terminal that has taken secure input.
    case secure
    /// Something else that has the keys and says what it is.
    case plain
    /// The app did not say: it has no accessibility tree, or the keys are
    /// in a web view that exposes nothing.
    case unknown
}

/// Whether macOS lets this app type into another, and the two ways of
/// getting it to. The app's is `SystemAccessibility`.
@MainActor
protocol Accessibility: AnyObject {
    var isTrusted: Bool { get }
    /// The system's own question, which it puts once.
    func ask()
    /// The list in System Settings the switch is in.
    func openSettings()
}

/// What is typed of a login.
struct Filling: Redacted {
    let username: String?
    let password: String

    var redactedLabel: String { "Filling" }

    /// The username when it can be typed ahead of the password, and nil
    /// when the login has none, or one that is only spaces, or one with a
    /// Tab or a line's end in it, which may move the caret before this
    /// app's own Tab does.
    var leadingUsername: String? {
        guard let username, !username.allSatisfy(\.isWhitespace),
              !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !username.contains(where: \.isNewline) else { return nil }
        return username
    }
}

/// Types a login into another app (D17): the username, a Tab and the
/// password, a character to an event, into the app that was in front when
/// Quick Access came up and into no other. With the caret already in a
/// password's field it types the password alone. Nothing goes near the
/// pasteboard.
///
/// A password is typed in two places and no others: a field the system
/// says is secure, and whatever this app's own username and Tab led to. So
/// a login with no username to type first is filled only with the caret in
/// a password's field. Anywhere else nothing is typed, and that includes an
/// app that does not say where its caret is (`Caret.unknown`): the password
/// would otherwise stand in the clear in a username's field, as it was seen
/// to do in Orion. With a username to type, an app that does
/// not say is typed into as a plain field is, since a web view that exposes
/// nothing is where most logins are filled and the Tab is what finds the
/// password's field there.
///
/// It waits, for two seconds at the most, until that app is in front again
/// and the keys that asked for the fill have been let go. Before each key it
/// looks again at what is in front, and stops when it is something else.
@MainActor
final class Typist {
    enum Outcome: Equatable {
        /// How many keys went.
        case typed(Int)
        /// Accessibility is not switched on for this app.
        case notAllowed
        /// Another app was in front, or came in front part of the way
        /// through. The number is how many keys had gone by then.
        case notInFront(Int)
        /// ⌘, ⇧, ⌥ or ⌃ was held for the whole of the wait.
        case keysHeld
        /// The vault locked.
        case stopped(Int)
        /// The login has no username to type first and the caret is not
        /// known to be in a password's field. Nothing went.
        case needsPasswordField
        /// The login has no password. Nothing went, the username included:
        /// a form left with its password empty looks filled, and the Return
        /// that may follow would send it.
        case noPassword

        /// What the log is told. Never the number: it is the username's
        /// length and the password's, or the password's alone.
        var kind: String {
            switch self {
            case .typed: return "typed"
            case .notAllowed: return "not allowed"
            case .notInFront: return "not in front"
            case .keysHeld: return "keys held"
            case .stopped: return "stopped"
            case .needsPasswordField: return "needs a password field"
            case .noPassword: return "no password"
            }
        }
    }

    /// How long the app is waited for, and how often it is looked at.
    static let patience: TimeInterval = 2
    static let look: TimeInterval = 0.01
    /// Between two keys, and after a Tab, which a web page may answer by
    /// moving the caret itself.
    static let pace: TimeInterval = 0.008
    static let afterTab: TimeInterval = 0.08

    let access: Accessibility
    private let ground: Foreground
    private let sink: KeySink
    private let pause: (TimeInterval) async -> Void
    /// The fill under way or the last one finished, for a test to wait on.
    private(set) var typing: Task<Outcome, Never>?
    private var ticking: Instruments.Registration?

    /// A test gives a `pause` that does not sleep.
    init(access: Accessibility, ground: Foreground, sink: KeySink,
         pause: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.access = access
        self.ground = ground
        self.sink = sink
        self.pause = pause
    }

    /// What goes, in order. Nil when nothing may: the password would land
    /// in a field that is not known to be a password's.
    static func keys(for login: Filling, caret: Caret, pressingReturn: Bool) -> [Key]? {
        var keys: [Key] = []
        if caret != .secure {
            guard let username = login.leadingUsername else { return nil }
            keys += username.map { .text(String($0)) }
            keys.append(.tab)
        }
        keys += login.password.map { .text(String($0)) }
        if pressingReturn { keys.append(.enter) }
        return keys
    }

    /// A fill that is asked for while another is going takes its place.
    /// `then` is told how it ended before the task is over, so whoever
    /// waits on the task finds what it did about that already done.
    @discardableResult
    func type(_ login: Filling, into app: FrontApp, pressingReturn: Bool,
              then: (@MainActor (Outcome) -> Void)? = nil) -> Task<Outcome, Never> {
        stop()
        ticking = Instruments.register("typing", kind: .timer, owner: "Fill")
        // Held by its own work until that is over: whoever asked may have
        // let go of it by then.
        let task = Task { () -> Outcome in
            let outcome = await self.run(login, into: app, pressingReturn: pressingReturn)
            if !Task.isCancelled { self.ticking = nil }
            Log.app.info("fill: \(outcome.kind, privacy: .public)")
            then?(outcome)
            return outcome
        }
        typing = task
        return task
    }

    /// The lock's: whatever has not been typed yet is not typed.
    func stop() {
        typing?.cancel()
        ticking = nil
    }

    private func run(_ login: Filling, into app: FrontApp, pressingReturn: Bool) async -> Outcome {
        guard access.isTrusted else { return .notAllowed }
        guard !login.password.isEmpty else { return .noPassword }
        var waited: TimeInterval = 0
        while ground.frontPID != app.pid || ground.holdsModifier {
            if Task.isCancelled { return .stopped(0) }
            guard waited < Self.patience else {
                return ground.frontPID == app.pid ? .keysHeld : .notInFront(0)
            }
            await pause(Self.look)
            waited += Self.look
        }
        guard let keys = Self.keys(for: login, caret: ground.caret(in: app), pressingReturn: pressingReturn) else {
            return .needsPasswordField
        }
        var gone = 0
        for key in keys {
            if Task.isCancelled { return .stopped(gone) }
            guard ground.frontPID == app.pid else { return .notInFront(gone) }
            sink.post(key, to: app.pid)
            gone += 1
            await pause(key == .tab ? Self.afterTab : Self.pace)
        }
        return .typed(gone)
    }
}

/// What the panel says when it did not type a login it was asked to type.
struct FillNotice: Equatable {
    let title: String
    let sentence: String
    /// Nil when there is nothing to go and switch on.
    let button: String?

    /// The one sentence that says what Accessibility is for here.
    static func copiedInstead(of app: String) -> FillNotice {
        FillNotice(title: "Password copied, not typed",
                   sentence: "\(AppInfo.name) can type a login into \(app.isEmpty ? "another app" : app) "
                       + "only after macOS has Accessibility switched on for it.",
                   button: "Allow Typing…")
    }

    /// A login with no username, and a caret that is not known to be in a
    /// password's field. Nothing was typed and nothing was copied. A
    /// username that cannot be typed for the Tab in it is told the same.
    static func needsPasswordField(in app: String) -> FillNotice {
        FillNotice(title: "Nothing typed",
                   sentence: "This login has no username, so the caret has to be in a password field"
                       + "\(app.isEmpty ? "" : " in \(app)").",
                   button: nil)
    }
}
