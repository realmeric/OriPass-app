import AuthenticationServices
import CryptoKit
import XCTest
@testable import OriPass

final class PasskeyTests: XCTestCase {
    private func passkey() throws -> (Item.Passkey, P256.Signing.PublicKey) {
        let plain = FakeServer.vault["plain"] as! [String: Any]
        let sync = try JSONSerialization.data(withJSONObject: FakeServer.vault["sync"]!)
        let vault = try Vault(data: sync, userKey: VaultKey(Data(b64: plain["userKey"])))
        let item = try XCTUnwrap(vault.items().items.first { $0.name == "Kanarya Passkey Site" })
        let kept = (plain["items"] as! [[String: Any]]).first { $0["name"] as? String == "Kanarya Passkey Site" }!
        let made = (kept["login"] as! [String: Any])["passkey"] as! [String: Any]
        let publicKey = try P256.Signing.PublicKey(derRepresentation: Data(b64: made["publicKey"]))
        return (try XCTUnwrap(item.login?.passkeys.first), publicKey)
    }

    func testTheSignatureIsTheKeysOverTheDataAndTheHash() throws {
        let (passkey, publicKey) = try passkey()
        let clientDataHash = Data(SHA256.hash(data: Data(#"{"type":"webauthn.get","challenge":"kanarya"}"#.utf8)))
        let assertion = try PasskeyAssertion(passkey: passkey, clientDataHash: clientDataHash)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: assertion.signature)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: assertion.authenticatorData + clientDataHash))
        XCTAssertFalse(publicKey.isValidSignature(signature, for: assertion.authenticatorData + Data(repeating: 0, count: 32)))
    }

    func testTheAuthenticatorDataIsTheRelyingPartysAndTheFlags() throws {
        let (passkey, _) = try passkey()
        let data = try PasskeyAssertion(passkey: passkey, clientDataHash: Data(count: 32)).authenticatorData
        XCTAssertEqual(data.count, 37)
        XCTAssertEqual(data.prefix(32), Data(SHA256.hash(data: Data("passkey.kanarya.example".utf8))))
        XCTAssertEqual(data[32], 0x1d, "present, verified, eligible for backup and backed up")
        XCTAssertEqual(data.suffix(4), Data([0, 0, 0, 0]))
    }

    func testTheIdsAreTheKeptOnes() throws {
        let (passkey, _) = try passkey()
        let assertion = try PasskeyAssertion(passkey: passkey, clientDataHash: Data(count: 32))
        XCTAssertEqual(assertion.credentialID, Passkeys.credentialID(passkey.credentialId))
        XCTAssertEqual(assertion.userHandle, Data("kanarya-user-handle-5".utf8))
    }
}

/// A passkey made, kept in the vault through the writes the extension makes,
/// and read back from the sync as Bitwarden's server would send it.
final class PasskeyRegistrationTests: XCTestCase {
    private let keychain = Keychain(service: "com.meric.oripass.tests")
    private var plain: [String: Any]!
    private var vault: Vault!
    private var api: Api!

    override func setUpWithError() throws {
        FakeServer.reset()
        plain = (FakeServer.vault["plain"] as! [String: Any])
        let sync = try JSONSerialization.data(withJSONObject: FakeServer.vault["sync"]!)
        try VaultFile.write(sync)
        vault = try Vault(data: sync, userKey: VaultKey(Data(b64: plain["userKey"])))
        api = Api(client: FakeServer.client(),
                  tokens: Tokens(access: "kanarya-access", refresh: "kanarya-refresh", expires: .distantFuture),
                  keychain: keychain)
    }

    override func tearDown() {
        FakeServer.reset()
        VaultFile.forget()
        keychain.deleteAll()
    }

    private func item(_ name: String) -> Item { vault.items().items.first { $0.name == name }! }

    private func made(_ rpId: String = "bank.kanarya.example", user: String = "kanarya-user-3") -> PasskeyRegistration {
        PasskeyRegistration(relyingParty: rpId, userName: user, userHandle: Data("kanarya-handle".utf8))
    }

