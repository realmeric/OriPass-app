import XCTest
@testable import OriPass

final class WatchTests: XCTestCase {
    private func login(_ id: String, _ password: String, uri: String = "https://kanarya.example", deleted: Bool = false) -> Item {
        Item(id: id, kind: .login, name: id, notes: nil, favorite: false, folderId: nil, organizationId: nil,
             deleted: deleted, archived: false, asksAgain: false, revised: nil, created: nil,
             login: Item.Login(username: "kanarya", password: password, totp: nil, passwordRevised: nil,
                               uris: [Item.Uri(uri: uri, match: nil)], passkeys: []),
             values: [], fields: [], history: [])
    }

    func testTheThreeCounts() {
        let strong = "kanarya-Xr8#Lq4!Zt2$Wn6"
        let watch = Watch.count([
            login("a", strong), login("b", strong),
            login("c", "password1"),
            login("d", "kanarya-Hd3@Qp1&Mv9*Ty", uri: "http://kanarya.example"),
            login("e", strong, deleted: true),
        ], year: 2026)
        XCTAssertEqual(Set(watch.reused), ["a", "b"], "the trash is on no list")
        XCTAssertEqual(watch.weak, ["c"])
        XCTAssertEqual(watch.unsecured, ["d"])
    }

    func testTheFixtureHasAnUnsecuredLoginAndNothingReused() throws {
        let plain = FakeServer.vault["plain"] as! [String: Any]
        let sync = try JSONSerialization.data(withJSONObject: FakeServer.vault["sync"]!)
        let items = try Vault(data: sync, userKey: VaultKey(Data(b64: plain["userKey"]))).items().items
        let watch = Watch.count(items)
        XCTAssertEqual(watch.reused, [])
        XCTAssertEqual(watch.unsecured.count, 2, "the two stand-in logins are on http://localhost")
    }
}
