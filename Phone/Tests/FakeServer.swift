import Foundation
@testable import OriPass

/// Bitwarden's server for a test, as a URLProtocol in the test's own
/// session: the invented account in vault.json, answered the way
/// scripts/standin.py answers it, with no network.
final class FakeServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var twoFactor = false
    nonisolated(unsafe) static var newDevice = false
    nonisolated(unsafe) static var revision = 1_760_954_400_000
    /// Every request seen, as its path and its form or JSON body.
    nonisolated(unsafe) static var seen: [(path: String, body: String)] = []
    nonisolated(unsafe) static var vault: [String: Any] = try! Fixture.json("vault.json")
    /// The ciphers as the writes left them, until the next reset.
    nonisolated(unsafe) static var ciphers: [[String: Any]]?
    /// Set to refuse the next edit as made from an older copy.
    nonisolated(unsafe) static var stale = false

    static let server = Server.own(URL(string: "https://standin.invalid")!)

    static func reset() {
        twoFactor = false
        newDevice = false
        seen = []
        ciphers = nil
        stale = false
    }

    static func client() -> Client {
        Client(server: server, protocolClasses: [FakeServer.self])
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url!.path()
        let body = String(data: bodyData(), encoding: .utf8) ?? ""
        FakeServer.seen.append((path, body))
        let (status, json) = answer(path: path, body: body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json, options: .fragmentsAllowed))
        client?.urlProtocolDidFinishLoading(self)
    }

    private func answer(path: String, body: String) -> (Int, Any) {
        let vault = FakeServer.vault
        let account = vault["account"] as! [String: Any]
        switch path {
        case "/identity/accounts/prelogin/password":
            return (200, vault["prelogin"]!)
        case "/identity/connect/token" where FakeServer.form(body)["grant_type"] == "refresh_token":
            guard FakeServer.form(body)["refresh_token"] == "kanarya-refresh" else { return (400, ["error": "invalid_grant"]) }
            return (200, ["access_token": "kanarya-access", "refresh_token": "kanarya-refresh", "expires_in": 3600])
        case "/identity/connect/token":
            let form = FakeServer.form(body)
            guard form["username"] == account["email"] as? String, form["password"] == account["serverHash"] as? String else {
                return (400, ["error": "invalid_grant", "ErrorModel": ["Message": "Username or password is incorrect. Try again."]])
            }
            if FakeServer.twoFactor && form["twoFactorToken"] != "123456" {
                return (400, ["error": "invalid_grant", "TwoFactorProviders2": ["0": NSNull()],
                              "ErrorModel": ["Message": "Two-step token is invalid. Try again."]])
            }
            if FakeServer.newDevice && form["newdeviceotp"] != "654321" {
                return (400, ["error": "device_error", "ErrorModel": ["Message": "new device verification required"]])
            }
            var token = vault["token"] as! [String: Any]
            token["access_token"] = "kanarya-access"
            token["refresh_token"] = "kanarya-refresh"
            token["expires_in"] = 3600
            return (200, token)
        case "/api/accounts/revision-date":
            return (200, FakeServer.revision)
        case "/api/sync":
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer kanarya-access" else {
                return (401, ["message": "Unauthorized"])
            }
            guard let ciphers = FakeServer.ciphers else { return (200, vault["sync"]!) }
            var sync = vault["sync"] as! [String: Any]
            sync["ciphers"] = ciphers
            return (200, sync)
        case "/api/ciphers" where request.httpMethod == "POST":
            return write(body, to: nil)
        case _ where path.hasPrefix("/api/ciphers/") && request.httpMethod == "PUT":
            return write(body, to: String(path.dropFirst("/api/ciphers/".count)))
        default:
            return (404, ["message": "Not found"])
        }
    }

    /// A write as the stand-in takes one: the fields it sends, on the cipher
    /// with that id or on a new one, and a new revision.
    private func write(_ body: String, to id: String?) -> (Int, Any) {
        if FakeServer.stale {
            FakeServer.stale = false
            return (400, ["message": "The cipher you are updating is out of date. Please save your work, sync your vault, and try again."])
        }
        var ciphers = FakeServer.ciphers ?? (FakeServer.vault["sync"] as! [String: Any])["ciphers"] as! [[String: Any]]
        let sent = try! JSONSerialization.jsonObject(with: Data(body.utf8)) as! [String: Any]
        let index = id.flatMap { id in ciphers.firstIndex { $0["id"] as? String == id } }
        var cipher = index.map { ciphers[$0] } ?? ["id": UUID().uuidString.lowercased(), "object": "cipherDetails"]
        cipher.merge(sent.filter { $0.key != "lastKnownRevisionDate" }) { $1 }
        cipher["revisionDate"] = "2026-10-30T12:00:00.000Z"
        if let index { ciphers[index] = cipher } else { ciphers.append(cipher) }
        FakeServer.ciphers = ciphers
        FakeServer.revision += 1
        return (200, cipher)
    }

    static func form(_ body: String) -> [String: String] {
        var form: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
            if parts.count == 2 { form[parts[0]] = parts[1] }
        }
        return form
    }

    private func bodyData() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
