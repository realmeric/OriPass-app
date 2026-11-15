import Combine
import LocalAuthentication
import SwiftUI

/// Decides which of the two the window holds: the lock screen, or what is
/// behind it. `panes` exists only while the store is unlocked, and the view
/// below builds the panes from it, so a locked window has neither the views
/// nor their model anywhere in it.
///
/// It is where an account is signed in, too: the sheet's model is made when
/// the sheet is raised and dropped when it goes, and a master password that
/// signed in goes straight on to open the vault, so it is typed once.
///
/// It is also where the finger is: a password the engine took is sealed
/// here, and a finger on the lock screen unseals it and opens the store
/// with it (D7). Without a `PasswordSeal` there is no finger at all, which
/// is how every test that is not about one makes its door.
@MainActor
final class Door: ObservableObject {
    let store: VaultStore
    /// One for the app and not one for each unlock: what it left on the
    /// pasteboard is taken off at the lock, after the panes have gone.
    let clipboard: Clipboard
    @Published private(set) var panes: Panes?
    /// The password is sealed and a finger may open it. The lock screen
    /// draws its fingerprint only then.
    @Published private(set) var hasSeal = false
    /// The question that follows the first unlock by password.
    @Published private(set) var isOfferingFinger = false
    /// Why something that asked the agent for a key was told nothing, for
    /// the lock screen to say: a shut vault, and no finger to open it.
    @Published private(set) var agentRefusal: String?
    /// What was signed through a pass, said by the first unlock after it.
    @Published private(set) var passReport: String?
    /// The sign-in sheet, while it is up.
    @Published private(set) var signIn: SignIn?
    /// ⌘+, ⌘- and ⌘0. The lock screen is drawn at it too, so it is the
    /// door's and not the panes'.
    @Published private(set) var zoom = Zoom.actual
    @Published private(set) var density = Density.comfortable

    private let seal: PasswordSeal?
    private let signInEngine: SignInEngine?
    /// Every choice, the answer about the finger and the size among them
    /// (`LockChoices.unlockWithFinger`, which outlives the seal, so after
    /// "Lock and forget" or fourteen days the next password seals again
    /// without asking). The app's delegate hands over the app's; a door made
    /// with defaults and no more keeps its own in them, and one made with
    /// neither reads nothing and keeps nothing, which is every door a test
    /// makes without saying.
    let preferences: Preferences
    private let defaults: UserDefaults?
    private let isInFront: () -> Bool
    private let makeIcons: () -> IconStore
    private let stage: LargeTypeStage?
    /// One for the app, as the pasteboard is: the copy of an attachment a
    /// preview is reading goes at the lock, after the panes have gone.
    let desk: AttachmentDesk?
    /// What asks again for the items that ask (`Reprompt`). One for the
    /// app, so Quick Access and every window ask once between them, and
    /// none in a test that is not about it.
    let reprompt: Reprompt?
    /// What Open & Fill arms (`ArmedFill`). One for the app, so the window
    /// and Quick Access arm the same thing and the lock clears it. None in
    /// a test that is not about it, and then nothing offers to open and fill.
    let armedFill: ArmedFill?
    /// Every pass (`AgentPass`). One for the app: a lock leaves them, and
    /// Lock and Forget, Sign Out and a change of the fingers do not.
    let passes: AgentPasses
    /// What puts a window of one item on the screen (`ItemWindows`), and
    /// nothing in a test.
    private let present: ((NSWindow) -> Void)?
    /// What else on this Mac is the account's and is neither the engine's
    /// nor the seal's: the site icons under Caches, which say where he has
    /// logins. Removed at Sign Out.
    private let accountFiles: [URL]
    /// What raises the settings window, which is the app's and not a
    /// window's. Nil in a test and a shot, where its two menu rows are grey.
    var showSettings: (() -> Void)?
    /// The password that opened the vault, held while the question is on
    /// screen and no longer.
    private var offered: SecretBytes?
    /// For a test, which holds it to being wiped.
    var heldForTheQuestion: SecretBytes? { offered }
    /// A lock screen has come up and its sheet has not been raised yet.
    private var owesFinger = false
    private var isAsking = false
    /// The finger being asked for, for whoever arrives while it is.
    private var fingering: Task<Void, Never>?
    private var watching: Set<AnyCancellable> = []

