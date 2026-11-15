import Foundation

/// The signed-in account, as much of it as the phone keeps outside the
/// keychain: who, where, how its master key is made, and the user key
/// sealed under that master key as the server keeps it, so a password can
/// open the vault with no network. Nothing in it opens anything alone.
struct Account: Codable, Equatable, Sendable {
    var email: String
    var server: Server
    var kdf: Kdf
    /// The user key under the stretched master key: an encrypted string.
    var protectedUserKey: String

    private static var file: URL? { Shared.container?.appending(path: "account.json") }

    static func stored() -> Account? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Account.self, from: data)
    }

    func store() throws {
        guard let file = Account.file else { throw CocoaError(.fileNoSuchFile) }
        try JSONEncoder().encode(self).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func forget() {
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    /// The user key from the master password, as a password unlock does it.
    func userKey(password: SecretBytes) throws -> VaultKey {
        let master = try kdf.masterKey(password: password, email: email)
        return try VaultKey(EncString(protectedUserKey).decrypt(with: Kdf.stretch(master)))
    }
}

/// The two tokens the API takes, in the keychain after the first unlock
/// since boot. They read the encrypted vault and can delete items from the
/// account; they decrypt nothing.
struct Tokens: Codable, Equatable, Sendable, Redacted {
    var access: String
    var refresh: String
    var expires: Date

    var redactedLabel: String { "Tokens" }

    static func stored(in keychain: Keychain = .app) -> Tokens? {
        guard let data = try? keychain.read("tokens") else { return nil }
        return try? JSONDecoder().decode(Tokens.self, from: data)
    }

    func store(in keychain: Keychain = .app) throws {
        try keychain.write(JSONEncoder().encode(self), as: "tokens")
    }

    /// Due a refresh a minute before they run out.
    var isStale: Bool { expires.timeIntervalSinceNow < 60 }
}

/// The id the server knows this install by, kept in the keychain so that a
/// reinstall is not a new device that wants an emailed code.
enum Device {
    static func identifier(in keychain: Keychain = .app) -> String {
        if let data = try? keychain.read("device"), let id = String(data: data, encoding: .utf8) { return id }
        let id = UUID().uuidString.lowercased()
        try? keychain.write(Data(id.utf8), as: "device")
        return id
    }

    static let name = "OriPass"
    static let type = "1"
}
