import CryptoKit
import Foundation

/// A passkey made on this phone: a new P-256 key, the entry a login keeps
/// for it as Bitwarden's apps write one, and what the relying party is
/// handed, an attestation of format "none" around the id and the public key.
struct PasskeyRegistration: Sendable, Redacted {
    let passkey: Item.Passkey
    let credentialID: Data
    let publicKey: P256.Signing.PublicKey
    let attestationObject: Data

    var redactedLabel: String { "PasskeyRegistration(\(passkey.rpId))" }

    /// The authenticator data's bit that says a credential follows it.
    static let attested: UInt8 = 0x40

    /// Sixteen zeros, which claim no maker: a provider's own number is for
    /// attestation, and borrowing Bitwarden's would claim to be Bitwarden.
    static let aaguid = Data(count: 16)

    init(relyingParty: String, userName: String, userHandle: Data) {
        let key = P256.Signing.PrivateKey()
        let id = UUID()
        let name = userName.isEmpty ? nil : userName
        credentialID = withUnsafeBytes(of: id.uuid) { Data($0) }
        publicKey = key.publicKey
        passkey = Item.Passkey(
            credentialId: id.uuidString.lowercased(), rpId: relyingParty, rpName: relyingParty, userName: name,
            userDisplayName: name, userHandle: Passkeys.base64url(userHandle),
            keyValue: Passkeys.base64url(key.derRepresentation), keyAlgorithm: "ECDSA", counter: "0", discoverable: true)
        var data = PasskeyAssertion.authenticatorData(rpId: relyingParty, counter: 0,
                                                      flags: PasskeyAssertion.flags | PasskeyRegistration.attested)
        data.append(PasskeyRegistration.aaguid)
        withUnsafeBytes(of: UInt16(credentialID.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(credentialID)
        data.append(PasskeyRegistration.coseKey(key.publicKey))
        attestationObject = CBOR.map([(CBOR.text("fmt"), CBOR.text("none")), (CBOR.text("attStmt"), CBOR.map([])),
                                      (CBOR.text("authData"), CBOR.bytes(data))])
    }

    /// RFC 9053's EC2 key: its type, ES256, the curve P-256, x and y.
    private static func coseKey(_ key: P256.Signing.PublicKey) -> Data {
        let point = key.rawRepresentation
        return CBOR.map([(CBOR.int(1), CBOR.int(2)), (CBOR.int(3), CBOR.int(-7)), (CBOR.int(-1), CBOR.int(1)),
                         (CBOR.int(-2), CBOR.bytes(point.prefix(32))), (CBOR.int(-3), CBOR.bytes(point.suffix(32)))])
    }

    /// The logins a new passkey for a site may go on: the site's, and none
    /// that holds a passkey already, since Bitwarden's apps read one from a
    /// login and a second would be out of their sight.
    static func homes(for relyingParty: String, in summaries: [Summary]) -> [Summary] {
        let site = Matching(pages: [Matching.Page(url: nil, host: relyingParty.lowercased(), app: nil)])
        return summaries.filter { $0.kind == .login && $0.passkeys.isEmpty && site.matches($0) }
    }

    /// Whether the vault holds one of the passkeys a relying party said it
    /// already has for this person.
    static func holds(_ excluded: [Data], for relyingParty: String, in summaries: [Summary]) -> Bool {
        summaries.contains { summary in
            summary.passkeys.contains { passkey in
                passkey.rpId == relyingParty && Passkeys.credentialID(passkey.credentialId).map(excluded.contains) == true
            }
        }
    }
}

/// The little of CBOR an attestation is made of, written in the order
/// CTAP2's canonical form asks for by whoever calls it.
private enum CBOR {
    static func int(_ value: Int) -> Data {
        value < 0 ? head(1, -1 - value) : head(0, value)
    }

    static func bytes(_ data: Data) -> Data { head(2, data.count) + data }
    static func text(_ text: String) -> Data { head(3, text.utf8.count) + Data(text.utf8) }

    static func map(_ pairs: [(Data, Data)]) -> Data {
        pairs.reduce(head(5, pairs.count)) { $0 + $1.0 + $1.1 }
    }

    private static func head(_ major: UInt8, _ count: Int) -> Data {
        let type = major << 5
        switch count {
        case ..<24: return Data([type | UInt8(count)])
        case ..<256: return Data([type | 24, UInt8(count)])
        default: return Data([type | 25, UInt8(count >> 8), UInt8(count & 0xFF)])
        }
    }
}