    init(store: VaultStore, seal: PasswordSeal? = nil, signIn: SignInEngine? = nil,
         defaults: UserDefaults? = nil, preferences: Preferences? = nil, icons: (() -> IconStore)? = nil,
         clipboard: Clipboard? = nil, stage: LargeTypeStage? = nil,
         present: ((NSWindow) -> Void)? = nil, desk: AttachmentDesk? = nil,
         reprompt: Reprompt? = nil, armedFill: ArmedFill? = nil, passes: AgentPasses? = nil, accountFiles: [URL] = [],
         isInFront: @escaping () -> Bool = { NSApp.isActive }) {
        self.store = store
        self.seal = seal
        signInEngine = signIn
        self.defaults = defaults
        let preferences = preferences ?? Preferences(defaults: defaults)
        self.preferences = preferences
        self.isInFront = isInFront
        makeIcons = icons ?? { .off }
        let clipboard = clipboard ?? Clipboard(pasteboard: nil)
        self.clipboard = clipboard
        self.stage = stage
        self.present = present
        self.desk = desk
        self.reprompt = reprompt
        self.armedFill = armedFill
        let passes = passes ?? AgentPasses()
        passes.fingers = { seal?.fingerprints }
        self.passes = passes
        self.accountFiles = accountFiles
        hasSeal = seal?.standing == .ready
        store.$state.sink { [weak self] state in
            guard let self else { return }
            if state != .unlocked {
                // Before the panes go: a request for an icon would outlive
                // them otherwise, and write a host under Caches when it came
                // back. Large Type would stay up over the lock screen, and
                // so would a window of one item, and a preview of an
                // attachment with the copy it is reading.
                self.panes?.end()
                self.panes = nil
                clipboard.clear()
                desk?.end()
                // A key pressed after a lock fills nothing for a page opened
                // before it.
                armedFill?.clear()
                self.withdrawOffer()
                self.passReport = nil
                // A vault with no account has nobody to hold a pass for.
                if state == .loggedOut {
                    passes.endAll()
                    passes.forgetReport()
                    preferences.settings.ssh.phone = nil
                }
            } else if self.panes == nil {
                self.agentRefusal = nil
                self.passReport = passes.takeReport()
                let panes = Panes(store: store, defaults: defaults, preferences: preferences, icons: makeIcons(), clipboard: clipboard,
                                  stage: stage, present: present, desk: desk, reprompt: reprompt,
                                  armedFill: armedFill)
                if self.showSettings != nil {
                    panes.showSettings = { [weak self] in self?.showSettings?() }
                }
                self.panes = panes
            }
        }.store(in: &watching)
        NotificationCenter.default.publisher(for: VaultStore.didLock, object: store).sink { [weak self] _ in
            self?.lockScreenAppeared()
        }.store(in: &watching)
    }

    /// The interval called "unlock" runs from Return to the store holding its
    /// lists, which is as far as there is a list to wait for until the panes
    /// draw one (OP-21). The task is handed back so a test can wait for it.
    ///
    /// The store wipes the password it is handed, so one that may be
    /// sealed is copied first, and the copy is wiped here if the engine
    /// did not take it.
    @discardableResult
    func unlock(with password: SecretBytes) -> Task<Void, Never> {
        let interval = Log.signposter.beginInterval("unlock")
        let mayBeSealed = seal?.canSeal == true && preferences.settings.lock.unlockWithFinger != false
        let typed = mayBeSealed ? password.copy() : nil
        return Task {
            let opened = await store.unlock(password: password)
            Log.signposter.endInterval("unlock", interval, "\(opened ? "opened" : "refused", privacy: .public)")
            guard let typed else { return }
            if opened { keep(typed) } else { typed.wipe() }
        }
    }

    func tryAgain() {
        Task { await store.refresh() }
    }

    func dismissPassReport() {
        passReport = nil
    }

    // MARK: Zoom

    /// The size the app was left at. Only the app asks, at launch: a door
    /// made for a test or a shot stays at the actual size.
    func restoreZoom() {
        zoom(to: preferences.settings.look.zoom, remembering: false)
    }

    /// False at the end of the three steps, where the menu's item is grey.
    @discardableResult
    func zoom(to size: Zoom?, remembering: Bool = true) -> Bool {
        guard let size else { return false }
        Metrics.zoom = size.factor
        if remembering { preferences.settings.look.zoom = size }
        guard size != zoom else { return true }
        zoom = size
        NotificationCenter.default.post(name: Zoom.didChange, object: nil)
        return true
    }

    // MARK: Density

    /// What the Appearance room chose, as `Following` hears of it: at the
    /// launch, and when the choice moves.
    func density(to density: Density) {
        Metrics.density = density
        guard density != self.density else { return }
        self.density = density
        NotificationCenter.default.post(name: Density.didChange, object: nil)
    }

    // MARK: Signing in

    /// Raises the sheet. Only a logged-out lock screen has the button.
    func beginSignIn() {
        guard signIn == nil, store.state == .loggedOut, let signInEngine else { return }
        signIn = SignIn(engine: signInEngine) { [weak self] password in
            guard let self else {
                password?.wipe()
                return
            }
            self.signedIn(with: password)
        }
    }

