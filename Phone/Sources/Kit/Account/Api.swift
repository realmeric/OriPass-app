import Foundation

/// The API with the account's tokens: refreshed before they run out and
/// once more on a 401, and kept in the keychain each time they change.
actor Api {
    enum Failure: Error, Equatable {
        /// The refresh token was refused: signed out somewhere, or expired.
        case signedOut
        case unreachable
        case status(Int, String?)
    }

    let client: Client
    private var tokens: Tokens
    private let keychain: Keychain

    init(client: Client, tokens: Tokens, keychain: Keychain = .app) {
        self.client = client
        self.tokens = tokens
        self.keychain = keychain
    }

    func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await call(path, method: "GET", query: query, json: nil)
    }

    func send(_ path: String, method: String, json: Data?) async throws -> Data {
        try await call(path, method: method, query: [], json: json)
    }

    private func call(_ path: String, method: String, query: [URLQueryItem], json: Data?) async throws -> Data {
        var url = client.server.api.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        if tokens.isStale { try await refresh() }
        var answer = try await attempt(url, method, json)
        if answer.status == 401 {
            try await refresh()
            answer = try await attempt(url, method, json)
        }
        guard answer.ok else { throw Failure.status(answer.status, Client.sentence(in: answer.json)) }
        return answer.body
    }

    private func attempt(_ url: URL, _ method: String, _ json: Data?) async throws -> Client.Answer {
        do {
            return try await client.send(url, method: method, json: json, token: tokens.access)
        } catch {
            throw Failure.unreachable
        }
    }

    private func refresh() async throws {
        let answer: Client.Answer
        do {
            answer = try await client.send(client.server.identity.appending(path: "connect/token"), method: "POST",
                                           form: ["grant_type": "refresh_token", "client_id": "mobile",
                                                  "refresh_token": tokens.refresh])
        } catch {
            throw Failure.unreachable
        }
        guard answer.ok, let json = answer.json, let access = json["access_token"] as? String else {
            throw answer.status == 400 || answer.status == 401 ? Failure.signedOut : Failure.status(answer.status, nil)
        }
        tokens = Tokens(access: access, refresh: json["refresh_token"] as? String ?? tokens.refresh,
                        expires: Date(timeIntervalSinceNow: json["expires_in"] as? Double ?? 3600))
        try? tokens.store(in: keychain)
    }
}
