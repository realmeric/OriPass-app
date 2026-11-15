import Foundation

/// Where the list comes from. The one real source is `TwoFactorDirectory`;
/// a test and the demo have their own, so nothing under test reaches a
/// network.
protocol TwoFactorSource: Sendable {
    /// The file as it came, or nil when the network or the server failed.
    func fetch() async -> Data?
    /// The vault is shut: whatever was open towards a server is shut too.
    func end()
}

extension TwoFactorSource {
    func end() {}
}

/// 2fa.directory's file of the sites that take a one-time code (D13, D14).
/// One GET of a public file, with nothing in it that is his: no query, no
/// cookie, no credential, no body. The same file goes to everybody, so the
/// request says only that this Mac has the app, and when the switch is on.
///
/// Its session is made by the first request after an unlock and ended by
/// `end`, as `PwnedRange`'s is.
final class TwoFactorDirectory: TwoFactorSource, @unchecked Sendable {
    static let host = "api.2fa.directory"
    /// The file was 236 KB on 2026-10-09.
    static let largest = 8 * 1024 * 1024

    let url: URL
    /// How long a request may take; the file is a quarter of a megabyte.
    let patience: TimeInterval
    private let makeSession: () -> URLSession
    private let lock = NSLock()
    private var session: URLSession?

    init(url: URL = URL(string: "https://\(TwoFactorDirectory.host)/v4/totp.json")!, patience: TimeInterval = 30,
         session: @escaping () -> URLSession = { URLSession(configuration: TwoFactorDirectory.configuration) }) {
        self.url = url
        self.patience = patience
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

    var request: URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = patience
        return request
    }

    func fetch() async -> Data? {
        guard let session = current() else { return nil }
        do {
            let (data, response) = try await session.data(for: request, delegate: StaysPut())
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= Self.largest else { return nil }
            return data
        } catch {
            return nil
        }
    }

    func end() {
        lock.lock()
        defer { lock.unlock() }
        session?.invalidateAndCancel()
        session = nil
    }

    /// Held around the session, because a task made in one that has been
    /// invalidated is an exception.
    private func current() -> URLSession? {
        lock.lock()
        defer { lock.unlock() }
        let session = self.session ?? makeSession()
        self.session = session
        return session
    }

    /// D14 names one host. A 3xx would send the request wherever the answer
    /// says, so none is taken, and its status is not a 200.
    private final class StaysPut: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