    func cancelSignIn() {
        signIn?.close()
        signIn = nil
    }

    /// An account is here. The store is asked whose, and the password that
    /// signed in, if there was one, opens the vault as if it had been typed
    /// into the lock screen. An API key leaves the lock screen asking.
    @discardableResult
    private func signedIn(with password: SecretBytes?) -> Task<Void, Never> {
        signIn = nil
        return Task {
            await store.refresh()
            guard let password else { return }
            guard store.state == .locked else {
                password.wipe()
                return
            }
            await unlock(with: password).value
        }
    }

    // MARK: The finger

    /// What becomes of the password that just opened the vault: sealed,
    /// wiped, or held for as long as the question takes.
    private func keep(_ password: SecretBytes) {
        guard let seal, seal.canSeal, store.state == .unlocked else {
            password.wipe()
            return
        }
        switch preferences.settings.lock.unlockWithFinger {
        case true?:
            write(password, to: seal)
            password.wipe()
        case false?:
            password.wipe()
        case nil:
            offered = password
            isOfferingFinger = true
        }
    }

    private func write(_ password: SecretBytes, to seal: PasswordSeal) {
        do {
            try seal.seal(password)
        } catch {
            Log.app.error("the password was not sealed: \((error as NSError).code)")
        }
        hasSeal = seal.standing == .ready
    }

    func answerFingerOffer(_ wanted: Bool) {
        guard isOfferingFinger else { return }
        preferences.settings.lock.unlockWithFinger = wanted
        if wanted, let offered, let seal { write(offered, to: seal) }
        withdrawOffer()
    }

    /// Unanswered, so it is asked again after the next password.
    private func withdrawOffer() {
        offered?.wipe()
        offered = nil
        isOfferingFinger = false
    }

    /// A lock screen has just come up: at launch, and after every lock. The
    /// sheet is raised at once if the app is in front, and when it next is if
    /// not, so the Mac does not ask for a finger behind another app's window.
    /// A seal past its fourteen days, or under fingerprints that have
    /// changed, is deleted here, whoever is looking.
    func lockScreenAppeared() {
        owesFinger = true
        passes.sweep()
        endIfExpired()
        raiseFingerIfOwed()
    }

    func raiseFingerIfOwed() {
        guard owesFinger, hasSeal, store.state == .locked, isInFront() else { return }
        askForFinger()
    }

    /// The fingerprint in the field, and the sheet that raises itself. A
    /// finger unseals the password and the store is opened with it as if it
    /// had been typed, and it is wiped there. Anything else leaves the
    /// password field as it was. A password the engine no longer takes was
    /// changed somewhere else: its seal is deleted, the lock screen says
    /// so, and the next unlock is the new one, typed. The same when the
    /// account is gone. An unlock that failed any other way, a `bw` that
    /// would not start among them, says nothing of the password, and the
    /// seal is kept for the next finger.
    ///
    /// The interval called "finger" runs from the enclave handing the
    /// password back to the store holding its lists, so the time he took to
    /// reach the sensor is not in it.
    ///
    /// `context` is one a card is drawing the finger for, and with none it
    /// is the sheet.
    @discardableResult
    func askForFinger(reason: String = PasswordSeal.reason, on context: LAContext? = nil) -> Task<Void, Never> {
        owesFinger = false
        let task = Task {
            guard let seal, !isAsking, store.state == .locked else { return }
            isAsking = true
            defer { isAsking = false }
            endIfExpired()
            guard hasSeal else { return }

            let password: SecretBytes
            do {
                password = try await Task.detached { try seal.unseal(reason: reason, on: context) }.value
            } catch {
                Log.app.info("the finger did not open the seal: \((error as NSError).code)")
                return
            }
            // He typed the password while the sheet was up.
            guard store.state == .locked else { return password.wipe() }

            let interval = Log.signposter.beginInterval("finger")
            let opened = await store.unlock(password: password, kept: true)
            Log.signposter.endInterval("finger", interval, "\(opened ? "opened" : "refused", privacy: .public)")
            if !opened, store.refusal == VaultStore.keptPasswordRefused || store.state == .loggedOut {
                seal.forget()
                hasSeal = false
            }
        }
        if !isAsking { fingering = task }
        return task
    }

    /// The vault opened for a request that arrived over a shut one, and
    /// whether it is. A finger through the seal is the only way a request
    /// can open it. With no seal, or with the lid shut over the sensor, it
    /// stays shut and the lock screen says why; the request itself is told
    /// nothing. A finger already being asked for, or a password already
    /// being tried, is waited for.
    func openForAgent(on context: LAContext? = nil) async -> Bool {
        if isAsking { await fingering?.value }
        if store.state == .locked {
            endIfExpired()
            if hasSeal, canUseFinger {
                await askForFinger(reason: Self.agentReason, on: context).value
            } else {
                agentRefusal = Self.agentWaited
            }
        }
        for await state in store.$state.values where state != .unlocking {
            return state == .unlocked
        }
        return false
    }