    /// The authenticator data out of the attestation, read a step at a time
    /// as a relying party reads it, and the public key out of that.
    private func read(_ attestation: Data) throws -> (data: Data, id: Data, key: P256.Signing.PublicKey) {
        var cbor = Reader(attestation)
        XCTAssertEqual(cbor.head(), Reader.Head(major: 5, value: 3))
        XCTAssertEqual(cbor.text(), "fmt")
        XCTAssertEqual(cbor.text(), "none")
        XCTAssertEqual(cbor.text(), "attStmt")
        XCTAssertEqual(cbor.head(), Reader.Head(major: 5, value: 0))
        XCTAssertEqual(cbor.text(), "authData")
        let data = cbor.bytes()
        XCTAssertTrue(cbor.atEnd)

        XCTAssertEqual(data[32], 0x5d, "present, verified, eligible for backup, backed up, attested")
        XCTAssertEqual(data.subdata(in: 33..<37), Data(count: 4), "the counter")
        XCTAssertEqual(data.subdata(in: 37..<53), Data(count: 16), "the maker claimed")
        let length = Int(data[53]) << 8 | Int(data[54])
        let id = data.subdata(in: 55..<(55 + length))
        var cose = Reader(data.subdata(in: (55 + length)..<data.count))
        XCTAssertEqual(cose.head(), Reader.Head(major: 5, value: 5))
        XCTAssertEqual(cose.head(), Reader.Head(major: 0, value: 1))
        XCTAssertEqual(cose.head(), Reader.Head(major: 0, value: 2), "an EC2 key")
        XCTAssertEqual(cose.head(), Reader.Head(major: 0, value: 3))
        XCTAssertEqual(cose.head(), Reader.Head(major: 1, value: 6), "ES256, -7")
        XCTAssertEqual(cose.head(), Reader.Head(major: 1, value: 0))
        XCTAssertEqual(cose.head(), Reader.Head(major: 0, value: 1), "P-256")
        XCTAssertEqual(cose.head(), Reader.Head(major: 1, value: 1))
        let x = cose.bytes()
        XCTAssertEqual(cose.head(), Reader.Head(major: 1, value: 2))
        let y = cose.bytes()
        XCTAssertTrue(cose.atEnd)
        return (data, id, try P256.Signing.PublicKey(rawRepresentation: x + y))
    }

    func testTheAttestationSaysTheIdAndTheKeyOfThePasskey() throws {
        let registration = made()
        let (data, id, key) = try read(registration.attestationObject)
        XCTAssertEqual(data.prefix(32), Data(SHA256.hash(data: Data("bank.kanarya.example".utf8))))
        XCTAssertEqual(id, registration.credentialID)
        XCTAssertEqual(id, Passkeys.credentialID(registration.passkey.credentialId))
        XCTAssertEqual(key.rawRepresentation, registration.publicKey.rawRepresentation)
        XCTAssertEqual(Passkeys.userHandle(registration.passkey.userHandle), Data("kanarya-handle".utf8))
    }

