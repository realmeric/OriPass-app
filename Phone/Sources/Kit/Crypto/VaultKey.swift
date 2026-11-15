import CryptoKit
import Foundation

/// A symmetric key as Bitwarden uses one: 32 bytes to encrypt with AES-256
/// and 32 to authenticate with HMAC-SHA256. A user key, an organisation's
/// key and an item's own key are each one of these, sent as 64 bytes. The
/// oldest user keys were 32 bytes with no MAC key, which only type 0 reads.
struct VaultKey: Redacted, Sendable {
    let encryption: Data
    let authentication: Data?

    var redactedLabel: String { "VaultKey(\(authentication == nil ? 32 : 64))" }

    init(encryption: Data, authentication: Data?) {
        self.encryption = encryption
        self.authentication = authentication
    }

    init(_ bytes: Data) throws {
        switch bytes.count {
        case 64:
            self.init(encryption: Data(bytes.prefix(32)), authentication: Data(bytes.suffix(32)))
        case 32:
            self.init(encryption: Data(bytes), authentication: nil)
        default:
            throw CryptoError.badKey
        }
    }

    /// The 64 bytes, as the server keeps a key and the keychain will.
    var bytes: Data { encryption + (authentication ?? Data()) }

    static func random() -> VaultKey {
        try! VaultKey(Random.bytes(64))
    }
}

enum Random {
    static func bytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(status == errSecSuccess, "the system has no randomness to give")
        return data
    }
}