    static let agentReason = "open the vault for an app that wants an SSH key"
    static let agentWaited = "Something asked for an SSH key while the vault was shut. Open it here and ask again."

    /// A seal past its days, or one from before a fingerprint was added or
    /// taken away, is deleted. Only a lock screen asks, so there is no
    /// engine to tell: the session it made went with it at the lock.
    private func endIfExpired() {
        guard let seal else { return }
        let standing = seal.standing
        if standing == .expired || standing == .orphaned { seal.forget() }
        hasSeal = seal.standing == .ready
    }

    /// Whether this Mac has a finger to offer at all: false with no seal to
    /// write to, with none enrolled, and with the lid shut over the sensor.
    var canUseFinger: Bool { seal?.canSeal == true }

    /// The switch in the Security room. Off is "Lock and forget" as well,
    /// since a password left sealed would still open to a finger. On seals
    /// nothing now: the app holds no password to seal, and the next one
    /// typed is the one.
    func setFinger(_ wanted: Bool) async {
        preferences.settings.lock.unlockWithFinger = wanted
        if !wanted { await lockAndForget() }
    }

    /// Sign Out: the seal goes, the engine forgets the account and empties
    /// its folder, and what else was the account's is removed.
    func signOut() async {
        passes.endAll()
        passes.forgetReport()
        seal?.forget()
        hasSeal = false
        await store.signOut()
        for file in accountFiles { try? FileManager.default.removeItem(at: file) }
    }

    /// The app is quitting. What it copied and what a preview is reading go
    /// first and whatever the switch says: the ninety seconds are a task of
    /// this process, and a lock that the switch has turned off would
    /// otherwise have been the only other thing to take them. The switch
    /// then decides what it always did, whether the engine is told to go.
    /// A change the engine is still making is waited for first, since the
    /// engine does not outlive the app whatever the switch says.
    func quit(under policy: LockPolicy?) async {
        clipboard.clear()
        desk?.end()
        await store.settle()
        await policy?.willQuit()
    }

    /// "Lock and forget", and what turning Touch ID off does: the two
    /// files go, and the engine drops its session before it is shut, so
    /// nothing on this Mac opens the vault but the password, typed.
    func lockAndForget() async {
        passes.endAll()
        seal?.forget()
        hasSeal = false
        await store.lock(forget: true)
    }
}

struct DoorView: View {
    @ObservedObject var door: Door
    @ObservedObject private var store: VaultStore
    @ObservedObject private var passes: AgentPasses

    init(door: Door) {
        self.door = door
        store = door.store
        passes = door.passes
    }

    var body: some View {
        ZStack {
            if let panes = door.panes {
                PanesView(panes: panes)
                    .transition(Motion.transition(.none))
                if door.isOfferingFinger {
                    FingerOffer(answer: door.answerFingerOffer)
                        .transition(Motion.transition(.fade))
                }
                if let report = door.passReport {
                    PassReportLine(sentence: report, dismiss: door.dismissPassReport)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .transition(Motion.transition(.fade))
                }
            } else {
                LockScreen(state: store.state, email: store.email, refusal: store.refusal ?? door.agentRefusal,
                           hasSeal: door.hasSeal, unlock: { door.unlock(with: $0) },
                           askForFinger: { door.askForFinger() }, tryAgain: door.tryAgain,
                           signIn: door.beginSignIn, isSigningIn: door.signIn != nil,
                           passes: passes.standing.count)
                    .transition(Motion.transition(.fadeOut))
                if let signIn = door.signIn {
                    SignInSheet(model: signIn, cancel: door.cancelSignIn)
                        .transition(Motion.transition(.fade))
                }
            }
        }
        // `Metrics` and `Fonts` are read as a view is made, so another size
        // or another density is every view made again. What they showed is the door's and the
        // panes', and is still there.
        .id(door.zoom)
        .id(door.density)
        // Opening fades the lock screen off the panes. Locking does not fade:
        // the panes are gone in the same frame.
        .animation(door.panes == nil ? nil : Motion.animation(Motion.door), value: door.panes == nil)
        .animation(door.panes == nil ? nil : Motion.animation(Motion.slide), value: door.isOfferingFinger)
        .animation(Motion.animation(Motion.slide), value: door.signIn == nil)
        .animation(Motion.animation(Motion.slide), value: door.passReport == nil)
    }
}
