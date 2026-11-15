import AppKit
import Combine

/// The settings window's model: the room that is shown, and the things a
/// room says or does that are not a field of `Settings`. A switch that is a
/// field is bound to `Preferences` by the view and never comes through here.
///
/// One for the app, made by the delegate and kept, since the window is only
/// ever put away. Nothing in it is the vault's: the email and the server are
/// what the lock screen says too, so a lock leaves it as it is.
@MainActor
final class Rooms: ObservableObject {
    /// What it asks of the system and of the app. The delegate hands over
    /// the real ones; a test's, a shot's, the demo's and the tour's ask
    /// nobody.
    @MainActor
    struct Hands {
        var loginItem: LoginItem = FakeLoginItem()
        var access: Accessibility = FakeAccessibility(isTrusted: false)
        var automation: Automation = FakeAutomation()
        /// What the hot keys last could not take (`HotKeys.refused`).
        var refusedKeys: () -> [HotKeyAction: HotKeyRefusal] = { [:] }
        /// `bw`, with what it says its version is. A second and more: it is
        /// node starting.
        var engine: () async -> BwBinary? = { nil }
        var open: (URL) -> Void = { _ in }
        /// Why the agent's switch is on and nothing listens.
        var agentProblem: () -> String? = { nil }
        /// Whether Orion has a folder for `BrowserHosts` to write under.
        var hasOrion: () -> Bool = { true }
        /// What New Pass may name, and the finger that gives one
        /// (`SSHAgent.give`).
        var passKeys: () -> [AgentKey] = { [] }
        var passApps: () async -> [PassApp] = { [] }
        var hasFinger: () -> Bool = { false }
        var givePass: (PassApp, PassSpan) async -> Bool = { _, _ in false }
        /// Add Phone (`PhoneDoor`), true once one is registered.
        var waitForPhone: () async -> Bool = { false }
        var stopWaitingForPhone: () -> Void = {}
    }

    /// New Pass, while it is open: what can be chosen and what has been. It
    /// holds public keys and names.
    struct NewPass: Equatable {
        static let refused = "The pass was not given."

        let keys: [AgentKey]
        let apps: [PassApp]
        var app: PassApp?
        var span = PassSpan.oneHour
        var problem: String?
        var isAsking = false

        init(keys: [AgentKey], apps: [PassApp]) {
            self.keys = keys
            self.apps = apps
            app = apps.first
        }

        var isReady: Bool { !keys.isEmpty && app != nil && !isAsking }
    }

    static let webVault = "https://vault.bitwarden.com"
    static let publicSuffix = "https://publicsuffix.org"
    static let listLicence = "https://www.mozilla.org/MPL/2.0/"

    let door: Door
    let preferences: Preferences
    private let hands: Hands

    @Published var room = Room.general
    @Published private(set) var startsAtLogin = false
    /// The system would not add the app to its login items, or take it out.
    @Published private(set) var loginProblem: String?
    /// Why the combination last recorded for an action was not taken.
    @Published private(set) var keyProblems: [HotKeyAction: String] = [:]
    @Published private(set) var isTrusted = false
    @Published private(set) var grants: [Browser: AutomationGrant] = [:]
    @Published private(set) var hasOrion = true
    @Published private(set) var engine: BwBinary?
    /// The engine has been looked for, so "not found" may be said.
    @Published private(set) var hasLooked = false
    /// The question between Sign Out and the account being gone.
    @Published private(set) var isAskingToSignOut = false
    /// The agent's switch was turned on and no socket came of it.
    @Published private(set) var agentProblem: String?
    @Published private(set) var isSigningOut = false
    /// The form under Passes, while it is open. It holds keys' names and
    /// public halves, which go at the lock like the rest of the list.
    @Published var newPass: NewPass?
    @Published var isWaitingForPhone = false

    /// The last look at the engine and at the browsers, for a test to wait
    /// on.
    private(set) var looking: Task<Void, Never>?
    private var lookedAt: String?
    private var watching: Set<AnyCancellable> = []

