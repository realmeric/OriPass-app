import AuthenticationServices
import Combine
import Foundation

/// What the system's list is told of one passkey, and nothing else: no
/// item's id, no handle, and no key.
struct PasskeyIdentity: Equatable, Redacted {
    let relyingParty: String
    let userName: String
    let credentialID: Data

    var redactedLabel: String { "PasskeyIdentity" }
}

/// The system's list of identities, which a page's question may read while
/// the vault is shut. `FakeIdentityList` stands behind it for a test.
protocol IdentityList: Sendable {
    func replace(with identities: [PasskeyIdentity]) async
    func empty() async
}

/// The one file that names the system's store. A write to a store that is
/// off is lost, so its state is asked first.
struct SystemIdentityList: IdentityList {
    func replace(with identities: [PasskeyIdentity]) async {
        let store = ASCredentialIdentityStore.shared
        guard await store.state().isEnabled else { return }
        let written: [any ASCredentialIdentity] = identities.map {
            ASPasskeyCredentialIdentity(relyingPartyIdentifier: $0.relyingParty, userName: $0.userName,
                                        credentialID: $0.credentialID, userHandle: Data(), recordIdentifier: nil)
        }
        do {
            try await store.replaceCredentialIdentities(written)
        } catch {
            Log.app.error("the system's list refused \(written.count) passkeys: \((error as NSError).code)")
        }
    }

    func empty() async {
        let store = ASCredentialIdentityStore.shared
        guard await store.state().isEnabled else { return }
        try? await store.removeAllCredentialIdentities()
    }
}

/// A list that only remembers, for a test.
final class FakeIdentityList: IdentityList, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [PasskeyIdentity] = []
    private var count = 0

    /// What the list holds now.
    var identities: [PasskeyIdentity] { lock.withLock { held } }
    /// How many times it was called, for either thing.
    var calls: Int { lock.withLock { count } }

    func replace(with identities: [PasskeyIdentity]) async {
        lock.withLock {
            held = identities
            count += 1
        }
    }

    func empty() async {
        lock.withLock {
            held = []
            count += 1
        }
    }
}

/// The second exception to D6, off until he says so: while the vault is open
/// and the switch is on, the system's list holds a relying party, a username
/// and a credential id for each passkey. It is for a page the system would
/// otherwise not offer OriPass to. The lock empties it, and a launch empties
/// what a killed run left. With the switch off the system is not called.
@MainActor
final class PasskeyOffer {
    static let sentence = "While the vault is open, each passkey's site, username and id are kept in a list of the system's, for a page that would not otherwise offer OriPass. The lock takes them out."

    private let store: VaultStore
    private let preferences: Preferences
    private let list: IdentityList
    /// What the system's list may hold, and nil when it holds nothing of
    /// this app's. At launch that is not known while the switch is on.
    private var written: [PasskeyIdentity]?
    private var watching: Set<AnyCancellable> = []
    /// The last write, which each waits for, so a lock's comes after the
    /// unlock's whatever the system takes over either. For a test to wait on.
    private(set) var writing: Task<Void, Never>?

    init(store: VaultStore, preferences: Preferences, list: IdentityList) {
        self.store = store
        self.preferences = preferences
        self.list = list
        written = isOn ? [] : nil
        follow()
        // `@Published` sends before the value is in place.
        store.$revision.map { _ in }.merge(with: store.$state.map { _ in })
            .merge(with: preferences.$settings.map { _ in })
            .sink { [weak self] in DispatchQueue.main.async { self?.follow() } }
            .store(in: &watching)
        // With the store still full, in the turn of the lock.
        NotificationCenter.default.publisher(for: VaultStore.willLock, object: store).sink { [weak self] _ in
            self?.takeOut()
        }.store(in: &watching)
    }

    private var isOn: Bool { preferences.settings.privacy.passkeysInSystemList }

    private func follow() {
        guard isOn, store.state == .unlocked else { return takeOut() }
        let identities = store.shelves.all.flatMap { entry -> [PasskeyIdentity] in
            guard entry.item.isOutstanding, entry.item.login?.passkeysCreated.isEmpty == false else { return [] }
            return Passkey.all(in: entry.item).filter(\.isES256).map {
                PasskeyIdentity(relyingParty: $0.relyingParty, userName: $0.userName ?? entry.item.login?.username ?? "",
                                credentialID: $0.credentialID)
            }
        }
        guard identities != written else { return }
        written = identities
        write { [list] in await list.replace(with: identities) }
    }

    private func takeOut() {
        guard written != nil else { return }
        written = nil
        write { [list] in await list.empty() }
    }

    /// The list out before the app goes, whatever the quit does to the vault.
    func quit() async {
        takeOut()
        await writing?.value
    }

    private func write(_ work: @escaping @Sendable () async -> Void) {
        let before = writing
        writing = Task {
            await before?.value
            await work()
        }
    }
}
