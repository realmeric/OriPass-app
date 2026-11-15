import Foundation

/// The vault as the server last sent it, encrypted, in the App Group where
/// the extension reads it. It opens after the first unlock since boot, so
/// that a sync in the background can write it.
enum VaultFile {
    static var url: URL? { Shared.container?.appending(path: "vault.json") }

    static func read() -> Data? {
        url.flatMap { try? Data(contentsOf: $0) }
    }

    static func write(_ data: Data) throws {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func forget() {
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    /// The sync's answer, checked to be one before it is written over the
    /// last: an answer that does not decode leaves the file as it was.
    static func sync(with api: Api) async throws -> Data {
        let data = try await api.get("sync", query: [URLQueryItem(name: "excludeDomains", value: "true")])
        _ = try Cipher.decoder.decode(SyncAnswer.self, from: data)
        try write(data)
        return data
    }

    /// A sync only when the account changed since the last one: the
    /// account's revision date is asked first, a few bytes, and the vault is
    /// downloaded only when it moved. Nil when nothing did.
    static func syncIfChanged(with api: Api, defaults: UserDefaults? = UserDefaults(suiteName: Shared.appGroup)) async throws -> Data? {
        let answer = try await api.get("accounts/revision-date")
        let revision = String(data: answer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let revision, revision == defaults?.string(forKey: "revision"), read() != nil { return nil }
        let data = try await sync(with: api)
        defaults?.set(revision, forKey: "revision")
        defaults?.set(Date.now, forKey: "synced")
        return data
    }

    static func lastSynced(defaults: UserDefaults? = UserDefaults(suiteName: Shared.appGroup)) -> Date? {
        defaults?.object(forKey: "synced") as? Date
    }
}

/// The sync iOS lets run while the app is in the background: the encrypted
/// vault downloaded, and the identity store written again at the next
/// unlock from what arrived (I6), since nothing here can open it.
enum BackgroundSync {
    static let identifier = "com.meric.oripass.ios.sync"

    static func run() async -> Bool {
        guard let account = Account.stored(), let tokens = Tokens.stored() else { return false }
        return await run(with: Api(client: Client(server: account.server), tokens: tokens))
    }

    static func run(with api: Api, defaults: UserDefaults? = UserDefaults(suiteName: Shared.appGroup)) async -> Bool {
        do {
            let data = try await VaultFile.syncIfChanged(with: api, defaults: defaults)
            Trace.note("background sync \(data == nil ? "found nothing new" : "wrote the vault")")
            return true
        } catch {
            Trace.note("background sync failed: \(error)")
            return false
        }
    }
}
