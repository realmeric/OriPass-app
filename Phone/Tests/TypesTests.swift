import XCTest
@testable import OriPass

final class TypesTests: XCTestCase {
    private var vault: Vault!
    private var data: Data!

    override func setUpWithError() throws {
        let plain = FakeServer.vault["plain"] as! [String: Any]
        data = try JSONSerialization.data(withJSONObject: FakeServer.vault["sync"]!)
        vault = try Vault(data: data, userKey: VaultKey(Data(b64: plain["userKey"])))
    }

    func testACardsChangedCodeIsTheOnlyStringSentAgain() throws {
        let card = vault.items().items.first { $0.kind == .card }!
        let raw = try XCTUnwrap(Writes.raw(card.id, in: data))
        var draft = Draft(card)
        draft.values["code"] = "999"
        let body = try Writes.edit(raw, from: card, to: draft, key: vault.key(for: card.id))
        let sent = body["card"] as! [String: Any]
        let kept = raw["card"] as! [String: Any]
        XCTAssertEqual(sent["number"] as? String, kept["number"] as? String)
        XCTAssertEqual(try EncString(sent["code"] as! String).decryptString(with: vault.key(for: card.id)), "999")
    }

    func testANewIdentityIsWrittenUnderBitwardensNames() throws {
        var draft = Draft(kind: .identity)
        draft.name = "Kanarya Person"
        draft.values = ["title": "Mx", "firstName": "Kanarya", "email": "kanarya@kanarya.example", "lastName": ""]
        let body = try Writes.create(draft, key: vault.userKey)
        XCTAssertEqual(body["type"] as? Int, 4)
        let identity = body["identity"] as! [String: Any]
        XCTAssertEqual(Set(identity.keys), ["title", "firstName", "email"], "an empty value is not sent")
        XCTAssertEqual(try EncString(identity["title"] as! String).decryptString(with: vault.userKey), "Mx")
    }

    func testAGeneratedKeyReadsBackAsAnEd25519KeyInOpenSSHsFile() throws {
        let key = SSHKeys.generate()
        XCTAssertTrue(key.privateKey.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----\n"))
        XCTAssertTrue(key.privateKey.hasSuffix("-----END OPENSSH PRIVATE KEY-----\n"))
        XCTAssertTrue(key.privateKey.split(separator: "\n").allSatisfy { $0.count <= 70 })
        XCTAssertTrue(key.publicKey.hasPrefix("ssh-ed25519 "))
        XCTAssertEqual(key.publicKey.split(separator: " ").count, 2, "no comment")
        XCTAssertTrue(key.fingerprint.hasPrefix("SHA256:"))
        XCTAssertFalse(key.fingerprint.hasSuffix("="))
        XCTAssertNotEqual(SSHKeys.generate().publicKey, key.publicKey)
    }
}