    init(door: Door, hands: Hands? = nil) {
        let hands = hands ?? Hands()
        self.door = door
        preferences = door.preferences
        self.hands = hands
        startsAtLogin = hands.loginItem.isOn
        isTrusted = hands.access.isTrusted
        hasOrion = hands.hasOrion()
        $room.dropFirst().removeDuplicates().sink { [weak self] room in
            // The room is not the new one until this has returned.
            DispatchQueue.main.async { self?.look() }
        }.store(in: &watching)
        door.store.$state.sink { [weak self] state in
            if state != .unlocked { self?.newPass = nil }
        }.store(in: &watching)
    }

    /// Asks again for what the system keeps and may have changed since: the
    /// login item, the two grants, and the engine when its room is up. The
    /// window does it as it comes to the front, which is the moment he is
    /// back from System Settings.
    @discardableResult
    func look() -> Task<Void, Never> {
        startsAtLogin = hands.loginItem.isOn
        isTrusted = hands.access.isTrusted
        hasOrion = hands.hasOrion()
        let room = self.room
        let path = preferences.settings.engine.bwPath
        let task = Task { [weak self, hands] in
            if room == .filling {
                var grants: [Browser: AutomationGrant] = [:]
                for browser in Browser.allCases { grants[browser] = await hands.automation.grant(for: browser) }
                self?.grants = grants
            }
            // Once for each path: the answer does not change while the app
            // runs, and asking is a whole `bw`.
            if room == .account, self?.lookedAt != path {
                let found = await hands.engine()
                self?.engine = found
                self?.lookedAt = path
                self?.hasLooked = true
            }
        }
        looking = task
        return task
    }

    /// What the last two would have brought, for a shot, which waits for
    /// nobody.
    func show(grants: [Browser: AutomationGrant], engine: BwBinary?) {
        self.grants = grants
        self.engine = engine
        hasLooked = true
    }

    // MARK: General

    func setStartsAtLogin(_ wanted: Bool) {
        do {
            try hands.loginItem.set(wanted)
            loginProblem = nil
        } catch {
            Log.app.error("the login item was not changed: \((error as NSError).code)")
            loginProblem = "macOS would not change it. Look under System Settings, General, Login Items."
        }
        startsAtLogin = hands.loginItem.isOn
    }

    func key(for action: HotKeyAction) -> HotKey? {
        preferences.settings.shortcuts.key(for: action)
    }

    /// A combination the recorder heard. One the rules refuse is said so
    /// and the key stays as it was. One they let through is written, which
    /// registers it (`Following`), and what Carbon then said is read back.
    func record(_ key: HotKey, for action: HotKeyAction) {
        var wanted = preferences.settings.shortcuts
        wanted.set(action, to: key)
        if let refusal = HotKeyRules.refusal(for: key, taken: wanted.all, by: action) {
            keyProblems[action] = refusal.words
            return
        }
        change(action) { $0 = wanted }
    }

    /// The key taken away, so the action has none.
    func clear(_ action: HotKeyAction) {
        change(action) { $0.set(action, to: nil) }
    }

    /// Back to the key the action came with.
    func reset(_ action: HotKeyAction) {
        change(action) { $0.forget(action) }
    }

    func isChanged(_ action: HotKeyAction) -> Bool {
        key(for: action) != action.fallback
    }

    private func change(_ action: HotKeyAction, _ edit: (inout ShortcutChoices) -> Void) {
        keyProblems[action] = nil
        edit(&preferences.settings.shortcuts)
        if let refusal = hands.refusedKeys()[action] { keyProblems[action] = refusal.words }
    }

    // MARK: Security

    var canUseFinger: Bool { door.canUseFinger }

    @discardableResult
    func setFinger(_ wanted: Bool) -> Task<Void, Never> {
        Task { [door] in await door.setFinger(wanted) }
    }

