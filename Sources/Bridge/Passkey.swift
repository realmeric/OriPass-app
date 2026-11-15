import CryptoKit
import Foundation

/// One passkey of a login, as Bitwarden keeps it under `fido2Credentials`,
/// read from the object the store holds. Nothing else in the app reads that
/// key, and `Item.patched` sends it back as it came. One made here is
/// `MadePasskey` until the engine has it.
///
/// `bw` decrypted it (D4), and this only signs with what the store already
/// has. The key stays the text it is in the store until `assertion`, which
/// reads it into `SecretBytes` for one signature and wipes them, as
/// `PrivateHalf` does for ssh. It never crosses the door.
struct Passkey: Redacted {
    /// The id's bytes, which a page lists and a system's request names.
    let credentialID: Data
    let relyingParty: String
    let userName: String?
    let userHandle: Data
    /// Only P-256 under ECDSA, which WebAuthn calls ES256, is answered.
    let isES256: Bool
    private let keyValue: String
    /// As it was kept: moving it would be a write, and Bitwarden makes its
    /// passkeys with 0, which a relying party reads as no counter at all.
    private let counter: UInt32

    var redactedLabel: String { "Passkey" }

    /// The flags of every assertion: the person was present and verified,
    /// which a finger at each signature makes true (`PasskeyDoor`), and the
    /// key is one that is synced, as every passkey in a Bitwarden vault is.
    static let flags: UInt8 = 0x01 | 0x04 | 0x08 | 0x10

    /// Nil for an entry with no relying party or an id that does not read,
    /// which nothing could ask for.
    init?(json: JSONValue) {
        guard let relyingParty = json["rpId"]?.string, !relyingParty.isEmpty,
              let credentialID = json["credentialId"]?.string.flatMap(Self.credentialID),
              let keyValue = json["keyValue"]?.string
        else { return nil }
        self.credentialID = credentialID
        self.relyingParty = relyingParty
        self.keyValue = keyValue
        userName = json["userName"]?.string
        userHandle = json["userHandle"]?.string.flatMap(Self.base64url) ?? Data()
        counter = json["counter"]?.string.flatMap { UInt32($0) } ?? 0
        let algorithm = json["keyAlgorithm"]?.string, curve = json["keyCurve"]?.string
        isES256 = (algorithm == nil || algorithm == "ECDSA") && (curve == nil || curve == "P-256")
    }

    /// Every passkey a login holds, in the order they are kept.
    static func all(in item: Item) -> [Passkey] {
        (item.raw["login"]?["fido2Credentials"]?.array ?? []).compactMap(Passkey.init(json:))
    }

    /// A GUID's sixteen bytes, written as the GUID, or any bytes written as
    /// "b64." and base64url.
    private static func credentialID(_ written: String) -> Data? {
        if written.hasPrefix("b64.") { return base64url(String(written.dropFirst(4))) }
        return UUID(uuidString: written).map { uuid in withUnsafeBytes(of: uuid.uuid) { Data($0) } }
    }

    private static func base64url(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    var authenticatorData: Data {
        Self.authenticatorData(for: relyingParty, flags: Self.flags, counter: counter)
    }

    /// The relying party's hash, the flags and the counter.
    static func authenticatorData(for relyingParty: String, flags: UInt8, counter: UInt32) -> Data {
        var data = Data(SHA256.hash(data: Data(relyingParty.utf8)))
        data.append(flags)
        withUnsafeBytes(of: counter.bigEndian) { data.append(contentsOf: $0) }
        return data
    }

    /// This passkey's signature over the authenticator data and the hash of
    /// the page's client data, which is all that leaves here. Nil for a key
    /// that is not ES256 or does not read as one.
    func assertion(over clientDataHash: Data) -> BridgeAssertion? {
        guard isES256, let key = privateKey else { return nil }
        defer { key.wipe() }
        let data = authenticatorData
        let signature = key.withBytes { bytes in
            try? P256.Signing.PrivateKey(derRepresentation: bytes).signature(for: data + clientDataHash)
        }
        return signature.map {
            BridgeAssertion(credential: credentialID, userHandle: userHandle, authenticatorData: data,
                            signature: $0.derRepresentation)
        }
    }

    /// PKCS#8, in either alphabet of base64: Bitwarden's clients write the
    /// URL's. The key's own bytes, and no `Data` or `String` of them.
    private var privateKey: SecretBytes? {
        SecretBytes.decodingBase64(keyValue.utf8.lazy.map(Self.standard), capacity: keyValue.utf8.count)
    }

    private static func standard(_ character: UInt8) -> UInt8 {
        switch character {
        case UInt8(ascii: "-"): return UInt8(ascii: "+")
        case UInt8(ascii: "_"): return UInt8(ascii: "/")
        default: return character
        }
    }
}
