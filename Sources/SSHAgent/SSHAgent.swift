import Combine
import Foundation

/// The agent's side of the app: whether the socket stands, what each request
/// is answered with, and who has said yes to what. Listing and signing are
/// done from what the store holds, and a private half is out of an item for
/// one signature (D4). Nothing here is written anywhere, the public keys
/// among it (D6), so over a shut vault there is no list until a finger has
/// opened it.
///
/// An approval is one key for one app, as long as `SSHChoices.approval` says
/// and never past the lock. A connection `session-bind` calls forwarded is
/// some other host's, and is asked every time.
///
/// A pass (`AgentPass`) is the one thing that outlives a lock: a request from
/// its app that it covers, a login to a host it knows or a git commit, is
/// signed from what the pass holds, open or shut, with nobody asked, and any
/// other request is everything above, with his phone able to answer the card
/// when the pass holds the key (`PhoneDoor`).
@MainActor
final class SSHAgent {
    /// What the room shows and copies. The app never edits the file.
    static let configLine = "IdentityAgent ~/.oripass/agent.sock"
    static let unopened = "The socket could not be made. Is another copy of \(AppInfo.name) running?"

    private struct Approval: Hashable {
        let key: Data
        let app: String
    }

    /// How a question came out. A phone's yes is its own: nothing of the
    /// vault's is touched for it, and the pass signs.
    private enum Asked {
        case no, yes
        case phone(AgentPass)
    }

    /// A request a phone may answer, and the pass that would sign it.
    private struct PhoneWay {
        let pass: AgentPass
        let act: PhoneAct
        let key: AgentKey?
    }

    private let door: Door
    private let authoriser: Authoriser?
    private let stage: AgentStage?
    private let now: () -> Date
    /// How long a question waits. Sixty seconds unless a test is waiting.
    private let patience: TimeInterval
    /// The question that is on the card or waiting behind the password's.
    private var up: AgentQuestion?
    private var store: VaultStore { door.store }
    private var passes: AgentPasses { door.passes }
    /// Where a phone's answer comes in (OP-88).
    let phones: PhoneDoor

    private let path: URL?
    /// With no path it listens for nobody, and a test over a socketpair
    /// hands it a caller with `adopt`, so the lock has one to cut.
    private lazy var server = SSHAgentServer(path: path) { [weak self] request, session in
        await self?.answer(request, on: session) ?? .failure
    }

    private var approvals: [Approval: Date] = [:]
    /// The public keys of what the store holds, as of one revision.
    private var offered: (opening: Int, revision: Int, keys: [AgentKey])?
    /// The finger being waited for, which every request waits on together.
    private var opening: Task<Bool, Never>?
    /// The question that is up. One at a time, and the next looks again at
    /// what the last one approved.
    private var asking: Task<Asked, Never>?
    /// Moves at each lock, so an answer after one is no answer.
    private var shuts = 0
    private var wasOpen = false
    private var watching: Set<AnyCancellable> = []

    /// Why the switch is on and nothing is listening.
    private(set) var problem: String?

    init(door: Door, authoriser: Authoriser?, stage: AgentStage? = nil, path: URL? = nil, phonePath: URL? = nil,
         phoneIdentifiers: [String] = PeerCheck.oriCode, addPhoneWindow: TimeInterval = 300,
         now: @escaping () -> Date = Date.init, patience: TimeInterval = 60) {
        self.door = door
        self.authoriser = authoriser
        self.stage = stage
        self.now = now
        self.patience = patience
        self.path = path
        phones = PhoneDoor(preferences: door.preferences, passes: door.passes, path: phonePath,
                           identifiers: phoneIdentifiers, now: now, addWindow: addPhoneWindow)
        // Before the store is emptied. The state as well, for the engine
        // going by itself, which posts nothing; and only from open, since a
        // request over a shut vault is why it is opening.
        NotificationCenter.default.publisher(for: VaultStore.willLock, object: door.store).sink { [weak self] _ in
            self?.locked()
        }.store(in: &watching)
        phones.confirm = { [weak self] name, fingerprint in await self?.confirm(phone: name, fingerprint) }
        door.store.$state.sink { [weak self] state in
            guard let self else { return }
            if state == .unlocked { self.wasOpen = true } else { self.locked() }
        }.store(in: &watching)
    }

    var isOpen: Bool { server.isOpen }
    var connected: Int { server.connected }

    /// A caller with no file, for a test.
    func adopt(_ descriptor: Int32, peer: AgentPeer) {
        server.adopt(descriptor, peer: peer)
    }

