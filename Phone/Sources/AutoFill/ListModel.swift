import AuthenticationServices
import Observation
import UIKit

/// The list behind the keyboard's key: a face, then the logins for the
/// page or the app first and every login under them, searched as typed.
@MainActor @Observable
final class ListModel {
    enum State: Equatable {
        case opening
        case password(String?)
        case open
    }

    private(set) var state = State.opening
    var query = ""
    private(set) var summaries: [Summary] = []
    private(set) var registering = false
    private(set) var failure: String?
    private var vault: Vault?
    private let matching: Matching
    private let services: [ASCredentialServiceIdentifier]
    let purpose: Purpose
    private let finish: (Answer, Vault?) -> Void

    /// What the list was asked for: a login, a code, a passkey for the
    /// relying party in the parameters, or a place for a new passkey.
    enum Purpose {
        case login
        case code
        case passkey(ASPasskeyCredentialRequestParameters)
        case register(ASPasskeyCredentialRequest)
    }

    init(services: [ASCredentialServiceIdentifier], purpose: Purpose = .login, finish: @escaping (Answer, Vault?) -> Void) {
        var services = services
        if case .passkey(let parameters) = purpose {
            services.append(ASCredentialServiceIdentifier(identifier: parameters.relyingPartyIdentifier, type: .domain))
        }
        if case .register(let request) = purpose {
            services.append(ASCredentialServiceIdentifier(identifier: request.credentialIdentity.serviceIdentifier.identifier, type: .domain))
        }
        matching = Matching(services)
        self.services = services
        self.purpose = purpose
        self.finish = finish
    }

    var suggested: [Summary] { filtered.filter(matching.matches) }
    var others: [Summary] { filtered.filter { !matching.matches($0) } }

    /// The passkeys the relying party will take, when a passkey was asked.
    var passkeys: [Summary] {
        guard case .passkey(let parameters) = purpose else { return [] }
        let allowed = Set(parameters.allowedCredentials)
        return summaries.filter { summary in
            summary.passkeys.contains { passkey in
                passkey.rpId == parameters.relyingPartyIdentifier
                    && (allowed.isEmpty || Passkeys.credentialID(passkey.credentialId).map(allowed.contains) == true)
            }
        }
    }

