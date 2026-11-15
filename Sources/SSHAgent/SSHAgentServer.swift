import Foundation

/// One caller on the socket, as `BridgeConnection` is one on the door: a
/// request at a time, each answered on the main actor and written from here.
/// A length over the cap closes it. A test hands it one end of a socketpair.
final class AgentConnection {
    typealias Answering = @MainActor (AgentRequest, AgentSession) async -> AgentAnswer

    /// It ended, whoever ended it. Called once.
    var onEnd: (() -> Void)?

    private let descriptor: Int32
    private let peer: AgentPeer
    private let answering: Answering
    private let queue = DispatchQueue(label: "\(AppInfo.bundleID).agent", qos: .userInitiated)
    private let lock = NSLock()
    private var isOver = false
    private var session: AgentSession?

    init(descriptor: Int32, peer: AgentPeer, answering: @escaping Answering) {
        self.descriptor = descriptor
        self.peer = peer
        self.answering = answering
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    func start() {
        queue.async { self.readNext() }
    }

    /// As `BridgeConnection.cut`: a read on another thread wakes, and an
    /// answer on its way finds the connection over.
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

    private func readNext() {
        guard let body = try? AgentWire.read(from: descriptor) else { return cut() }
        let peer = self.peer, answering = self.answering
        Task { @MainActor in
            let session = self.session ?? AgentSession(peer: peer)
            self.session = session
            let answer = await answering(AgentRequest(body), session)
            self.queue.async { self.write(answer) }
        }
    }

    private func write(_ answer: AgentAnswer) {
        guard !lock.withLock({ isOver }), (try? AgentWire.write(answer.body, to: descriptor)) != nil
        else { return cut() }
        readNext()
    }
}

/// The socket `ssh` talks to, in a folder of mode 0700 and itself 0600, from
/// `open` to `close`. Unlike the door for the browser it stands while the
/// vault is shut, and a lock cuts who is on it and leaves it there. Anyone
/// running as him may connect; what stands between them and a key is the
/// question (`SSHAgent`). `Instruments` counts it while it is open, since a
/// locked app holds it beside the hot keys (D18).
final class SSHAgentServer {
    private let path: URL?
    private let answering: AgentConnection.Answering
    private let queue = DispatchQueue(label: "\(AppInfo.bundleID).agent.socket", qos: .userInitiated)
    private let lock = NSLock()
    private var listening: DispatchSourceRead?
    private var registration: Instruments.Registration?
    private var connections: [ObjectIdentifier: AgentConnection] = [:]

    init(path: URL?, answering: @escaping AgentConnection.Answering) {
        self.path = path
        self.answering = answering
    }

    var isOpen: Bool { lock.withLock { listening != nil } }
    /// How many callers are connected now, for a test.
    var connected: Int { lock.withLock { connections.count } }

    func open() throws {
        guard let path, !isOpen else { return }
        let folder = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let listener = try BridgeServer.listener(at: path)
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(on: listener) }
        source.setCancelHandler { Darwin.close(listener) }
        source.resume()
        lock.withLock {
            listening = source
            registration = Instruments.register("listener", kind: .observer, owner: "SSHAgent")
        }
    }

    /// The listener shut, the file gone and every caller cut. It can be
    /// opened again.
    func close() {
        let source = lock.withLock { () -> DispatchSourceRead? in
            defer {
                listening = nil
                registration = nil
            }
            return listening
        }
        guard let source, let path else { return }
        source.cancel()
        unlink(path.path)
        cut()
    }

    /// Every caller cut, and the socket left standing for the next.
    func cut() {
        let callers = lock.withLock { () -> [AgentConnection] in
            defer { connections = [:] }
            return Array(connections.values)
        }
        callers.forEach { $0.cut() }
    }

    /// A caller on a descriptor that is the connection's from here on.
    /// `accept` is how one comes, and a socketpair in a test.
    func adopt(_ descriptor: Int32, peer: AgentPeer) {
        let connection = AgentConnection(descriptor: descriptor, peer: peer, answering: answering)
        let key = ObjectIdentifier(connection)
        lock.withLock { connections[key] = connection }
        connection.onEnd = { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.connections[key] = nil }
        }
        connection.start()
    }

    private func accept(on listener: Int32) {
        while true {
            let descriptor = Darwin.accept(listener, nil, nil)
            guard descriptor >= 0 else { return }
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            // Inherited from the listener, and a read here is meant to wait.
            _ = fcntl(descriptor, F_SETFL, 0)
            adopt(descriptor, peer: AgentPeer.of(descriptor))
        }
    }
}