    /// The switch, and the choice of how long a yes lasts: a shorter one
    /// must not leave a longer one standing.
    func follow(_ choices: SSHChoices) {
        approvals = [:]
        problem = nil
        guard choices.isOn else {
            // No socket, and nobody left to hold a key for.
            passes.endAll()
            return server.close()
        }
        do {
            try server.open()
        } catch {
            Log.app.error("agent: did not open: \((error as NSError).code)")
            problem = Self.unopened
        }
    }

    /// The app is going: a file left behind is a socket nobody answers.
    func end() {
        passes.endAll()
        phones.end()
        server.close()
    }

    private func locked() {
        guard wasOpen else { return }
        wasOpen = false
        shuts += 1
        approvals = [:]
        offered = nil
        server.cut()
        if asking != nil { up?.withdraw() }
    }

    // MARK: Answering

    func answer(_ request: AgentRequest, on session: AgentSession) async -> AgentAnswer {
        switch request {
        case .identities:
            if store.state != .unlocked {
                let held = passes.keys(for: session)
                if !held.isEmpty { return .identities(held) }
            }
            switch await vaultIsOpen(for: session, phoneWay(for: session)) {
            case .no: return .failure
            case .yes: return .identities(keys)
            case .phone(let pass): return .identities(pass.keys)
            }
        case .sign(let key, let data, let flags):
            if let (pass, act) = passes.pass(for: key, signing: data, on: session) {
                return await sign(data, with: key, flags: flags, through: pass, act, on: session)
            }
            switch await vaultIsOpen(for: session, phoneWay(to: key, signing: data, for: session)) {
            case .no: return .failure
            case .yes: return await sign(data, with: key, flags: flags, on: session)
            case .phone(let pass): return await sign(data, with: key, flags: flags, through: pass, .phone, on: session)
            }
        case .bind(let bind):
            return session.take(bind) ? .success : .failure
        case .passes:
            // A count and nothing of whose, to anyone: the mark's menu says
            // as much to whoever looks at the screen.
            return .count(passes.standing.count)
        case .other:
            return .failure
        }
    }

    /// Every request that arrives over a shut vault waits on one finger,
    /// and the one that asked for it keeps it for its signature. With a way
    /// to a phone the card names the key the pass holds, the finger is one
    /// answer and the phone the other, and there may be no finger at all.
    private func vaultIsOpen(for session: AgentSession, _ way: PhoneWay? = nil) async -> Asked {
        guard store.state != .unlocked else { return .yes }
        if let opening { return await opening.value ? .yes : .no }
        let hasFinger = door.hasSeal && door.canUseFinger
        // No card with nothing to answer it: it would only flash.
        let question = hasFinger || way != nil ? question(about: way?.key, for: session, way: way, hasFinger: hasFinger,
                                                          isShut: true) : nil
        if let way, let question { phones.ask(question, way.act, key: way.key, pass: way.pass) }
        let asked = Task { [door] in
            await self.waiting(on: question) { isUp in
                if let question, !hasFinger { return await question.passwordChosen() }
                return await door.openForAgent(on: isUp ? question?.finger : nil)
            }
        }
        opening = asked
        let isOpen = await asked.value
        opening = nil
        if let question {
            if let way, question.yesFromPhone { return .phone(way.pass) }
            phones.end(question, isOpen ? .answeredAtMac : question.ending ?? .denied)
        }
        // The finger on the card gave it, as on a card with a key.
        if isOpen, let span = question?.passSpan, let signer = session.peer.signer {
            _ = give(appName: session.peer.appName, signer: signer, for: span)
        }
        session.fingerLasts = isOpen ? now().addingTimeInterval(patience) : nil
        session.fingerSpan = question?.span
        return isOpen ? .yes : .no
    }

    /// A request his phone could answer, which is one the card is about to
    /// be raised for, from an app whose pass holds the key. With no key, a
    /// forwarded caller wanting the list over a shut vault.
    private func phoneWay(to blob: Data? = nil, signing data: Data? = nil, for session: AgentSession) -> PhoneWay? {
        guard phones.hasPhone, let pass = passes.pass(holding: blob, for: session) else { return nil }
        guard let blob, let data else {
            return session.isForwarded ? PhoneWay(pass: pass, act: .list, key: nil) : nil
        }
        let act: PhoneAct = session.isForwarded ? .forwarded
            : passes.isOwnLogin(data, by: blob, on: session) ? .stranger : .signature
        return PhoneWay(pass: pass, act: act, key: pass.keys.first { $0.blob == blob })
    }

