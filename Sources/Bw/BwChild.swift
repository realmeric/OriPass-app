import Foundation

/// `bw serve`, alive only while the vault is unlocked, and unable to outlive
/// this app.
///
/// It is started holding one end of a socketpair as descriptor 3, with
/// `--hostname fd+connected://3`, and serves that one connection and
/// nothing else: it listens nowhere and no socket file is made (D5). The
/// app keeps the other end (`ServeConnection`). When that end closes,
/// because of a lock, a quit, a crash or a `kill -9`, `bw` reads the end
/// of its only connection and exits by itself: the real one took two
/// seconds over it, with nothing watching (`docs/spikes/fd-2026-10.md`).
/// So there is no shell around it and no watcher beside it. When `bw`
/// exits on its own the kernel says so. Nothing polls for either
/// (`docs/notes.md`, "A child that outlives its parent").
final class BwChild {
    enum Failure: Error, Equatable {
        /// `bw` exited before it answered. The string is what it said on
        /// standard error: its own sentence, never a value.
        case exited(String)
        case notReady
    }

    /// The descriptor the child finds its end of the connection at.
    static let descriptor: Int32 = 3
    /// How long a child that was told to go is given before it is killed
    /// outright: a little over the two seconds the real one took by itself.
    static let grace: TimeInterval = 2.5

    /// The way to the child, from the moment it is started.
    private(set) var connection: ServeConnection?
    /// `bw` went away by itself, or its connection did, which is the same
    /// thing to whoever was asking. Called once, and not for a `stop()`.
    var onExit: (() -> Void)?

    private let binary: URL
    private let runDirectory: URL
    private let dataDirectory: URL
    private var spawned: pid_t?
    private var watch: DispatchSourceProcess?
    private var errors: FileHandle?
    private var said = Data()
    private var saidAll = false
    private var hasExited = false
    private var isReady = false
    private var isStopping = false
    private var wasHeard = false
    private let lock = NSLock()

    private var pidFile: URL { runDirectory.appendingPathComponent("child.pid") }

    /// `kill`, unless a test wants a child no signal reaches.
    private let signal: (pid_t, Int32) -> Void

    init(binary: URL, runDirectory: URL, dataDirectory: URL,
         signal: @escaping (pid_t, Int32) -> Void = { _ = kill($0, $1) }) {
        self.binary = binary
        self.runDirectory = runDirectory
        self.dataDirectory = dataDirectory
        self.signal = signal
    }

    /// The child's own pid, for as long as it is written down, which is as
    /// long as there is a child.
    var pid: pid_t? { Self.recorded(in: pidFile) }

    /// Returns once the child answers `/status` with anything, which is
    /// what ready means: that the process exists says nothing. The request
    /// is written at once and waits in the socket for `bw` to come up and
    /// read it.
    func start(readyWithin: TimeInterval = 30) async throws {
        try FileManager.default.createDirectory(
            at: runDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Made by an earlier version, or by hand, with other permissions.
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: runDirectory.path)
        Self.clearLeftovers(in: runDirectory)

        lock.withLock {
            said = Data()
            (saidAll, hasExited, isReady, isStopping, wasHeard) = (false, false, false, false, false)
        }
        let (connection, theirs) = try ServeConnection.pair()
        let born = Result { try spawn(holding: theirs) }
        // The child has its own copy now. While this one stayed open the
        // connection would never be seen to end.
        close(theirs)
        let child = try born.get()
        spawned = child
        self.connection = connection
        do {
            try "\(child)\n".write(to: pidFile, atomically: true, encoding: .utf8)
        } catch {
            await stop()
            throw error
        }

        let watch = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit,
                                                     queue: .global(qos: .userInitiated))
        watch.setEventHandler { [weak self] in self?.reap() }
        self.watch = watch
        watch.resume()
        // It may have gone before anything was watching.
        reap()

