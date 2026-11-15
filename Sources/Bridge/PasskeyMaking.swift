import CryptoKit
import Foundation

/// A passkey a page asks to have made: who for, the hash of the client data
/// it is to be tied to, and where it goes. The system checked the page
/// against the relying party, as it does for `PasskeyAsk`, and only the
/// provider gets this far (`BrowserDoor`).
struct PasskeyOrder: Equatable {
    /// ES256 in COSE's numbers, which is how the system lists what a page takes.
    static let es256 = -7

    let relyingParty: String
    let userName: String
    /// What the site knows the person by, one to sixty-four bytes.
    let userHandle: Data
    let clientDataHash: Data
    let algorithms: [Int]
    /// The ids the site already holds for this person, which it lists so as
    /// not to be given a second.
    let excluded: [Data]
    /// The login chosen to hold it, and nil for a new one.
    let login: String?
}

/// A passkey made in the app and never in the provider: its entry for
/// `fido2Credentials`, as `bw` keeps one, thirteen keys and every value a
/// string, and the attestation that tells the page its public half. The
/// entry holds the key, as an entry the engine sent does, and goes nowhere
/// but `Item.patched`. The attestation and the id are all that cross the door.
struct MadePasskey: Equatable, Redacted {
    /// Set beside `Passkey.flags` on a registration: attested credential
    /// data follows the counter.
    private static let attested: UInt8 = 0x40

    let credentialID: Data
    let entry: JSONValue
    let attestation: Data

    var redactedLabel: String { "MadePasskey" }

    init(_ order: PasskeyOrder, key: P256.Signing.PrivateKey, id: UUID = UUID(), at date: Date) {
        credentialID = withUnsafeBytes(of: id.uuid) { Data($0) }
        var der = key.derRepresentation
        defer { der.resetBytes(in: 0..<der.count) }
        entry = .object([
            "credentialId": .string(id.uuidString.lowercased()),
            "keyType": .string("public-key"),
            "keyAlgorithm": .string("ECDSA"),
            "keyCurve": .string("P-256"),
            "keyValue": .string(Self.urlSafe(der)),
            "rpId": .string(order.relyingParty),
            "rpName": .string(order.relyingParty),
            "userHandle": .string(Self.urlSafe(order.userHandle)),
            "userName": .string(order.userName),
            "userDisplayName": .string(order.userName),
            "counter": .string("0"),
            "discoverable": .string("true"),
            "creationDate": .string(VaultDate.string(date)),
        ])
        attestation = Self.attestation(for: order.relyingParty, id: credentialID, key: key.publicKey)
    }

    private static func urlSafe(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// WebAuthn's attestation object under the format `none`, which
    /// `ASPasskeyRegistrationCredential` carries as the CBOR it is: nothing
    /// signs it, and the authenticator data says the key. The AAGUID is
    /// zeros, as `none` has it, so a site names no maker.
    private static func attestation(for relyingParty: String, id: Data, key: P256.Signing.PublicKey) -> Data {
        var data = Passkey.authenticatorData(for: relyingParty, flags: Passkey.flags | attested, counter: 0)
        data.append(Data(count: 16))
        withUnsafeBytes(of: UInt16(id.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(id)
        data.append(coseKey(key))
        return Data([0xA3]) + CBOR.text("fmt") + CBOR.text("none") + CBOR.text("attStmt") + Data([0xA0])
            + CBOR.text("authData") + CBOR.bytes(data)
    }

    /// An EC2 key on P-256 for ES256, in COSE's numbers.
    private static func coseKey(_ key: P256.Signing.PublicKey) -> Data {
        let point = key.rawRepresentation
        return Data([0xA5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21]) + CBOR.bytes(point.prefix(32))
            + Data([0x22]) + CBOR.bytes(point.suffix(32))
    }
}

/// As much of CBOR as an attestation object is.
private enum CBOR {
    static func text(_ string: String) -> Data {
        head(major: 3, count: string.utf8.count) + Data(string.utf8)
    }

    static func bytes(_ bytes: Data) -> Data {
        head(major: 2, count: bytes.count) + bytes
    }

    private static func head(major: UInt8, count: Int) -> Data {
        switch count {
        case ..<24: return Data([major << 5 | UInt8(count)])
        case ..<256: return Data([major << 5 | 24, UInt8(count)])
        default: return Data([major << 5 | 25, UInt8(count >> 8), UInt8(count & 0xFF)])
        }
    }
}

extension PasskeyDoor {
    /// A new key, after a finger, for every one: the flags say a person was
    /// verified, as an assertion's do. It is made here, sent through the
    /// engine (D4), and answered only once the engine has handed the item
    /// back holding it, since a site told of a passkey the vault lost would
    /// be a sign-in nobody can use.
    func make(_ order: PasskeyOrder) async -> BridgeAnswer {
        guard order.algorithms.contains(PasskeyOrder.es256) else { return .refused(.page) }
        let isHeld = held.contains {
            order.excluded.contains($0.passkey.credentialID)
                && $0.passkey.relyingParty.caseInsensitiveCompare(order.relyingParty) == .orderedSame
        }
        guard !isHeld else { return .refused(.excluded) }
        let asked: Bool
        if let id = order.login {
            guard let item = store.entry(id: id)?.item else { return .refused(.gone) }
            asked = await reprompt.confirm(.makePasskey, on: item)
        } else {
            asked = await reprompt.confirm(.makePasskey, named: order.relyingParty)
        }
        guard asked else { return .refused(.declined) }
        // He took a while, and the vault may have moved under the question.
        guard store.state == .unlocked else { return .locked }
        if let id = order.login, store.entry(id: id)?.item.isOutstanding != true { return .refused(.gone) }
        let made = MadePasskey(order, key: newKey(), at: store.now())
        do {
            guard let saved = try await save(made, for: order) else { return .locked }
            guard Passkey.all(in: saved).contains(where: { $0.credentialID == made.credentialID }) else {
                Log.app.error("passkey: the engine handed the item back without it")
                return .refused(.unsaved)
            }
            return .made(BridgeRegistration(credential: made.credentialID, attestation: made.attestation))
        } catch VaultError.locked {
            return .locked
        } catch {
            Log.app.error("passkey: the engine did not keep it: \((error as NSError).code)")
            return .refused(.unsaved)
        }
    }

    private func save(_ made: MadePasskey, for order: PasskeyOrder) async throws -> Item? {
        if let id = order.login { return try await store.apply(.passkey(made), to: id) }
        let blank = try await store.blank(.login)
        return try await store.create(blank.named(for: order), from: blank, holding: made)
    }
}

private extension Item {
    /// A new login for a passkey: the site's name, the person's and the
    /// site's address, as the form would have them, and no password.
    func named(for order: PasskeyOrder) -> Item {
        var named = self
        named.name = order.relyingParty
        guard case .login(var login) = payload else { return named }
        login.username = order.userName.isEmpty ? nil : order.userName
        login.uris = [LoginURI(uri: "https://\(order.relyingParty)")]
        named.payload = .login(login)
        return named
    }
}