    /// The store's keys, read once for each revision: a private half out
    /// and wiped for the public half that lies beside it in the file.
    private var keys: [AgentKey] {
        if let offered, offered.opening == store.opening, offered.revision == store.revision { return offered.keys }
        let keys = (store.shelves.byType[.sshKey] ?? []).compactMap { entry -> AgentKey? in
            guard let half = Self.privateHalf(of: entry.item), let key = half.publicKey else { return nil }
            defer { half.wipe() }
            return AgentKey(id: entry.id, name: entry.item.name, kind: key.kind, blob: key.blob)
        }
        offered = (store.opening, store.revision, keys)
        return keys
    }

    private static func privateHalf(of item: Item) -> PrivateHalf? {
        guard case .sshKey(let key) = item.payload else { return nil }
        return key.privateKey.flatMap(PrivateHalf.init)
    }

    private func sign(_ data: Data, with blob: Data, flags: UInt32, on session: AgentSession) async -> AgentAnswer {
        guard let key = keys.first(where: { $0.blob == blob }) else { return .failure }
        // Said before anybody is asked: the answer would be no whatever
        // they said.
        if key.kind == .rsa, flags & AgentKey.rsaFlags == 0 { return .failure }
        switch await approval(of: key, signing: data, for: session) {
        case .no: return .failure
        case .phone(let pass): return await sign(data, with: blob, flags: flags, through: pass, .phone, on: session)
        case .yes: break
        }
        guard store.state == .unlocked, let item = store.entry(id: key.id)?.item, !item.isInTrash,
              let half = Self.privateHalf(of: item), half.publicKey?.blob == blob
        else { return .failure }
        // RSA is whole milliseconds, and the main thread has a panel to draw.
        let signature = await Task.detached { () -> Data? in
            defer { half.wipe() }
            return half.sign(data, flags: flags)
        }.value
        return signature.map(AgentAnswer.signature) ?? .failure
    }

    /// What a pass holds is not out of the vault for this and not wiped by
    /// it: the pass wipes it when it ends, which waits for this.
    private func sign(_ data: Data, with blob: Data, flags: UInt32, through pass: AgentPass, _ act: PassAct,
                      on session: AgentSession) async -> AgentAnswer {
        let signature = await Task.detached { pass.sign(data, with: blob, flags: flags) }.value
        guard let signature else { return .failure }
        passes.count(pass, act, on: session)
        return .signature(signature)
    }

    // MARK: Passes

    /// What a pass would hold, which is nothing with the vault shut: a pass
    /// is read out of its items.
    var passKeys: [AgentKey] { store.state == .unlocked ? keys : [] }

    /// New Pass, with no request waiting: a running app, for every key and
    /// one finger.
    func give(to app: PassApp, for span: PassSpan) async -> Bool {
        guard !passKeys.isEmpty, let authoriser, authoriser.hasFinger,
              await authoriser.authorise(.pass, for: app.name)
        else { return false }
        return give(appName: app.name, signer: app.signer, for: span)
    }

    /// Every key out of its item again, in `PrivateHalf`s the pass keeps.
    private func give(appName: String, signer: AppSigner, for span: PassSpan) -> Bool {
        let held = passKeys.compactMap { key -> AgentPass.Held? in
            guard let item = store.entry(id: key.id)?.item, !item.isInTrash, let half = Self.privateHalf(of: item)
            else { return nil }
            guard half.publicKey?.blob == key.blob else {
                half.wipe()
                return nil
            }
            return (key, half)
        }
        guard !held.isEmpty else { return false }
        return passes.give(held, appName: appName, signer: signer, for: span) != nil
    }

    // MARK: Asking

    /// A forwarded connection hears the question whatever else stands.
    private func approval(of key: AgentKey, signing data: Data, for session: AgentSession) async -> Asked {
        let wanted = Approval(key: key.blob, app: session.peer.app)
        guard !session.isForwarded else { return await ask(about: key, signing: data, for: session, wanted) }
        if isStanding(wanted) { return .yes }
        let finger = session.fingerLasts
        session.fingerLasts = nil
        if let finger, now() < finger {
            remember(wanted, for: session.fingerSpan ?? door.preferences.settings.ssh.approval)
            passes.know(key.blob, signing: data, on: session)
            return .yes
        }
        return await ask(about: key, signing: data, for: session, wanted)
    }

    private func isStanding(_ approval: Approval) -> Bool {
        approvals[approval].map { now() < $0 } == true
    }

    private func remember(_ approval: Approval, for span: SSHApproval) {
        guard let window = span.window else { return }
        approvals[approval] = now().addingTimeInterval(window)
    }