    func testAPasskeyOnALoginSignsAfterTheSyncAndLeavesTheLoginAsItWas() async throws {
        let bank = item("Kanarya Bank")
        let ownKey = try vault.key(for: bank.id)
        let registration = made()
        let data = try await Saving.keep(registration.passkey, on: bank, in: vault, with: api)

        let back = try Vault(data: data, userKey: vault.userKey)
        let login = try XCTUnwrap(back.item(id: bank.id).login)
        XCTAssertEqual(login.username, bank.login?.username)
        XCTAssertEqual(login.password, bank.login?.password)
        XCTAssertEqual(login.uris, bank.login?.uris)
        let raw = try XCTUnwrap(Writes.raw(bank.id, in: data))
        let credential = try XCTUnwrap(((raw["login"] as? [String: Any])?["fido2Credentials"] as? [[String: Any]])?.first)
        XCTAssertEqual(try EncString(credential["rpId"] as! String).decryptString(with: ownKey), "bank.kanarya.example",
                       "under the item's own key")
        XCTAssertNil(try? EncString(credential["rpId"] as! String).decryptString(with: vault.userKey))
        XCTAssertNotNil(credential["creationDate"] as? String)

        let passkey = try XCTUnwrap(login.passkeys.first)
        XCTAssertEqual(passkey, registration.passkey)
        let clientDataHash = Data(SHA256.hash(data: Data(#"{"type":"webauthn.get","challenge":"kanarya"}"#.utf8)))
        let assertion = try PasskeyAssertion(passkey: passkey, clientDataHash: clientDataHash)
        XCTAssertEqual(assertion.credentialID, registration.credentialID)
        let (_, _, key) = try read(registration.attestationObject)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: assertion.signature)
        XCTAssertTrue(key.isValidSignature(signature, for: assertion.authenticatorData + clientDataHash))
    }

    func testAPasskeyWithNoLoginMakesOneForItsSite() async throws {
        let registration = made("new.kanarya.example", user: "kanarya-user-9")
        let data = try await Saving.keep(registration.passkey, on: nil, in: vault, with: api)
        let back = try Vault(data: data, userKey: vault.userKey)
        let login = try XCTUnwrap(back.items().items.first { $0.name == "new.kanarya.example" }?.login)
        XCTAssertEqual(login.username, "kanarya-user-9")
        XCTAssertNil(login.password)
        XCTAssertEqual(login.uris.map(\.uri), ["https://new.kanarya.example"])
        XCTAssertEqual(login.passkeys, [registration.passkey])
    }

    func testTheNewPasskeyIsAnIdentityAtOnce() async throws {
        let registration = made()
        let data = try await Saving.keep(registration.passkey, on: item("Kanarya Bank"), in: vault, with: api)
        let identities = Identities.make(from: try Vault(data: data, userKey: vault.userKey).summaries())
        let passkeys = identities.compactMap { $0 as? ASPasskeyCredentialIdentity }
        XCTAssertTrue(passkeys.contains { $0.credentialID == registration.credentialID && $0.relyingPartyIdentifier == "bank.kanarya.example" })
    }

    func testAWriteFromAnOldCopyGoesAgainFromASync() async throws {
        FakeServer.stale = true
        let registration = made()
        let data = try await Saving.keep(registration.passkey, on: item("Kanarya Bank"), in: vault, with: api)
        let back = try Vault(data: data, userKey: vault.userKey)
        XCTAssertEqual(try back.item(id: item("Kanarya Bank").id).login?.passkeys, [registration.passkey])
        XCTAssertEqual(FakeServer.seen.filter { $0.path.hasPrefix("/api/ciphers/") }.count, 2)
    }

    func testANewLoginIsNotAskedToGoAgain() async throws {
        FakeServer.stale = true
        do {
            _ = try await Saving.keep(made().passkey, on: nil, in: vault, with: api)
            XCTFail("the refusal is said")
        } catch {
            XCTAssertEqual(error as? SaveFailure, .outOfDate)
        }
    }

    func testAnEditKeepsThePasskeyItFoundAndAddsTheNewOne() throws {
        let site = item("Kanarya Passkey Site")
        var draft = Draft(site)
        draft.passkey = made("passkey.kanarya.example").passkey
        let body = try Writes.edit(XCTUnwrap(Writes.raw(site.id, in: JSONSerialization.data(withJSONObject: FakeServer.vault["sync"]!))), from: site, to: draft, key: vault.key(for: site.id))
        let kept = (body["login"] as! [String: Any])["fido2Credentials"] as! [[String: Any]]
        XCTAssertEqual(kept.count, 2)
    }

    func testOnlyTheSitesLoginsWithNoPasskeyCanTakeOne() {
        let summaries = vault.summaries()
        let homes = PasskeyRegistration.homes(for: "bank.kanarya.example", in: summaries).map(\.name)
        XCTAssertTrue(homes.contains("Kanarya Bank"))
        XCTAssertFalse(homes.contains("Kanarya Passkey Site"), "it has one")
        XCTAssertFalse(homes.contains("Kanarya Note"), "not a login")
        XCTAssertTrue(PasskeyRegistration.homes(for: "nowhere.example", in: summaries).isEmpty)
    }

    func testAPasskeyTheSiteHasAlreadyIsFound() throws {
        let summaries = vault.summaries()
        let kept = try XCTUnwrap(item("Kanarya Passkey Site").login?.passkeys.first)
        let id = try XCTUnwrap(Passkeys.credentialID(kept.credentialId))
        XCTAssertTrue(PasskeyRegistration.holds([id], for: "passkey.kanarya.example", in: summaries))
        XCTAssertFalse(PasskeyRegistration.holds([id], for: "bank.kanarya.example", in: summaries), "another site's")
        XCTAssertFalse(PasskeyRegistration.holds([Data(count: 16)], for: "passkey.kanarya.example", in: summaries))
        XCTAssertFalse(PasskeyRegistration.holds([], for: "passkey.kanarya.example", in: summaries))
    }
}

/// CBOR read the way a relying party reads it, for what a test has to take
/// apart: nothing here shares a line with what wrote it.
private struct Reader {
    struct Head: Equatable {
        let major: UInt8
        let value: Int
    }

    private let data: [UInt8]
    private var at = 0

    init(_ data: Data) {
        self.data = Array(data)
    }

    var atEnd: Bool { at == data.count }

    mutating func head() -> Head {
        let first = data[at]
        at += 1
        var value = Int(first & 0x1f)
        if value == 24 {
            value = Int(data[at])
            at += 1
        } else if value == 25 {
            value = Int(data[at]) << 8 | Int(data[at + 1])
            at += 2
        }
        return Head(major: first >> 5, value: value)
    }

    mutating func bytes() -> Data {
        let count = head().value
        defer { at += count }
        return Data(data[at..<(at + count)])
    }

    mutating func text() -> String {
        String(decoding: bytes(), as: UTF8.self)
    }
}
