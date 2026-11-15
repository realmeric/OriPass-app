import Foundation

/// The app's end of the socketpair a `bw serve` was born holding the other
/// end of (D5). It is the only way to that child there is: no file, no
/// listener, nothing another process could connect to, and no second
/// connection to open when this one is busy.
///
/// So requests go one at a time, each after the last one's answer, in the
/// order they were made. Two written before the first was answered were
/// never tried on the real `bw` (`docs/spikes/fd-2026-10.md`). An answer is
/// read by its length or its chunks, since the end of one is no longer the
/// end of the connection.
///
/// A request that is not answered whole leaves the connection of no use:
/// the answer that comes late would be read as the next request's. It is
/// shut there and then, every request waiting behind it fails, and
/// `onLost` says so once.
final class ServeConnection {
    enum Failure: Error, Equatable {
        case timedOut
        /// The other end closed, or this one was shut.
        case hungUp
    }

    /// The connection ended and nobody here shut it. Called once, on the
    /// connection's own queue.
    var onLost: (() -> Void)?

    private let descriptor: Int32
    private let queue = DispatchQueue(label: "\(AppInfo.bundleID).serve", qos: .userInitiated)
    private let lock = NSLock()
    private var isShut = false
    private var isOver = false

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// A connected pair: this app's end, and the descriptor the child is
    /// to be handed, which the caller closes once the child has it. Neither
    /// is inherited by any other process this app starts.
    static func pair() throws -> (ours: ServeConnection, theirs: Int32) {
        var ends: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        for end in ends { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        // A peer that has gone must be an error here, not a signal that
        // kills the app.
        var on: Int32 = 1
        setsockopt(ends[0], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return (ServeConnection(descriptor: ends[0]), ends[1])
    }

    /// One request written and its answer read, after every exchange asked
    /// for before it. The deadline starts when its turn comes.
    func exchange(_ request: SecretBytes, deadline: TimeInterval) async throws -> ServeClient.Response {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.exchangeNow(request, deadline: deadline) })
            }
        }
    }

    /// Shuts the connection, which the child reads as the end of its life.
    /// An exchange under way fails at once, and nothing is said of it:
    /// this is the app's own doing.
    func shut() {
        let wasShut = lock.withLock { () -> Bool in
            defer { isShut = true }
            return isShut
        }
        guard !wasShut else { return }
        // Wakes a read on another thread, which a close would not. The
        // descriptor itself is closed when this is let go of, so its number
        // is nobody else's while a read may still hold it.
        shutdown(descriptor, SHUT_RDWR)
    }

    deinit {
        close(descriptor)
    }

    // MARK: -

    private func exchangeNow(_ request: SecretBytes, deadline: TimeInterval) throws -> ServeClient.Response {
        guard !lock.withLock({ isShut || isOver }) else { throw Failure.hungUp }
        do {
            return try request.withBytes { try exchangeNow($0, deadline: deadline) }
        } catch {
            end()
            throw error
        }
    }

    private func exchangeNow(_ request: UnsafeRawBufferPointer,
                             deadline: TimeInterval) throws -> ServeClient.Response {
        let started = Date()
        var remaining: TimeInterval { deadline - Date().timeIntervalSince(started) }

        try setTimeout(SO_SNDTIMEO, remaining)
        var sent = 0
        while sent < request.count {
            let wrote = write(descriptor, request.baseAddress! + sent, request.count - sent)
            if wrote < 0, errno == EINTR { continue }
            guard wrote > 0 else { throw errno == EAGAIN ? Failure.timedOut : Failure.hungUp }
            sent += wrote
            try setTimeout(SO_SNDTIMEO, remaining)
        }

        var read = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try setTimeout(SO_RCVTIMEO, remaining)
            let got = Darwin.read(descriptor, &buffer, buffer.count)
            if got < 0, errno == EINTR { continue }
            if got == 0 {
                // An answer with no length and no chunks ends where the
                // connection does, which is then of no more use.
                guard let whole = try ServeClient.answer(in: read, isAll: true) else { throw Failure.hungUp }
                end()
                return whole.response
            }
            guard got > 0 else { throw errno == EAGAIN ? Failure.timedOut : Failure.hungUp }
            read.append(buffer, count: got)
            if let whole = try ServeClient.answer(in: read, isAll: false) {
                // Nothing was asked that these could be the answer to.
                guard whole.length == read.count else { throw Failure.hungUp }
                return whole.response
            }
        }
    }

    /// Of no more use. Says so once, unless it was shut from here.
    private func end() {
        let (first, wasShut) = lock.withLock { () -> (Bool, Bool) in
            defer { isOver = true }
            return (!isOver, isShut)
        }
        guard first else { return }
        shutdown(descriptor, SHUT_RDWR)
        if !wasShut { onLost?() }
    }

    private func setTimeout(_ option: Int32, _ seconds: TimeInterval) throws {
        guard seconds > 0 else { throw Failure.timedOut }
        var time = timeval(tv_sec: Int(seconds),
                           tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
        setsockopt(descriptor, SOL_SOCKET, option, &time, socklen_t(MemoryLayout<timeval>.size))
    }
}