    // MARK: Filling

    func openAccessibility() {
        hands.access.openSettings()
    }

    func openAutomation() {
        hands.automation.openSettings()
    }

    // MARK: Developer

    func setAgent(_ wanted: Bool) {
        preferences.settings.ssh.isOn = wanted
        agentProblem = hands.agentProblem()
    }

    /// Why New Pass cannot be pressed now, and nil when it can.
    var passRefusal: String? {
        if door.store.state != .unlocked { return Self.passNeedsVault }
        return hands.hasFinger() ? nil : Self.passNeedsFinger
    }

    static let passNeedsVault = "A pass is read out of the vault, so open it first."
    static let passNeedsFinger = "A pass is given with a finger, and there is none to be had."

    /// The apps are read as it opens, each by its signature.
    @discardableResult
    func beginPass() -> Task<Void, Never> {
        Task { [hands] in
            let keys = hands.passKeys()
            let apps = await hands.passApps()
            self.newPass = NewPass(keys: keys, apps: apps)
        }
    }

    func cancelPass() {
        newPass = nil
    }

    /// One finger, and the form goes. A no leaves it up, saying so.
    @discardableResult
    func givePass() -> Task<Void, Never> {
        Task { [hands] in
            guard let form = self.newPass, form.isReady, let app = form.app else { return }
            self.newPass?.isAsking = true
            self.newPass?.problem = nil
            let given = await hands.givePass(app, form.span)
            if given {
                self.newPass = nil
            } else {
                self.newPass?.isAsking = false
                self.newPass?.problem = NewPass.refused
            }
        }
    }

    func revoke(_ pass: AgentPass) {
        door.passes.end(pass)
    }

    /// The door stands open for five minutes at most, and the card that
    /// names the phone takes a finger.
    @discardableResult
    func addPhone() -> Task<Void, Never> {
        Task { [hands] in
            self.isWaitingForPhone = true
            _ = await hands.waitForPhone()
            self.isWaitingForPhone = false
        }
    }

    func cancelPhone() {
        hands.stopWaitingForPhone()
    }

    func forgetPhone() {
        preferences.settings.ssh.phone = nil
    }

    /// The app never writes `~/.ssh/config`, so this is as far as it goes.
    func copyAgentLine() {
        door.clipboard.copy(SSHAgent.configLine)
    }

    /// Allowed or denied, the origin is back to not having been seen, and
    /// the next `hello` from it raises the card.
    func forget(_ origin: String) {
        preferences.settings.browser.forget(origin)
    }

    /// The toast may ask on this host again.
    func askAgain(on host: String) {
        preferences.settings.browser.neverSave.removeAll { $0 == host }
    }

    // MARK: Account

    /// The web vault of the server the account is on, where everything this
    /// app leaves alone is done (D20).
    var webVault: URL? {
        URL(string: door.store.server ?? Self.webVault)
    }

    /// The server as a row names it.
    var server: String {
        door.store.server.flatMap { URL(string: $0)?.host } ?? door.store.server ?? "bitwarden.com"
    }

    func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        hands.open(url)
    }

    func openWebVault() {
        guard let webVault else { return }
        hands.open(webVault)
    }

    @discardableResult
    func lockAndForget() -> Task<Void, Never> {
        Task { [door] in await door.lockAndForget() }
    }

    var canSignOut: Bool {
        !isSigningOut && door.store.email != nil
    }

    func askToSignOut() {
        guard canSignOut else { return }
        isAskingToSignOut = true
    }

    func cancelSignOut() {
        isAskingToSignOut = false
    }

    /// Sign Out on the question. Nil when the question was not up.
    @discardableResult
    func confirmSignOut() -> Task<Void, Never>? {
        guard isAskingToSignOut, !isSigningOut else { return nil }
        isAskingToSignOut = false
        isSigningOut = true
        return Task { [weak self, door] in
            await door.signOut()
            self?.isSigningOut = false
        }
    }
}
