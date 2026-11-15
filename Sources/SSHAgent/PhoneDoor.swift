import Combine
import Foundation

/// OriCode's end of the wire: a line at a time in each direction, each heard
/// on the main actor in the order it came. A line over the cap closes it. A
/// test hands it one end of a socketpair.
final class PhoneConnection {
    typealias Hearing = @MainActor (Data) -> Void

    private static let newline = UInt8(ascii: "\n")

    /// It ended, whoever ended it. Called once.
    var onEnd: (() -> Void)?

    private let descriptor: Int32
    private let hearing: Hearing
    private let reading = DispatchQueue(label: "\(AppInfo.bundleID).phone.reading", qos: .userInitiated)
    private let writing = DispatchQueue(label: "\(AppInfo.bundleID).phone.writing", qos: .userInitiated)
    private let lock = NSLock()
    private var isOver = false

    init(descriptor: Int32, hearing: @escaping Hearing) {
        self.descriptor = descriptor
        self.hearing = hearing
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    func start() {
        reading.async { self.readLines() }
    }

    func say(_ line: Data) {
        writing.async {
            guard !self.lock.withLock({ self.isOver }) else { return }
            let written = line + [Self.newline]
            guard (try? written.withUnsafeBytes { try BridgeWire.send($0, to: self.descriptor) }) != nil
            else { return self.cut() }
        }
    }

    /// After whatever is on its way out.
    func finish() {
        writing.async { self.cut() }
    }

    func cut() {
        let wasOver = lock.withLock { () -> Bool in
            defer { isOver = true }
            return isOver
        }
        guard !wasOver else { return }
        shutdown(descriptor, SHUT_RDWR)
        onEnd?()
    }

    deinit {
        close(descriptor)
    }

    private func readLines() {
        var held = Data()
        var chunk = [UInt8](repeating: 0, count: PhoneWire.most)
        while true {
            let got = read(descriptor, &chunk, chunk.count)
            if got < 0, errno == EINTR { continue }
            guard got > 0 else { return cut() }
            held.append(contentsOf: chunk.prefix(got))
            while let end = held.firstIndex(of: Self.newline) {
                let line = Data(held[held.startIndex..<end])
                held = Data(held[held.index(after: end)...])
                guard line.count < PhoneWire.most else { return cut() }
                let hearing = self.hearing
                DispatchQueue.main.async { MainActor.assumeIsolated { hearing(line) } }
            }
            guard held.count < PhoneWire.most else { return cut() }
        }
    }
}

/// Where a phone's answer comes in, through OriCode (OP-88). It stands only
/// while a pass stands and a phone is registered, or while Add Phone waits, so
/// with neither there is no file and no way in. It takes OriCode's own process
/// and nobody else, and a yes is a signature it checks against the one key he
/// registered: OriCode can lose an answer and cannot make one. A yes signs one
/// request with what the pass holds, and reaches nothing of the vault.
@MainActor
final class PhoneDoor {
    private struct Open {
        let request: PhoneRequest
        let question: AgentQuestion
        let pass: AgentPass
        let expires: Date
    }

    private let preferences: Preferences
    private let passes: AgentPasses
    private let path: URL?
    private let peers: PeerCheck
    private let identifiers: [String]
    private let now: () -> Date
    /// How long Add Phone stands open. Five minutes unless a test is waiting.
    private let addWindow: TimeInterval
    private let accepting = DispatchQueue(label: "\(AppInfo.bundleID).phone.socket", qos: .userInitiated)

    /// Raises the card that names the phone. Nil for a card that could not
    /// come up, as with the lid shut or another question on it.
    var confirm: (_ name: String, _ fingerprint: String) async -> Bool? = { _, _ in nil }

    private var hasPass = false
    private var phone: SSHPhone?
    private var listening: DispatchSourceRead?
    private var registration: Instruments.Registration?
    private var connection: PhoneConnection?
    private var saidHello = false
    private var open: [String: Open] = [:]
    /// Every id that has had its answer, for as long as the app runs.
    private var spent: Set<String> = []
    private var adding: CheckedContinuation<Bool, Never>?
    private var addClock: Task<Void, Never>?
    private var watching: Set<AnyCancellable> = []

