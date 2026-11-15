import Foundation

/// The sheet the system raises when OriPass is picked from its Passwords
/// menu or for a page's passkey or code: the logins or passkeys for what
/// asked, and one of them handed back. It asks the door for all of it and
/// keeps none of it past the sheet. It writes nothing anywhere, and the
/// system's own list of identities least of all (D6).
///
/// When the system names nothing, the app is asked what the sheet is up over,
/// and a field finds any other login by a word. A row a word found is a
/// `pick`, which the door holds to no address.
@MainActor
final class AutoFillSheet: ObservableObject {
    enum State: Equatable {
        case asking
        case listed
        /// A row was chosen, and the door is at it, a finger perhaps.
        case filling(id: String)
        /// Asked, and no login holds for it.
        case nothing
        /// Nothing the door can be asked about, from the system or the app.
        case unnamed
        case shut(isRunning: Bool)
    }

    /// How long a shut door is left before it is tried again. The sheet is
    /// up, so someone is looking at it, and a door that is not there costs
    /// one `connect` that fails.
    nonisolated static let again: Duration = .seconds(1)

    @Published private(set) var state = State.asking
    @Published private(set) var rows: [SheetRow] = []
    /// What the door said to the last row chosen.
    @Published private(set) var refusal: String?
    /// What is typed in the field.
    @Published var word = "" {
        didSet { if word != oldValue { find() } }
    }
    /// Who the sheet says it is for, which the app may say instead of the
    /// system.
    @Published private(set) var name: String?

    /// Whether it lists passkeys, and so says that.
    let isForPasskeys: Bool
    /// Whether it lists logins for their one-time codes, and hands back a
    /// code and nothing else.
    let isForCodes: Bool
    /// Whether the system named nothing and the app is asked instead.
    private let looksInFront: Bool

    private let services: [AutoFillService]
    private let door: any SheetDoor
    private let again: Duration
    private let finish: (SheetCredential) -> Void
    private let assert: (SheetAssertion) -> Void
    private let code: (SheetCode) -> Void
    private let dismiss: () -> Void
    private var asking: Task<Void, Never>?
    private var finding: Task<Void, Never>?
    /// What the sheet holds with no word in the field.
    private var listed: [SheetRow] = []
    private var standing = State.asking

    /// `looksInFront` counts only when the list of services is empty, and a
    /// passkey's question never does: what it asks for is the relying party's.
    init(services: [AutoFillService], door: any SheetDoor, again: Duration = AutoFillSheet.again, isForCodes: Bool = false,
         looksInFront: Bool = false, finish: @escaping (SheetCredential) -> Void, assert: @escaping (SheetAssertion) -> Void = { _ in },
         code: @escaping (SheetCode) -> Void = { _ in }, dismiss: @escaping () -> Void) {
        self.services = services
        self.door = door
        self.again = again
        self.finish = finish
        self.assert = assert
        self.code = code
        self.dismiss = dismiss
        self.isForCodes = isForCodes
        self.looksInFront = looksInFront && services.isEmpty
        name = services.first?.name
        isForPasskeys = services.contains(where: \.isPasskey)
    }

    /// A sheet that asks nobody, for a shot.
    init(still state: State, name: String?, rows: [SheetRow] = [], refusal: String? = nil, isForPasskeys: Bool = false,
         isForCodes: Bool = false, looksInFront: Bool = false, word: String = "") {
        services = []
        door = NoDoor()
        again = Self.again
        finish = { _ in }
        assert = { _ in }
        code = { _ in }
        dismiss = {}
        self.isForPasskeys = isForPasskeys
        self.isForCodes = isForCodes
        self.looksInFront = looksInFront
        self.state = state
        self.name = name
        self.rows = rows
        self.refusal = refusal
        self.word = word
    }

