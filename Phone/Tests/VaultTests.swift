import XCTest
@testable import OriPass

final class VaultTests: XCTestCase {
    private var plain: [String: Any]!
    private var userKey: VaultKey!
    private var sync: Data!

    override func setUpWithError() throws {
        plain = FakeServer.vault["plain"] as? [String: Any]
        userKey = try VaultKey(Data(b64: plain["userKey"]))
        sync = try JSONSerialization.data(withJSONObject: FakeServer.vault["sync"]!)
    }

    private var plainItems: [[String: Any]] { plain["items"] as! [[String: Any]] }

    func testEveryItemOpensToWhatWasPutIn() throws {
        let vault = try Vault(data: sync, userKey: userKey)
        let (items, unread) = vault.items()
        XCTAssertEqual(unread, [:])
        XCTAssertEqual(items.count, plainItems.count)
        for want in plainItems {
            let got = try XCTUnwrap(items.first { $0.id == want["id"] as? String })
            let name = want["name"] as! String
            XCTAssertEqual(got.name, name)
            XCTAssertEqual(got.notes, want["notes"] as? String, name)
            XCTAssertEqual(got.favorite, want["favorite"] as? Bool, name)
            XCTAssertEqual(got.deleted, want["deleted"] as? Bool, name)
            if let login = want["login"] as? [String: Any] {
                XCTAssertEqual(got.login?.username, login["username"] as? String, name)
                XCTAssertEqual(got.login?.password, login["password"] as? String, name)
                XCTAssertEqual(got.login?.totp, login["totp"] as? String, name)
                XCTAssertEqual(got.login?.uris.map(\.uri), login["uris"] as? [String], name)
                if let passkey = login["passkey"] as? [String: Any] {
                    let kept = try XCTUnwrap(got.login?.passkeys.first)
                    XCTAssertEqual(kept.rpId, passkey["rpId"] as? String)
                    XCTAssertEqual(kept.keyValue, passkey["keyValue"] as? String)
                    XCTAssertEqual(kept.userHandle, passkey["userHandle"] as? String)
                    XCTAssertTrue(kept.discoverable)
                }
            }
            for part in ["card", "identity", "sshKey"] {
                for (key, value) in want[part] as? [String: String] ?? [:] {
                    XCTAssertEqual(got.value(key), value, "\(name) \(key)")
                }
            }
            let fields = want["fields"] as! [[String: Any]]
            XCTAssertEqual(got.fields.map(\.value), fields.map { $0["value"] as? String }, name)
            XCTAssertEqual(got.history.map(\.password), want["passwordHistory"] as? [String], name)
        }
        XCTAssertEqual(vault.folders().map(\.name), [plain["folder"] as! String])
    }

    func testTheOrganisationsItemAndTheOneWithItsOwnKeyOpen() throws {
        let items = try Vault(data: sync, userKey: userKey).items().items
        XCTAssertEqual(items.first { $0.organizationId != nil }?.login?.password, "kanarya-pass-4-Wn6")
        let own = try XCTUnwrap(plainItems.first { $0["ownKey"] as? Bool == true })
        XCTAssertEqual(items.first { $0.id == own["id"] as? String }?.login?.password, "kanarya-pass-3-Zt2")
    }

    func testSummariesLeaveTheTrashOut() throws {
        let summaries = try Vault(data: sync, userKey: userKey).summaries()
        XCTAssertEqual(summaries.count, plainItems.count - 1)
        XCTAssertFalse(summaries.contains { $0.name == "Old Kanarya" })
        let mail = try XCTUnwrap(summaries.first { $0.name == "Kanarya Mail" })
        XCTAssertTrue(mail.hasTotp)
        XCTAssertEqual(mail.username, "kanarya-user-2@kanarya.example")
        XCTAssertEqual(summaries.first { $0.name == "Kanarya Passkey Site" }?.passkeys.first?.rpId, "passkey.kanarya.example")
    }

    func testAnItemInTheNewerFormatIsCountedAndNotShown() throws {
        var json = FakeServer.vault["sync"] as! [String: Any]
        var ciphers = json["ciphers"] as! [[String: Any]]
        ciphers[0]["name"] = "7.0oRDoQEDoPZY"
        json["ciphers"] = ciphers
        let vault = try Vault(data: JSONSerialization.data(withJSONObject: json), userKey: userKey)
        let (items, unread) = vault.items()
        XCTAssertEqual(unread, [ciphers[0]["id"] as! String: .newerEncryption])
        XCTAssertEqual(items.count, plainItems.count - 1)
    }

    func testAnItemOfAnOrganisationWithNoKeyIsCounted() throws {
        var json = FakeServer.vault["sync"] as! [String: Any]
        var profile = json["profile"] as! [String: Any]
        profile["organizations"] = []
        json["profile"] = profile
        let (_, unread) = try Vault(data: JSONSerialization.data(withJSONObject: json), userKey: userKey).items()
        XCTAssertEqual(Array(unread.values), [.noOrganisationKey])
    }

    func testAnotherKeyOpensNothing() throws {
        let (items, unread) = try Vault(data: sync, userKey: VaultKey.random()).items()
        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(unread.count, plainItems.count)
        XCTAssertEqual(unread.values.filter { $0 == .noOrganisationKey }.count, 1)
        XCTAssertTrue(unread.values.allSatisfy { $0 == .wrongKey || $0 == .noOrganisationKey })
    }

    func testASyncWithATokenThatRanOutIsRefreshedAndAsked() async throws {
        FakeServer.reset()
        let keychain = Keychain(service: "com.meric.oripass.tests")
        defer { keychain.deleteAll() }
        let api = Api(client: FakeServer.client(),
                      tokens: Tokens(access: "kanarya-revoked", refresh: "kanarya-refresh", expires: .distantFuture),
                      keychain: keychain)
        let data = try await api.get("sync")
        XCTAssertEqual(try Vault(data: data, userKey: userKey).count, plainItems.count)
        XCTAssertEqual(FakeServer.seen.map(\.path), ["/api/sync", "/identity/connect/token", "/api/sync"])
        XCTAssertEqual(Tokens.stored(in: keychain)?.access, "kanarya-access")
    }
}