    init(preferences: Preferences, passes: AgentPasses, path: URL?, peers: PeerCheck = PeerCheck(),
         identifiers: [String] = PeerCheck.oriCode, now: @escaping () -> Date = Date.init, addWindow: TimeInterval = 300) {
        self.preferences = preferences
        self.passes = passes
        self.path = path
        self.peers = peers
        self.identifiers = identifiers
        self.now = now
        self.addWindow = addWindow
        phone = preferences.settings.ssh.phone
        // What is published is on its way in, so the value is taken from
        // what arrives and not read back.
        passes.$standing.sink { [weak self] standing in
            self?.hasPass = !standing.isEmpty
            self?.reconsider()
        }.store(in: &watching)
        preferences.$settings.map(\.ssh.phone).removeDuplicates().sink { [weak self] phone in
            self?.phone = phone
            self?.reconsider()
        }.store(in: &watching)
    }

    var hasPhone: Bool { phone != nil }
    var isOpen: Bool { listening != nil }

    /// A caller with no file, for a test.
    func adopt(_ descriptor: Int32) {
        let connection = PhoneConnection(descriptor: descriptor) { [weak self] line in self?.hear(line) }
        connection.onEnd = { [weak self, weak connection] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.lost(connection) } }
        }
        self.connection?.finish()
        self.connection = connection
        saidHello = false
        connection.start()
    }

    /// The app is going.
    func end() {
        stopWaiting(for: false)
        shut()
    }

    // MARK: The socket

    private func reconsider() {
        if adding != nil || (hasPass && hasPhone) { start() } else { shut() }
    }

    private func start() {
        guard let path, listening == nil else { return }
        do {
            let folder = path.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let listener = try BridgeServer.listener(at: path)
            let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: accepting)
            let peers = self.peers, identifiers = self.identifiers
            source.setEventHandler { [weak self] in
                while true {
                    let descriptor = Darwin.accept(listener, nil, nil)
                    guard descriptor >= 0 else { return }
                    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
                    _ = fcntl(descriptor, F_SETFL, 0)
                    // Before a byte is read.
                    guard identifiers.contains(where: { peers.signs(descriptor, as: $0) }) else {
                        close(descriptor)
                        continue
                    }
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.adopt(descriptor) } }
                }
            }
            source.setCancelHandler { close(listener) }
            source.resume()
            listening = source
            registration = Instruments.register("approve", kind: .observer, owner: "SSHAgent")
        } catch {
            Log.app.error("phone: did not open: \((error as NSError).code)")
        }
    }

    private func shut() {
        connection?.finish()
        connection = nil
        saidHello = false
        guard let listening else { return }
        listening.cancel()
        self.listening = nil
        registration = nil
        if let path { unlink(path.path) }
    }

    private func lost(_ gone: PhoneConnection?) {
        guard gone === connection else { return }
        connection = nil
        saidHello = false
    }

    // MARK: A request

    /// Goes down the socket now, or to the next connection to say hello.
    func ask(_ question: AgentQuestion, _ act: PhoneAct, key: AgentKey?, pass: AgentPass) {
        let expires = now().addingTimeInterval(question.patience)
        let request = PhoneRequest(id: UUID().uuidString.lowercased(), nonce: PhoneWire.nonce(), act: act,
                                   words: question.words, app: question.peer.appName,
                                   appID: question.peer.signer?.bundleID ?? "", key: key?.name ?? "",
                                   keyFingerprint: key?.fingerprint ?? "", host: question.destination ?? "",
                                   hostKey: question.host ?? "", expires: PhoneWire.time(expires))
        open[request.id] = Open(request: request, question: question, pass: pass, expires: expires)
        question.phoneRequest = request.id
        if saidHello { say(request.line) }
    }

    /// The card has gone, whoever took it down.
    func end(_ question: AgentQuestion, _ outcome: PhoneOutcome) {
        guard let id = question.phoneRequest, open.removeValue(forKey: id) != nil else { return }
        spent.insert(id)
        closed(id, outcome)
    }

    private func closed(_ id: String, _ outcome: PhoneOutcome, _ reason: PhoneRefusal? = nil) {
        var line: [String: Any] = ["type": "closed", "id": id, "outcome": outcome.rawValue]
        if let reason { line["reason"] = reason.rawValue }
        say(line)
    }

    private func refuse(_ code: String, id: String? = nil) {
        var line: [String: Any] = ["type": "error", "code": code]
        if let id { line["id"] = id }
        say(line)
    }

    private func say(_ line: [String: Any]) {
        var line = line
        line["v"] = PhoneWire.version
        guard let written = try? JSONSerialization.data(withJSONObject: line, options: [.withoutEscapingSlashes])
        else { return }
        connection?.say(written)
    }

    // MARK: What OriCode says

    private func hear(_ line: Data) {
        guard let said = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return refuse("bad-line")
        }
        let id = said["id"] as? String
        guard said["v"] as? Int == PhoneWire.version, let type = said["type"] as? String else {
            return refuse("unknown-type", id: id)
        }
        if type == "hello" { return hello() }
        guard saidHello else { return refuse("no-hello", id: id) }
        switch type {
        case "approve":
            guard let id else { return refuse("bad-line") }
            approve(id, signature: (said["signature"] as? String).flatMap { Data(base64Encoded: $0) })
        case "deny":
            guard let id else { return refuse("bad-line") }
            deny(id)
        case "register":
            Task { await self.register(said) }
        default:
            refuse("unknown-type", id: id)
        }
    }

    private func hello() {
        saidHello = true
        let shown: Any = phone.map { ["name": $0.name, "fingerprint": $0.fingerprint] } ?? NSNull()
        say(["type": "welcome", "phone": shown])
        open.values.sorted { $0.expires < $1.expires }.forEach { say($0.request.line) }
    }

    /// One answer for each request, right or wrong. One that does not hold
    /// shuts the phone's way in and leaves the card up for the finger.
    private func approve(_ id: String, signature: Data?) {
        guard let asked = open[id] else {
            return spent.contains(id) ? closed(id, .refused, .replay) : refuse("unknown-id", id: id)
        }
        open[id] = nil
        spent.insert(id)
        passes.sweep()
        if now() >= asked.expires { return closed(id, .refused, .expired) }
        guard passes.standing.contains(where: { $0 === asked.pass }) else { return closed(id, .refused, .noPass) }
        guard let phone, let signature,
              PhoneWire.verifies(signature, over: asked.request.message, by: phone.publicKey)
        else { return closed(id, .refused, .badSignature) }
        closed(id, .approved)
        asked.question.answeredByPhone()
    }

    private func deny(_ id: String) {
        guard let asked = open[id] else { return refuse("unknown-id", id: id) }
        asked.question.deny()
    }

    // MARK: Adding a phone

    /// True once a phone is registered. Stands for `addWindow` at most.
    func waitForPhone() async -> Bool {
        guard adding == nil else { return false }
        return await withCheckedContinuation { waiting in
            adding = waiting
            reconsider()
            addClock = Task { [addWindow] in
                try? await Task.sleep(nanoseconds: UInt64(addWindow * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.stopWaiting(for: false)
            }
        }
    }

    func stopWaiting(for found: Bool = false) {
        addClock?.cancel()
        addClock = nil
        adding?.resume(returning: found)
        adding = nil
        reconsider()
    }

    private func register(_ said: [String: Any]) async {
        guard adding != nil else { return refused("not-waiting") }
        guard let name = said["name"] as? String, !name.isEmpty, name.count <= PhoneWire.longestName,
              let publicKey = (said["publicKey"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let proof = (said["proof"] as? String).flatMap({ Data(base64Encoded: $0) }),
              PhoneWire.verifies(proof, over: PhoneWire.registration(name: name, publicKey: publicKey), by: publicKey)
        else { return refused("bad-proof") }
        guard let answer = await confirm(name, PhoneWire.fingerprint(of: publicKey)) else { return refused("busy") }
        guard answer else { return refused("denied") }
        let phone = SSHPhone(name: name, publicKey: publicKey)
        preferences.settings.ssh.phone = phone
        say(["type": "registered", "fingerprint": phone.fingerprint])
        stopWaiting(for: true)
    }

    private func refused(_ reason: String) {
        say(["type": "refused", "reason": reason])
    }
}
