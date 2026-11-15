import Foundation

/// Have I Been Pwned's password range endpoint, which this app asks about
/// five characters of a hash and nothing else (D13, D14). No key and no
/// account. `Add-Padding` has the server pad its answer, so the length of
/// what comes back says nothing of the five. Cookies, a cache and
/// credentials are off.
///
/// It lives as long as the app and its session as long as an unlock: the
/// first request after one makes the session, and `end` is
/// `invalidateAndCancel`, so no connection stays open behind the lock
/// screen.
final class PwnedRange: BreachFetcher, @unchecked Sendable {
    static let host = "api.pwnedpasswords.com"
    /// A range of the commonest five was 82 KB on 2026-10-09.
    static let largest = 1024 * 1024

    let base: URL
    private let makeSession: () -> URLSession
    /// Held around the session and the making of a task, because a task
    /// made in a session that has been invalidated is an exception.
    private let lock = NSLock()
    private var session: URLSession?

    init(base: URL = URL(string: "https://\(PwnedRange.host)")!,
         session: @escaping () -> URLSession = { URLSession(configuration: PwnedRange.configuration) }) {
        self.base = base
        makeSession = session
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

    func request(for prefix: String) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("range").appendingPathComponent(prefix))
        request.setValue("true", forHTTPHeaderField: "Add-Padding")
        request.timeoutInterval = 15
        return request
    }

    func fetch(prefix: String) async -> BreachAnswer {
        // Nothing longer than the five ever goes into a path.
        guard BreachMark.isPrefix(prefix) else { return .failed }
        let running = Running()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let task = begin(request(for: prefix)) { continuation.resume(returning: $0) }
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
        session?.invalidateAndCancel()
        session = nil
    }

    private func begin(_ request: URLRequest, done: @escaping @Sendable (BreachAnswer) -> Void) -> URLSessionDataTask {
        lock.lock()
        defer { lock.unlock() }
        let session = self.session ?? makeSession()
        self.session = session
        let stays = StaysPut()
        let task = session.dataTask(with: request) { data, response, _ in
            guard !stays.wasSentOn, let data, (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count <= Self.largest else { return done(.failed) }
            done(.body(data))
        }
        task.delegate = stays
        return task
    }

    /// D14 names one host. A 3xx from it would send five characters of a
    /// hash to whichever host the answer names, so no redirect is taken.
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
