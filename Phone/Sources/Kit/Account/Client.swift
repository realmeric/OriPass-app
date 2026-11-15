import Foundation

/// Bitwarden's servers over one session that keeps no cache and no cookies.
/// It knows the headers Bitwarden's iPhone app sends and how an answer is
/// read, and nothing of the vault.
final class Client: Sendable {
    /// The Bitwarden version whose protocol this follows. The server decides
    /// some things by it, so it is theirs and not this app's.
    static let bitwardenVersion = "2026.10.0"

    let server: Server
    private let session: URLSession

    init(server: Server, protocolClasses: [AnyClass]? = nil) {
        self.server = server
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration)
    }

    struct Answer: Sendable {
        let status: Int
        let body: Data

        var json: [String: Any]? { try? JSONSerialization.jsonObject(with: body) as? [String: Any] }
        var ok: Bool { (200..<300).contains(status) }
    }

    func send(_ url: URL, method: String = "GET", json: Data? = nil, form: [String: String]? = nil,
              token: String? = nil) async throws -> Answer {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("mobile", forHTTPHeaderField: "Bitwarden-Client-Name")
        request.setValue(Client.bitwardenVersion, forHTTPHeaderField: "Bitwarden-Client-Version")
        request.setValue("1", forHTTPHeaderField: "Device-Type")
        request.setValue("OriPass/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") (iOS)",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = json
        } else if let form {
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(Client.formEncoded(form).utf8)
        }
        let (body, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Log.net.info("\(method, privacy: .public) \(url.path(), privacy: .public) \(status)")
        return Answer(status: status, body: body)
    }

    static func formEncoded(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }

    /// The sentence a refusal carries, in the shapes the identity and the
    /// API use, or nil.
    static func sentence(in json: [String: Any]?) -> String? {
        guard let json else { return nil }
        let model = (json["ErrorModel"] ?? json["errorModel"]) as? [String: Any]
        let text = (model?["Message"] ?? model?["message"] ?? json["message"] ?? json["Message"] ?? json["error_description"]) as? String
        return text?.isEmpty == false ? text : nil
    }
}
