import XCTest
@testable import OriPass

final class WritesTests: XCTestCase {
    private var vault: Vault!
    private var data: Data!

    override func setUpWithError() throws {
        let plain = FakeServer.vault["plain"] as! [String: Any]
        data = try JSONSerialization.data(withJSONObject: FakeServer.vault["sync"]!)
        vault = try Vault(data: data, userKey: VaultKey(Data(b64: plain["userKey"])))
    }

    private func item(_ name: String) -> Item { vault.items().items.first { $0.name == name }! }

    func testAnEditChangesOnlyWhatChangedAndKeepsThePasskey() throws {
        let passkeySite = item("Kanarya Passkey Site")
        let raw = try XCTUnwrap(Writes.raw(passkeySite.id, in: data))
        var draft = Draft(passkeySite)
        draft.password = "kanarya-pass-5-Edited"
        let body = try Writes.edit(raw, from: passkeySite, to: draft, key: vault.key(for: passkeySite.id))
        let login = body["login"] as! [String: Any]
        let rawLogin = raw["login"] as! [String: Any]
        XCTAssertEqual(body["name"] as? String, raw["name"] as? String, "the name went back as it came")
        XCTAssertEqual(login["username"] as? String, rawLogin["username"] as? String)
        XCTAssertEqual(try EncString(login["password"] as! String).decryptString(with: vault.key(for: passkeySite.id)),
                       "kanarya-pass-5-Edited")
        XCTAssertEqual(NSArray(array: login["fido2Credentials"] as! [Any]), NSArray(array: rawLogin["fido2Credentials"] as! [Any]))
        XCTAssertEqual(body["lastKnownRevisionDate"] as? String, raw["revisionDate"] as? String)
        XCTAssertNil(body["data"])
        XCTAssertNil(body["attachments"])
    }

    func testAChangedPasswordGoesFirstIntoTheHistoryUnderTheItemsOwnKey() throws {
        let bank = item("Kanarya Bank")
        let key = try vault.key(for: bank.id)
        XCTAssertNotEqual(key.bytes, vault.userKey.bytes, "the bank has a key of its own")
        var draft = Draft(bank)
        draft.password = "kanarya-pass-3-New"
        let body = try Writes.edit(XCTUnwrap(Writes.raw(bank.id, in: data)), from: bank, to: draft, key: key)
        let history = body["passwordHistory"] as! [[String: Any]]
        XCTAssertEqual(try EncString(history[0]["password"] as! String).decryptString(with: key), "kanarya-pass-3-Zt2")
    }

    func testANewLoginIsSealedUnderTheUserKey() throws {
        var draft = Draft()
        draft.name = "Kanarya New"
        draft.username = "kanarya-user-9"
        draft.password = "kanarya-pass-9"
        draft.uris = ["https://new.kanarya.example"]
        let body = try Writes.create(draft, key: vault.userKey)
        XCTAssertEqual(body["type"] as? Int, 1)
        XCTAssertEqual(try EncString(body["name"] as! String).decryptString(with: vault.userKey), "Kanarya New")
        let uri = ((body["login"] as! [String: Any])["uris"] as! [[String: Any]])[0]
        XCTAssertEqual(try EncString(uri["uri"] as! String).decryptString(with: vault.userKey), "https://new.kanarya.example")
    }
}

@MainActor
final class SaveFailureTests: XCTestCase {
    func testTheServersSentenceForAnOldCopyIsOutOfDate() {
        let said = "The cipher you are updating is out of date. Please save your work, sync your vault, and try again."
        XCTAssertEqual(AppModel.SaveFailure(.status(400, said)), .outOfDate)
        XCTAssertEqual(AppModel.SaveFailure(.status(400, "Something else.")), .refused("Something else."))
        XCTAssertEqual(AppModel.SaveFailure(.unreachable), .refused(nil))
    }
}