    private var filtered: [Summary] {
        var logins = summaries.filter { $0.kind == .login }
        if case .code = purpose { logins = logins.filter(\.hasTotp) }
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return logins }
        return logins.filter { summary in
            let text = ([summary.name, summary.username ?? ""] + summary.uris.map(\.uri)).joined(separator: " ").lowercased()
            return words.allSatisfy(text.contains)
        }
    }

    func openWithFace() async {
        #if DEBUG
        if Shared.container.map({ FileManager.default.fileExists(atPath: $0.appending(path: "debug-no-face").path) }) == true {
            state = .password(nil)
            return
        }
        #endif
        do {
            let reason = if case .register = purpose { String(localized: "Make a passkey") } else { String(localized: "Fill a password") }
            opened(try await Unlocking.open(reason: reason))
        } catch Unlocking.Failure.signedOut {
            state = .password(String(localized: "Sign in to OriPass first."))
        } catch {
            state = .password(nil)
        }
    }

    func open(password: SecretBytes) async {
        guard let account = Account.stored(), let data = VaultFile.read() else { return }
        Trace.note("memory before the KDF \(Memory.footprint()) MB")
        do {
            let key = try await Task.detached(priority: .userInitiated) { try account.userKey(password: password) }.value
            Trace.note("memory after the KDF \(Memory.footprint()) MB, at most \(Memory.peak()) MB, \(account.kdf)")
            opened(try Vault(data: data, userKey: key))
        } catch {
            state = .password(String(localized: "That's not the master password."))
        }
    }

    private func opened(_ vault: Vault) {
        self.vault = vault
        summaries = vault.summaries().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        state = .open
        let summaries = summaries
        Task { await IdentityStore.replace(with: summaries) }
        if case .register(let request) = purpose { Task { await place(request) } }
    }

    /// What was asked for, from the row tapped: the login into both
    /// fields, its code, or a passkey's assertion.
    func fill(_ summary: Summary) {
        guard let item = try? vault?.item(id: summary.id) else { return }
        let answer: Answer? = switch purpose {
        case .login: Answer.login(item)
        case .code: Answer.code(item)
        case .passkey, .register: Answer.login(item)
        }
        if let answer { finish(answer, vault) }
    }

    /// A new login's form, with the page's address in it.
    var newLogin: Draft {
        var draft = Draft()
        if let service = services.first(where: { $0.type == .URL }) ?? services.first {
            let page = Matching.page(service)
            if let url = page.url, let scheme = url.scheme, let host = url.host() {
                draft.uris = ["\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")"]
            } else if let host = page.host {
                draft.uris = ["https://" + host]
            }
            draft.name = page.host ?? ""
        }
        return draft
    }

    var usernames: [String] { Usernames.ranked(summaries.map(\.username)) }

    /// A login made from the list: written to the vault under the face the
    /// list was opened with, and filled into the page at once.
    func add(_ draft: Draft) async throws {
        guard let vault, let account = Account.stored(), let tokens = Tokens.stored() else { throw SaveFailure.notOpen }
        let api = Api(client: Client(server: account.server), tokens: tokens)
        let data = try await Saving.save(draft, editing: nil, in: vault, with: api)
        let opened = (try? Vault(data: data, userKey: vault.userKey)) ?? vault
        Trace.note("made a login from the list")
        finish(.password(ASPasswordCredential(user: draft.username, password: draft.password)), opened)
    }

    func signIn(with summary: Summary) {
        guard case .passkey(let parameters) = purpose, let item = try? vault?.item(id: summary.id),
              let answer = Answer.passkey(item, credentialID: nil, clientDataHash: parameters.clientDataHash) else { return }
        finish(answer, vault)
    }

    /// The site's logins that can take the passkey being made.
    var homes: [Summary] {
        guard case .register(let request) = purpose else { return [] }
        return PasskeyRegistration.homes(for: request.credentialIdentity.serviceIdentifier.identifier, in: summaries)
    }

    /// The username the site gave for the passkey.
    var registeringUser: String? {
        guard case .register(let request) = purpose else { return nil }
        return request.credentialIdentity.user
    }

    /// A passkey the site says it has already stops here, as WebAuthn asks;
    /// with no login to choose from, the passkey is made for a new one.
    private func place(_ request: ASPasskeyCredentialRequest) async {
        let excluded = request.excludedCredentials?.map(\.credentialID) ?? []
        if PasskeyRegistration.holds(excluded, for: request.credentialIdentity.serviceIdentifier.identifier, in: summaries) {
            Trace.note("the site has this passkey already")
            return finish(.refused(.matchedExcludedCredential), nil)
        }
        if homes.isEmpty { await register(on: nil) }
    }

    /// The passkey made under the face the list was opened with, and handed
    /// to the site only once the account has it: one that was not kept
    /// would leave the site holding a key nobody has. The store is written
    /// first, since the extension goes as soon as the answer does.
    func register(on summary: Summary?) async {
        guard case .register(let request) = purpose, let vault, let account = Account.stored(), let tokens = Tokens.stored(),
              let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity else { return }
        registering = true
        failure = nil
        defer { registering = false }
        let made = PasskeyRegistration(relyingParty: identity.relyingPartyIdentifier, userName: identity.userName,
                                       userHandle: identity.userHandle)
        do {
            let api = Api(client: Client(server: account.server), tokens: tokens)
            let data = try await Saving.keep(made.passkey, on: summary.map { try vault.item(id: $0.id) }, in: vault, with: api)
            if let opened = try? Vault(data: data, userKey: vault.userKey) { await IdentityStore.replace(with: opened.summaries()) }
            Trace.note(summary == nil ? "made a passkey on a new login" : "made a passkey on a login")
            finish(.registered(ASPasskeyRegistrationCredential(
                relyingParty: identity.relyingPartyIdentifier, clientDataHash: request.clientDataHash,
                credentialID: made.credentialID, attestationObject: made.attestationObject)), nil)
        } catch {
            Trace.note("could not keep the passkey: \(error)")
            failure = String(localized: "It could not be saved.")
        }
    }

    enum Part { case username, password, code }

    func copy(_ part: Part, of summary: Summary) {
        guard let login = try? vault?.item(id: summary.id).login else { return }
        let value: String? = switch part {
        case .username: login.username
        case .password: login.password
        case .code: login.totp.flatMap(Totp.init)?.code(at: .now)
        }
        if let value { Pasteboard.copy(value) }
    }
}

enum Memory {
    /// The process's footprint in MB, as iOS counts it against the limit.
    static func footprint() -> Int { read(\.phys_footprint) }

    /// The most it has been since the process started.
    static func peak() -> Int { read(\.ledger_phys_footprint_peak) }

    private static func read<Number: BinaryInteger>(_ field: KeyPath<task_vm_info_data_t, Number>) -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int(info[keyPath: field]) / 1_048_576 : -1
    }
}
