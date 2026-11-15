import Foundation

/// One caller, one connection: `hello`, and then a request at a time, each
/// answered on the main actor and written from here. Anything the wire does
/// not have closes it. A test hands it one end of a socketpair and is a
/// caller with no file and no peer check.
final class BridgeConnection {
    typealias Answering = @MainActor (BridgeRequest, BridgeCaller) async -> BridgeAnswer

    /// It ended, whoever ended it. Called once.
    var onEnd: (() -> Void)?

    private let descriptor: Int32
    private let caller: BridgeCaller
    private let answering: Answering
    private let queue = DispatchQueue(label: "\(AppInfo.bundleID).bridge", qos: .userInitiated)
    private let lock = NSLock()
    private var isOver = false
    private var hasSaidHello = false

    init(descriptor: Int32, caller: BridgeCaller, answering: @escaping Answering) {
        self.descriptor = descriptor
        self.caller = caller
        self.answering = answering
        // A peer that has gone must be an error here, not a signal that
        // kills the app.
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    func start() {
        queue.async { self.readNext() }
    }

    /// Wakes a read on another thread, which a close would not, and an
    /// answer on its way finds the connection over. The descriptor is
    /// closed when this is let go of, so its number is nobody else's while
    /// a read may still hold it.
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
        var body = (try? BridgeWire.read(from: descriptor)) ?? Data()
        defer { body.resetBytes(in: 0..<body.count) }
        guard let request = BridgeRequest(body), isExpected(request) else { return cut() }
        let caller = self.caller, answering = self.answering
        Task { @MainActor in
            let answer = await answering(request, caller)
            self.queue.async { self.write(answer) }
        }
    }

    /// `hello` first, and once.
    private func isExpected(_ request: BridgeRequest) -> Bool {
        if case .hello = request {
            defer { hasSaidHello = true }
            return !hasSaidHello
        }
        return hasSaidHello
    }

    private func write(_ answer: BridgeAnswer) {
        var body = answer.body
        defer { body.resetBytes(in: 0..<body.count) }
        guard !lock.withLock({ isOver }), (try? BridgeWire.write(body, to: descriptor)) != nil,
              answer.keepsConnection
        else { return cut() }
        readNext()
    }
}

/// The door for the browser: a Unix socket that exists between `open` and
/// `cut`. Whoever connects is asked who they are of the system (`PeerCheck`)
/// before a byte of theirs is read, and anyone else is closed on. `Instruments`
/// counts it while it is open, which `BrowserDoor` has it be only while the
/// store is unlocked (D18).
final class BridgeServer {
    private let path: URL
    private let peers: PeerCheck
    private let answering: BridgeConnection.Answering
    private let queue = DispatchQueue(label: "\(AppInfo.bundleID).door", qos: .userInitiated)
    private let lock = NSLock()
    private var listening: DispatchSourceRead?
    private var registration: Instruments.Registration?
    private var connections: [ObjectIdentifier: BridgeConnection] = [:]

    init(path: URL, peers: PeerCheck = PeerCheck(), answering: @escaping BridgeConnection.Answering) {
        self.path = path
        self.peers = peers
        self.answering = answering
    }

    var isOpen: Bool { lock.withLock { listening != nil } }
    /// How many callers are connected now, for a test.
    var connected: Int { lock.withLock { connections.count } }

    func open() throws {
        guard !isOpen else { return }
        let listener = try Self.listener(at: path)
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(on: listener) }
        source.setCancelHandler { close(listener) }
        source.resume()
        lock.withLock {
            listening = source
            registration = Instruments.register("door", kind: .observer, owner: "Bridge")
        }
    }

    /// The listener shut, the file gone and every caller cut, in the turn
    /// it is called. It can be opened again.
    func cut() {
        let (source, callers) = lock.withLock { () -> (DispatchSourceRead?, [BridgeConnection]) in
            defer {
                listening = nil
                registration = nil
                connections = [:]
            }
            return (listening, Array(connections.values))
        }
        guard let source else { return }
        source.cancel()
        unlink(path.path)
        callers.forEach { $0.cut() }
    }

    /// A socket listening at `path`, for this user alone. It takes the path
    /// from whatever is left there: a run that was killed leaves its file,
    /// and nothing answers at it.
    static func listener(at path: URL) throws -> Int32 {
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw failure }
        _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
        _ = fcntl(listener, F_SETFL, O_NONBLOCK)
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: path)
            try bind(listener, to: path)
            // Nobody can connect before `listen`, so nobody finds it open.
            guard chmod(path.path, 0o600) == 0, listen(listener, SOMAXCONN) == 0 else { throw failure }
        } catch {
            close(listener)
            throw error
        }
        return listener
    }

    private static func bind(_ listener: Int32, to path: URL) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let written = Array(path.path.utf8CString).map { UInt8(bitPattern: $0) }
        let room = MemoryLayout.size(ofValue: address.sun_path)
        guard written.count <= room else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: written) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw failure }
    }

    private func accept(on listener: Int32) {
        while true {
            let descriptor = Darwin.accept(listener, nil, nil)
            guard descriptor >= 0 else { return }
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            // Inherited from the listener, and a read here is meant to wait.
            _ = fcntl(descriptor, F_SETFL, 0)
            guard let caller = peers.caller(on: descriptor) else {
                Log.app.info("bridge: closed on a caller of no standing")
                close(descriptor)
                continue
            }
            adopt(BridgeConnection(descriptor: descriptor, caller: caller, answering: answering))
        }
    }

    private func adopt(_ connection: BridgeConnection) {
        let key = ObjectIdentifier(connection)
        let isOpen = lock.withLock { () -> Bool in
            if listening != nil { connections[key] = connection }
            return listening != nil
        }
        guard isOpen else { return connection.cut() }
        connection.onEnd = { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.connections[key] = nil }
        }
        connection.start()
    }

    private static var failure: POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
