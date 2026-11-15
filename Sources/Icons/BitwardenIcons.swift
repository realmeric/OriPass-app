import CryptoKit
import Foundation

/// Bitwarden's icon server, which this app asks about the host of a login's
/// first address and nothing else (D14). Cookies, a cache and credentials are
/// all off: the request is a path and nothing it could be recognised by.
///
/// The session lives as long as the `IconStore` that holds this, which is as
/// long as the vault is open. Of the two ways to have nothing running behind
/// a lock, this is the one that also shuts the connection: `end` is
/// `invalidateAndCancel`, where a shared session whose tasks were cancelled
/// would keep an idle connection to the server open under the lock screen.
/// The next unlock makes its own.
final class BitwardenIcons: IconFetcher, @unchecked Sendable {
    /// Measured 2026-10-08: the server answers 200 for a host it knows nothing
    /// about, with the same 19 by 19 globe every time. This is its SHA-256,
    /// and an answer that matches it is "no icon" (`docs/notes.md`).
    static let globeDigest = "aaa64871332ad5b7d28fe8874efb19c2d9cc2f1e6de75d52b080b438225a0783"
    static let largest = 512 * 1024

    let base: URL
    private let session: URLSession
    /// Held around `hasEnded` and the making of a task, because a task made
    /// in a session that has been invalidated is an exception.
    private let lock = NSLock()
    private var hasEnded = false

    /// The one host D14 names.
    static let host = "icons.bitwarden.net"

    init(base: URL = URL(string: "https://\(BitwardenIcons.host)")!, session: URLSession? = nil) {
        self.base = base
        self.session = session ?? URLSession(configuration: Self.configuration)
    }

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    func url(for host: String) -> URL {
        base.appendingPathComponent(host).appendingPathComponent("icon.png")
    }

    func fetch(host: String) async -> IconAnswer {
        var request = URLRequest(url: url(for: host))
        request.timeoutInterval = 15
        let running = Running()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let task = begin(request) { continuation.resume(returning: $0) }
                guard let task else {
                    continuation.resume(returning: .failed)
                    return
                }
                running.hold(task)
                task.resume()
            }
        } onCancel: {
            running.cancel()
        }
    }

    func end() {
        lock.lock()
        defer { lock.unlock() }
        guard !hasEnded else { return }
        hasEnded = true
        session.invalidateAndCancel()
    }

    /// Nil once the session has ended.
    private func begin(_ request: URLRequest,
                       done: @escaping @Sendable (IconAnswer) -> Void) -> URLSessionDataTask? {
        lock.lock()
        defer { lock.unlock() }
        guard !hasEnded else { return nil }
        let stays = StaysPut()
        // A redirect is "no icon": the server sent this app somewhere else,
        // and it will send it there tomorrow too.
        let task = session.dataTask(with: request) { data, response, _ in
            done(stays.wasSentOn ? .none : Self.sort(data, response))
        }
        task.delegate = stays
        return task
    }

    private static func sort(_ data: Data?, _ response: URLResponse?) -> IconAnswer {
        guard let data, let http = response as? HTTPURLResponse else { return .failed }
        switch http.statusCode {
        case 200:
            guard !data.isEmpty, data.count <= largest else { return .none }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return digest == globeDigest ? .none : .image(data)
        case 404:
            return .none
        default:
            return .failed
        }
    }

    /// D14 names one host. A 3xx from it would have this app ask whichever
    /// host the answer names, so no redirect is taken. One to a task, and
    /// it remembers having been asked: what a refused redirect leaves in the
    /// task's own answer is not something to sort by.
    private final class StaysPut: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var sentOn = false

        var wasSentOn: Bool {
            lock.lock()
            defer { lock.unlock() }
            return sentOn
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            lock.lock()
            sentOn = true
            lock.unlock()
            completionHandler(nil)
        }
    }

    /// The task of one `fetch`, so that cancelling the fetch cancels it,
    /// whichever of the two comes first.
    private final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var isCancelled = false

        func hold(_ task: URLSessionDataTask) {
            lock.lock()
            self.task = task
            let cancelled = isCancelled
            lock.unlock()
            if cancelled { task.cancel() }
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }
}