        // Any HTTP answer is the child being up, a refusal included. What
        // the answer says is for the first call that wants one: a `bw` that
        // turns this app away with a 403 is ready at once and says so there
        // (`VaultError.turnedAway`), where waiting for a 200 would spend the
        // whole thirty seconds and report a slow start.
        do {
            _ = try await ServeClient(connection: connection, deadline: readyWithin)
                .send("GET", "/status", body: nil, type: "")
        } catch VaultError.timeout {
            await stop()
            throw Failure.notReady
        } catch {
            // The connection ended under the question, which is `bw`
            // going. What it said on its way is the reason.
            let deadline = Date().addingTimeInterval(1)
            while !lock.withLock({ hasExited && saidAll }), Date() < deadline {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            let exited = lock.withLock { hasExited }
            let sentence = lock.withLock {
                String(decoding: said, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
            }
            await stop()
            throw exited ? Failure.exited(sentence) : Failure.notReady
        }
        connection.onLost = { [weak self] in self?.lost() }
        let goneAlready = lock.withLock { () -> Bool in
            isReady = true
            return hasExited
        }
        if goneAlready { hear() }
    }

    /// Closes this end and tells `bw` to go, waits a little over two
    /// seconds, and then kills it. Afterwards there is no process and no
    /// pid written down. A child that is still there after all of that,
    /// which none has been, keeps its pid in the file: it is what
    /// `clearLeftovers` would kill it by.
    ///
    /// Closing would be enough: the real one exits by itself two seconds
    /// after its connection ends. It is told as well because a lock should
    /// not leave the vault open in a process for two seconds more, or keep
    /// the lock screen waiting on them.
    func stop() async {
        lock.withLock { isStopping = true }
        connection?.shut()
        if let child = spawned {
            send(SIGTERM, to: child)
            var deadline = Date().addingTimeInterval(Self.grace)
            while isRunning, Date() < deadline {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            if isRunning {
                send(SIGKILL, to: child)
                deadline = Date().addingTimeInterval(Self.grace)
                while isRunning, Date() < deadline {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            }
            if isRunning {
                Log.app.error("a child outlived its kill: \(child)")
            } else {
                forget(child)
            }
        }
        connection = nil
    }

    // MARK: -

    /// `bw` itself, with no shell in between, holding the descriptor it is
    /// told to serve, `/dev/null` and a pipe for what it says, and nothing
    /// else this app has open.
    private func spawn(holding theirs: Int32) throws -> pid_t {
        var pipeEnds: [Int32] = [-1, -1]
        guard pipe(&pipeEnds) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        for end in pipeEnds { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        defer { close(pipeEnds[1]) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, pipeEnds[1], STDERR_FILENO)
        posix_spawn_file_actions_adddup2(&actions, theirs, Self.descriptor)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the four descriptors above reach the child, and no signal
        // comes to it blocked or ignored because it was here.
        var every = sigset_t(), none = sigset_t()
        sigfillset(&every)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &every)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
                                                    | POSIX_SPAWN_SETSIGMASK))

        // Nothing that opens the vault is in either list: every user on
        // the Mac can read a process's arguments, and every process of his
        // its environment. The password comes down the connection.
        let arguments = [binary.path, "serve", "--hostname", "fd+connected://\(Self.descriptor)"]
        let environment = BwBinary.environment(dataDirectory: dataDirectory)
            .map { "\($0.key)=\($0.value)" }
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer {
            for pointer in argv + envp { free(pointer) }
        }

        var child: pid_t = 0
        let failed = posix_spawn(&child, binary.path, &actions, &attributes, &argv, &envp)
        guard failed == 0 else {
            close(pipeEnds[0])
            throw POSIXError(POSIXErrorCode(rawValue: failed) ?? .EIO)
        }
        let errors = FileHandle(fileDescriptor: pipeEnds[0], closeOnDealloc: true)
        errors.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            guard let self else { return }
            self.lock.withLock {
                if data.isEmpty { self.saidAll = true }
                self.said = (self.said + data).suffix(4096)
            }
        }
        self.errors = errors
        return child
    }

    private var isRunning: Bool {
        reap()
        return !lock.withLock { hasExited }
    }

    /// Takes the child's exit from the kernel if it has one to give, and
    /// says so the first time when nobody here asked it to go.
    private func reap() {
        guard let child = spawned else { return }
        let justExited = lock.withLock { () -> Bool in
            guard !hasExited else { return false }
            var status: Int32 = 0
            guard waitpid(child, &status, WNOHANG) == child else { return false }
            hasExited = true
            return true
        }
        guard justExited else { return }
        watch?.cancel()
        forget(child)
        hear()
    }

    /// The connection ended under a request and this app did not end it:
    /// the child closed it, or never answered. Either way nothing more can
    /// be asked of that child, so it goes.
    private func lost() {
        hear()
        Task { await self.stop() }
    }

    /// `onExit`, once, for a child that was ready and was not stopped.
    private func hear() {
        let isNews = lock.withLock { () -> Bool in
            guard isReady, !isStopping, !wasHeard else { return false }
            wasHeard = true
            return true
        }
        if isNews { DispatchQueue.main.async { self.onExit?() } }
    }

    /// A signal to the child, unless its exit has been taken already and
    /// its number may be somebody else's.
    private func send(_ signal: Int32, to child: pid_t) {
        lock.withLock {
            if !hasExited { self.signal(child, signal) }
        }
    }

    /// The pid is written down for as long as there is a child and no
    /// longer. A later child's is left alone.
    private func forget(_ child: pid_t) {
        if Self.recorded(in: pidFile) == child { try? FileManager.default.removeItem(at: pidFile) }
    }

    private static func recorded(in pidFile: URL) -> pid_t? {
        (try? String(contentsOf: pidFile, encoding: .utf8))
            .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// The belt beside the braces, for a child that hangs when its
    /// connection ends, which no run has seen: as the app launches and
    /// before every start, a recorded pid is killed if it is still a `bw`
    /// serving a descriptor.
    /// A socket file is what a build from before D5 was rewritten left
    /// there, with a `bw` that named it, and both go the same way.
    static func clearLeftovers(in runDirectory: URL) {
        let pidFile = runDirectory.appendingPathComponent("child.pid")
        let socket = runDirectory.appendingPathComponent("serve.sock").path
        if let pid = recorded(in: pidFile), let arguments = ProcessArguments.of(pid),
           arguments.contains("serve"),
           arguments.contains("fd+connected://\(descriptor)") || arguments.contains("unix://\(socket)") {
            kill(pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: pidFile)
        try? FileManager.default.removeItem(atPath: socket)
    }
}

/// Another process's arguments, which is how a pid in a file is known to
/// still be the `bw` that wrote it and not whoever was given the number next.
enum ProcessArguments {
    static func of(_ pid: pid_t) -> [String]? {
        var name = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&name, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let count = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        // The count, the executable's path, padding, then the arguments,
        // each ended by a zero byte.
        var strings = buffer[MemoryLayout<Int32>.size..<size].split(
            separator: 0, omittingEmptySubsequences: true
        ).map { String(decoding: $0, as: UTF8.self) }
        guard !strings.isEmpty else { return nil }
        strings.removeFirst()
        return Array(strings.prefix(Int(count)))
    }
}
