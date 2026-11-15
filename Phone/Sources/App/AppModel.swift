import AuthenticationServices
import Foundation
import Observation

/// What the app is showing, and the one place the account comes and goes.
@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case signedOut
        case locked(Account)
        case open(Account)
    }

    private(set) var phase: Phase
    /// The open vault's user key, while it is open and only then.
    private(set) var userKey: VaultKey?
    private(set) var vault: Vault? {
        didSet {
            items = vault?.items().items ?? []
            let items = items
            watch = nil
            Task {
                let counted = await Task.detached(priority: .utility) { Watch.count(items) }.value
                if self.items.map(\.id) == items.map(\.id) { watch = counted }
            }
        }
    }
    /// Password Health's counts for the open vault, once they are worked out.
    private(set) var watch: Watch?
    /// Every item that opened, decrypted once per vault.
    private(set) var items: [Item] = []
    private(set) var syncing = false
    private(set) var syncFailure: Api.Failure?
    /// What the lock screen says under the field, when it says anything.
    private(set) var lockSentence: String?
    private(set) var unlocking = false
    /// The KDF is running, which is the one wait worth a spinner.
    private(set) var derivingKey = false
    /// Whether OriPass is switched on in iOS's AutoFill settings, as last read.
    private(set) var autoFillOn = true
    /// From a face accepted to the vault open, the last time.
    private(set) var faceToVault: Duration?
    private var api: Api?
    private let face: FaceKey
    /// Face ID is asked once each time the app comes to the front.
    private var faceAsked = false

    init(face: FaceKey = .app) {
        self.face = face
        #if DEBUG
        // A UI test starts from a phone that has never signed in.
        if ProcessInfo.processInfo.arguments.contains("-OPReset") {
            Account.forget()
            VaultFile.forget()
            Keychain.app.deleteAll()
        }
        #endif
        if let account = Account.stored(), let tokens = Tokens.stored() {
            api = Api(client: Client(server: account.server), tokens: tokens)
            phase = .locked(account)
        } else {
            phase = .signedOut
        }
    }

    var canUseFace: Bool { face.isKept && FaceKey.available }

    func signedIn(_ opened: SignIn.Opened) throws {
        try opened.account.store()
        try opened.tokens.store()
        api = Api(client: Client(server: opened.account.server), tokens: opened.tokens)
        keepForFace(opened.userKey)
        open(opened.account, userKey: opened.userKey)
    }

    // MARK: Locked and open

    /// Called as the app comes to the front: asks for a face if one can
    /// open the vault and none was asked for since it last went away.
    func readAutoFill() async {
        autoFillOn = await IdentityStore.isEnabled
    }

    /// iOS's own question, from the app, with no trip to Settings. On a
    /// yes the store is written at once, so the keyboard has the vault.
    func turnOnAutoFill() async {
        Trace.note("asking iOS to turn AutoFill on")
        Log.fill.notice("asking iOS to turn AutoFill on")
        let on = await withCheckedContinuation { done in
            ASSettingsHelper.requestToTurnOnCredentialProviderExtension { done.resume(returning: $0) }
        }
        Trace.note("iOS answered the request to turn AutoFill on with \(on)")
        Log.fill.notice("iOS answered the request to turn AutoFill on with \(on)")
        autoFillOn = on
        if on, let vault { await IdentityStore.replace(with: vault.summaries()) }
    }

    func cameToFront() {
        cameBack()
        Task { await readAutoFill() }
        if phase != .signedOut, VaultFile.lastSynced().map({ $0.timeIntervalSinceNow < -60 }) ?? true {
            Task { await sync() }
        }
        guard case .locked = phase, !faceAsked else { return }
        if face.forgetIfFacesChanged() {
            lockSentence = String(localized: "Face ID changed. Enter your master password.")
        }
        guard canUseFace else { return }
        faceAsked = true
        Task { await unlockWithFace() }
    }

    /// When the app last went to the background with the vault open.
    private var leftAt: Date?

    /// The vault stays open for the chosen time away, and locks on the
    /// return after it; at once when the choice is 0.
    func wentAway() {
        faceAsked = false
        leftAt = .now
        if choices.lockAfter == 0 { lock() }
    }

    func cameBack() {
        if LockRule.locks(leftAt: leftAt, now: .now, after: choices.lockAfter) { lock() }
        leftAt = nil
    }

    func unlockWithFace() async {
        guard case .locked(let account) = phase, !unlocking else { return }
        unlocking = true
        defer { unlocking = false }
        do {
            let key = try await face.open(reason: String(localized: "Open your vault"))
            let faced = ContinuousClock.now
            open(account, userKey: key)
            faceToVault = faced.duration(to: .now)
        } catch FaceKey.Failure.gone {
            lockSentence = String(localized: "Face ID changed. Enter your master password.")
        } catch {
            lockSentence = nil
        }
    }

    func unlock(password: SecretBytes) async {
        guard case .locked(let account) = phase, !unlocking else { return }
        unlocking = true
        derivingKey = true
        defer { unlocking = false; derivingKey = false }
        do {
            let key = try await Task.detached(priority: .userInitiated) { try account.userKey(password: password) }.value
            keepForFace(key)
            open(account, userKey: key)
        } catch {
            lockSentence = String(localized: "That's not the master password.")
        }
    }

    /// Locked by hand, or by the phone locking: the grace goes too.
    func lockNow() {
        GraceKey.app.forget()
        lock()
    }

    func lock() {
        guard case .open(let account) = phase else { return }
        userKey = nil
        vault = nil
        lockSentence = nil
        phase = .locked(account)
    }

    private func keepForFace(_ key: VaultKey) {
        guard FaceKey.available, choices.faceID else { return }
        do {
            try face.keep(key)
        } catch {
            Log.app.error("the key was not kept for Face ID: \((error as? KeychainError)?.status ?? 0)")
        }
    }

    private func open(_ account: Account, userKey: VaultKey) {
        self.userKey = userKey
        GraceKey.app.keep(userKey, minutes: choices.grace)
        lockSentence = nil
        if let data = VaultFile.read() { vault = try? Vault(data: data, userKey: userKey) }
        phase = .open(account)
        if let vault { Task { await IdentityStore.replace(with: vault.summaries()) } }
        Task { await sync(force: true) }
    }

    /// Settings' choices, written as they change.
    var choices = Choices.read() {
        didSet {
            choices.write()
            if !choices.faceID { face.forget() } else if let userKey, !face.isKept { keepForFace(userKey) }
            if choices.grace == 0 { GraceKey.app.forget() } else if let userKey { GraceKey.app.keep(userKey, minutes: choices.grace) }
        }
    }

    typealias SaveFailure = OriPass.SaveFailure

    /// A login or a note written to the account, and the vault and the
    /// keyboard's suggestions brought up to it.
    func save(_ draft: Draft, editing item: Item?) async throws {
        guard let api, let vault, let userKey else { throw SaveFailure.notOpen }
        do {
            let data = try await Saving.save(draft, editing: item, in: vault, with: api)
            let opened = try Vault(data: data, userKey: userKey)
            self.vault = opened
            await IdentityStore.replace(with: opened.summaries())
        } catch SaveFailure.outOfDate {
            await sync(force: true)
            throw SaveFailure.outOfDate
        }
    }

    func signOut() async {
        lock()
        api = nil
        await SignOut.wipe()
        phase = .signedOut
    }

    var census: Census? {
        guard let vault, let data = VaultFile.read() else { return nil }
        return Census(vault: vault, data: data)
    }

    /// A sync, by a pull (forced) or because the last is a minute old. With
    /// the vault locked it only downloads; the next unlock reads what came.
    func sync(force: Bool = false) async {
        guard let api, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            let fetched = force ? try await VaultFile.sync(with: api) : try await VaultFile.syncIfChanged(with: api)
            guard let data = fetched, let userKey else { return }
            let opened = try Vault(data: data, userKey: userKey)
            vault = opened
            syncFailure = nil
            await IdentityStore.replace(with: opened.summaries())
        } catch Api.Failure.signedOut {
            // The refresh token was refused: signed out elsewhere, or the
            // password changed. What this phone holds goes with it.
            await signOut()
        } catch let failure as Api.Failure {
            syncFailure = failure
        } catch {
            syncFailure = .status(0, nil)
        }
    }
}