    /// One at a time, each with its own sixty seconds. Whoever was waiting
    /// looks again when the last one ends, since it may have been the same
    /// key for the same app.
    private func ask(about key: AgentKey, signing data: Data, for session: AgentSession, _ wanted: Approval) async -> Asked {
        let asked = shuts
        let deadline = Date().addingTimeInterval(patience)
        while let up = asking {
            _ = await up.value
            guard asked == shuts, Date() < deadline else { return .no }
            if !session.isForwarded, isStanding(wanted) { return .yes }
        }
        guard let authoriser else { return .no }
        let way = phoneWay(to: key.blob, signing: data, for: session)
        let question = question(about: key, for: session, way: way, purpose: AgentPurpose(signing: data, key: key.blob))
        if let way { phones.ask(question, way.act, key: way.key, pass: way.pass) }
        let task = Task { () -> Asked in
            let isHis = await self.waiting(on: question) { isUp in
                // The password's card takes the keys, so it never rises by
                // itself: he asks for it from this one, which goes.
                if isUp, !authoriser.hasFinger {
                    guard await question.passwordChosen() else { return false }
                    self.stage?.close()
                }
                return await authoriser.authorise(.sign, for: key.name, on: isUp ? question.finger : nil)
            }
            // Here and not behind the `await` below: the loop above would
            // find a finished task, which does not suspend, and keep the
            // main actor from whoever was to clear it.
            self.asking = nil
            if let way, question.yesFromPhone { return .phone(way.pass) }
            self.phones.end(question, isHis ? .answeredAtMac : question.ending ?? .denied)
            guard isHis, asked == self.shuts else { return .no }
            // A forwarded yes is for that one request.
            if !session.isForwarded { self.remember(wanted, for: question.span) }
            // The finger on the card gave it, so the password in its place
            // gives none.
            if let span = question.passSpan, authoriser.hasFinger, let signer = session.peer.signer {
                _ = self.give(appName: session.peer.appName, signer: signer, for: span)
            }
            self.passes.know(key.blob, signing: data, on: session)
            return .yes
        }
        asking = task
        return await task.value
    }

    /// The card that names a phone, which takes a finger and nothing else.
    /// Nil when it cannot be raised.
    private func confirm(phone name: String, _ fingerprint: String) async -> Bool? {
        guard asking == nil, let authoriser, authoriser.hasFinger else { return nil }
        let question = AgentQuestion(peer: AgentPeer(names: ["OriCode"], app: "OriCode"), key: nil, host: nil, isForwarded: false,
                                     adding: .init(name: name, fingerprint: fingerprint), hasFinger: true,
                                     approval: door.preferences.settings.ssh.approval, patience: patience) { [authoriser] in
            authoriser.withdraw()
        }
        let task = Task { () -> Asked in
            let isHis = await self.waiting(on: question) { isUp in
                await authoriser.authorise(.phone, for: name, on: isUp ? question.finger : nil)
            }
            self.asking = nil
            return isHis ? .yes : .no
        }
        asking = task
        if case .yes = await task.value { return true }
        return false
    }

    /// Who is asking, for the card. With no key it is the vault they want
    /// opened.
    private func question(about key: AgentKey?, for session: AgentSession, way: PhoneWay? = nil,
                          purpose: AgentPurpose = .login, hasFinger: Bool? = nil, isShut: Bool = false) -> AgentQuestion {
        AgentQuestion(peer: session.peer, key: key.map { .init(name: $0.name, fingerprint: $0.fingerprint) },
                      purpose: purpose, host: session.host, isForwarded: session.isForwarded,
                      hasFinger: hasFinger ?? (key == nil || authoriser?.hasFinger != false),
                      opensVault: isShut && key != nil, offersPassword: !isShut,
                      approval: door.preferences.settings.ssh.approval, icon: session.peer.icon,
                      patience: way == nil ? patience : patience * 2) { [authoriser] in authoriser?.withdraw() }
    }

    /// `answer` with the card up and the sixty seconds running, told whether
    /// it did come up. If not, nothing is drawing the question's finger and
    /// the system's sheet asks instead. Deny and the clock are both a
    /// withdrawal, which is `answer` hearing no.
    private func waiting<Answer>(on question: AgentQuestion?, for answer: (Bool) async -> Answer) async -> Answer {
        let isUp = question.map { stage?.show($0) == true } ?? false
        up = question
        let clock = Task { [authoriser, patience] in
            try await Task.sleep(nanoseconds: UInt64((question?.patience ?? patience) * 1_000_000_000))
            if let question { question.expire() } else { authoriser?.withdraw() }
        }
        let answered = await answer(isUp)
        clock.cancel()
        up = nil
        stage?.close()
        return answered
    }
}