    /// Over a shut door it goes on asking, so that a vault unlocked in Quick
    /// Access brings the list here with nothing more done. `takingALoneRow`
    /// chooses the row when one is listed: a passkey the system's own list
    /// offered has already been picked.
    func begin(takingALoneRow: Bool = false) {
        asking?.cancel()
        guard !services.isEmpty || looksInFront else {
            state = .unnamed
            return
        }
        asking = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.list()
                if takingALoneRow, self.state == .listed, self.rows.count == 1 { return self.choose(self.rows[0]) }
                guard case .shut = self.state else { return }
                try? await Task.sleep(for: self.again)
            }
        }
    }

    private func list() async {
        guard looksInFront else { return await list(services) }
        let answer = await door.ask(.front)
        guard !Task.isCancelled else { return }
        switch answer {
        case .front(let service?, _) where isForCodes:
            name = service.name
            await list([service])
        case .front(let service?, let logins):
            name = service.name
            stand(logins.map { SheetRow(id: $0.id, title: $0.title, username: $0.username, service: service) }, on: .nothing)
        case .shut(let isRunning):
            shut(isRunning: isRunning)
        default:
            stand([], on: .unnamed)
        }
    }

    private func list(_ services: [AutoFillService]) async {
        var found: [SheetRow] = []
        for service in services {
            switch await door.ask(isForCodes ? .codes(service) : service.listing) {
            case .logins(_, let logins):
                let new = logins.filter { login in !found.contains { $0.id == login.id } }
                found += new.map { SheetRow(id: $0.id, title: $0.title, username: $0.username, service: service) }
            case .shut(let isRunning):
                guard !Task.isCancelled else { return }
                shut(isRunning: isRunning)
                return
            case .refused, .filled, .asserted, .code, .front:
                break
            }
        }
        guard !Task.isCancelled else { return }
        stand(found, on: .nothing)
    }

    /// What is held with no word typed, and shown unless one is: the field
    /// is his from the moment it is up, and `front` can take a second.
    private func stand(_ found: [SheetRow], on nothing: State) {
        listed = found
        standing = found.isEmpty ? nothing : .listed
        guard !isFinding else { return }
        rows = found
        state = standing
    }

    private func shut(isRunning: Bool) {
        listed = []
        word = ""
        rows = []
        state = .shut(isRunning: isRunning)
    }

    /// Asked again at each letter, showing only the last word's answer, and
    /// back to what the sheet held when the field is emptied.
    private func find() {
        finding?.cancel()
        finding = nil
        switch state {
        case .filling, .shut: return
        default: break
        }
        refusal = nil
        guard isFinding else {
            rows = listed
            state = standing
            return
        }
        let word = self.word
        finding = Task { [weak self] in
            guard let answer = await self?.door.ask(.find(word)), !Task.isCancelled, let self else { return }
            switch answer {
            case .logins(_, let logins):
                self.rows = logins.map { SheetRow(id: $0.id, title: $0.title, username: $0.username, service: nil) }
                self.state = self.rows.isEmpty ? .nothing : .listed
            case .shut(let isRunning):
                self.shut(isRunning: isRunning)
                self.begin()
            default:
                self.rows = []
                self.state = .nothing
            }
        }
    }

    func chooseFirst() {
        if let first = rows.first { choose(first) }
    }

    func choose(_ row: SheetRow) {
        guard state == .listed else { return }
        finding?.cancel()
        state = .filling(id: row.id)
        refusal = nil
        var request = SheetRequest.pick(id: row.id)
        if let service = row.service { request = isForCodes ? .code(id: row.id, service) : service.taking(row.id) }
        asking = Task { [weak self] in
            guard let answer = await self?.door.ask(request), !Task.isCancelled, let self else { return }
            switch answer {
            case .filled(let credential) where !credential.password.isEmpty:
                self.end()
                self.finish(credential)
            case .filled:
                self.refuse("That login has no password.")
            case .asserted(let assertion):
                self.end()
                self.assert(assertion)
            case .code(let code):
                self.end()
                self.code(code)
            case .refused(let reason):
                self.refuse(self.sentence(for: reason))
            case .shut(let isRunning):
                self.shut(isRunning: isRunning)
                self.begin()
            case .logins, .front:
                self.refuse(self.sentence(for: ""))
            }
        }
    }

    private func refuse(_ sentence: String) {
        refusal = sentence
        state = .listed
    }

    /// The same words the extension's menu has for each reason.
    private func sentence(for reason: String) -> String {
        if isForPasskeys {
            switch reason {
            case "gone": return "That passkey can no longer be used."
            case "declined": return "OriPass was not told to sign in with that passkey."
            default: return "That passkey is not for this site."
            }
        }
        if isForCodes {
            switch reason {
            case "gone": return "That login no longer has a code."
            case "declined": return "OriPass was not told to hand over that code."
            default: break
            }
        }
        switch reason {
        case "gone": return "That login is no longer in the vault."
        case "insecure": return "This page is not secure, and the login is saved for a secure one."
        case "declined": return "OriPass was not told to fill that login."
        default: return "That login is not for this page."
        }
    }

    func cancel() {
        end()
        dismiss()
    }

    /// The sheet is going, whoever took it down, and what it listed with it.
    func end() {
        asking?.cancel()
        asking = nil
        finding?.cancel()
        finding = nil
        listed = []
        rows = []
    }

    // MARK: What it says

    /// Whether it has a field: a code has no way to be handed over for a row
    /// no address holds, and any other sheet was told what it is for.
    private var hasField: Bool { looksInFront && !isForCodes }

    /// Over a shut vault nothing could be found, and the lock is what to say.
    var showsField: Bool {
        if case .shut = state { return false }
        return hasField
    }

    var isFilling: Bool {
        if case .filling = state { return true }
        return false
    }

    private var isFinding: Bool { hasField && !word.allSatisfy(\.isWhitespace) }

    var statement: String {
        switch state {
        case .asking: return "Asking OriPass…"
        case .listed where isFinding: return "Logins found"
        case .nothing where isFinding: return "No login found"
        case .listed: return "\(listHeading)\(name.map { " for \($0)" } ?? "")"
        case .filling: return "Waiting for OriPass…"
        case .nothing: return "No \(thing)\(name.map { " for \($0)" } ?? "")"
        case .unnamed: return "This app did not say what it signs in to"
        case .shut(let isRunning): return isRunning ? "OriPass is locked" : "OriPass is not open"
        }
    }

    var sentence: String? {
        switch state {
        case .asking, .listed, .filling: return nil
        case .nothing where hasField, .unnamed where !isForCodes: return nil
        case .nothing where isForPasskeys: return "Cancel, and the site will offer another way to sign in."
        case .nothing where isForCodes, .unnamed: return "Quick Access can find any login and copy its code."
        case .nothing: return "Quick Access can find any login and type it here."
        case .shut(true): return "Unlock it in Quick Access, on its key or from the mark in the menu bar, and the \(thing)s will come here."
        case .shut(false): return "Open it and unlock it, and the \(thing)s will come here."
        }
    }

    private var listHeading: String {
        if isForCodes { return "One-time codes" }
        return isForPasskeys ? "Passkeys" : "Logins"
    }

    private var thing: String {
        if isForCodes { return "one-time code" }
        return isForPasskeys ? "passkey" : "login"
    }
}

private struct NoDoor: SheetDoor {
    func ask(_ request: SheetRequest) async -> SheetAnswer { .shut(isRunning: true) }
}
