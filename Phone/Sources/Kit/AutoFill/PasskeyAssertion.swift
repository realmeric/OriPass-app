import CryptoKit
import Foundation

/// A WebAuthn assertion made with a passkey kept in a login: the
/// authenticator data for the relying party, signed together with the
/// client data's hash by the passkey's P-256 key.
struct PasskeyAssertion: Sendable {
    let credentialID: Data
    let userHandle: Data
    let authenticatorData: Data
    let signature: Data

    enum Failure: Error, Equatable {
        case notES256
        case unreadableKey
        case unreadableId
    }

    /// The flags: the person was present and verified by a face or the
    /// master password, and the key is one that is synced, as every passkey
    /// in a Bitwarden vault is.
    static let flags: UInt8 = 0x01 | 0x04 | 0x08 | 0x10

    static func authenticatorData(rpId: String, counter: UInt32, flags: UInt8 = flags) -> Data {
        var data = Data(SHA256.hash(data: Data(rpId.utf8)))
        data.append(flags)
        withUnsafeBytes(of: counter.bigEndian) { data.append(contentsOf: $0) }
        return data
    }

    /// The counter stays as it was kept: a write that moves it is PH-21's,
    /// and Bitwarden's passkeys are made with 0, which a relying party
    /// reads as no counter at all.
    init(passkey: Item.Passkey, clientDataHash: Data) throws {
        guard passkey.keyAlgorithm == nil || passkey.keyAlgorithm == "ECDSA" else { throw Failure.notES256 }
        guard let id = Passkeys.credentialID(passkey.credentialId) else { throw Failure.unreadableId }
        guard let der = Data(base64Encoded: passkey.keyValue) ?? Passkeys.base64url(passkey.keyValue),
              let key = try? P256.Signing.PrivateKey(derRepresentation: der) else { throw Failure.unreadableKey }
        credentialID = id
        userHandle = Passkeys.userHandle(passkey.userHandle) ?? Data()
        authenticatorData = PasskeyAssertion.authenticatorData(rpId: passkey.rpId,
                                                               counter: UInt32(passkey.counter ?? "0") ?? 0)
        signature = try key.signature(for: authenticatorData + clientDataHash).derRepresentation
    }
}
