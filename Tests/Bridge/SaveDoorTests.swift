import CryptoKit
import Foundation
import XCTest
@testable import OriPass

/// What a toast asks of the door, over the fake backend: `known`, `save` and
/// `never` from a page's caller, with the demo's own logins and two of a
/// site of the test's.
@MainActor
final class SaveDoorTests: XCTestCase {
    private static let site = "https://shop.example.test"
    private static let page = "https://shop.example.test/account/login?next=%2Fcart"
    private static let held = "kanarya-held-password"
    private static let typed = "kanarya-typed-password"

    private struct Rig {
        let store: VaultStore
        let backend: FakeBackend
        let authoriser: FakeAuthoriser
        let door: BrowserDoor
        let preferences: Preferences
    }

    private func login(_ id: String, _ username: String?, _ password: String?, at uri: String = site) -> JSONValue {
        let template = DemoVault.objects().items.first { $0["type"]?.int == 1 } ?? .null
        return template.setting(["id"], to: .string(id))
            .setting(["name"], to: .string("Shop \(id)"))
            .setting(["reprompt"], to: .int(0))
            .setting(["login", "username"], to: JSONValue(username))
            .setting(["login", "password"], to: JSONValue(password))
            .setting(["login", "totp"], to: .null)
            .setting(["login", "uris"], to: .array([.object(["uri": .string(uri), "match": .null])]))
            .setting(["passwordHistory"], to: .array([]))
    }

    private func rig(_ logins: [JSONValue] = [], icons: @escaping (String) async -> Data? = { _ in nil }) async -> Rig {
        let vault = DemoVault.objects()
        let backend = FakeBackend(items: vault.items + logins, folders: vault.folders, password: DemoVault.password)
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        let authoriser = FakeAuthoriser()
        let reprompt = Reprompt(store: store, authoriser: authoriser)
        let preferences = Preferences()
        let door = BrowserDoor(store: store, reprompt: reprompt, preferences: preferences, icons: icons)
        await store.unlock(password: SecretBytes(DemoVault.password))
        await store.indexing?.value
        return Rig(store: store, backend: backend, authoriser: authoriser, door: door, preferences: preferences)
    }

    private func typed(_ password: String = typed, username: String? = "kanarya@example.test",
                       url: String = page) -> BridgeRequest {
        let key = SymmetricKey(size: .bits256)
        let mark = Data(HMAC<SHA256>.authenticationCode(for: Data(password.utf8), using: key))
        return .known(BridgeTyped(url: url, username: username, key: key.withUnsafeBytes { Data($0) }, mark: mark))
    }

    private func order(_ id: String? = nil, password: SecretBytes = SecretBytes(typed), url: String = page,
                       username: String? = "kanarya@example.test") -> BridgeRequest {
        .save(BridgeSave(url: url, id: id, username: username, password: password))
    }

    private func said(_ answer: BridgeAnswer) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: answer.body) as? [String: Any])
    }

    private func state(_ answer: BridgeAnswer) throws -> String? { try said(answer)["state"] as? String }

    private func reason(_ answer: BridgeAnswer) throws -> String? { try said(answer)["reason"] as? String }

    private func listed(_ answer: BridgeAnswer) throws -> [String] {
        (try said(answer)["logins"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    // MARK: known

    func testASiteWithNoLoginIsNew() async throws {
        let rig = await rig()
        let answer = await rig.door.answer(typed(), from: .host)
        XCTAssertEqual(try state(answer), "new")
        XCTAssertEqual(try said(answer)["site"] as? String, "example.test")
        XCTAssertEqual(try listed(answer), [])
    }

    func testThePasswordItHasSaysNothingWhicheverUsernameWentWithIt() async throws {
        let rig = await rig([login("a", "kanarya@example.test", Self.held), login("b", "other", "kanarya-else")])
        for username in ["kanarya@example.test", "KANARYA@example.test", "phone-number", nil] {
            let answer = await rig.door.answer(typed(Self.held, username: username), from: .safari)
            XCTAssertEqual(try state(answer), "same", username ?? "none")
        }
    }

    func testAnotherPasswordForThatUsernameIsAnUpdateNamingIt() async throws {
        let rig = await rig([login("a", "kanarya@example.test", Self.held), login("b", "other", "kanarya-else")])
        let answer = await rig.door.answer(typed(), from: .host)
        XCTAssertEqual(try state(answer), "update")
        XCTAssertEqual(try listed(answer), ["a"])
    }

    func testAUsernameSeveralLoginsHaveIsAMenuOfThem() async throws {
        let rig = await rig([login("a", "kanarya@example.test", "kanarya-1"), login("b", "kanarya@example.test", "kanarya-2"),
                             login("c", "other", "kanarya-3")])
        let answer = await rig.door.answer(typed(), from: .host)
        XCTAssertEqual(try state(answer), "choose")
        XCTAssertEqual(Set(try listed(answer)), ["a", "b"])
    }

    func testNoUsernameIsAnyOfTheLogins() async throws {
        let one = await rig([login("a", "kanarya@example.test", Self.held)])
        let single = await one.door.answer(typed(username: nil), from: .host)
        XCTAssertEqual(try state(single), "update")
        let two = await rig([login("a", "one", "kanarya-1"), login("b", "two", "kanarya-2")])
        let several = await two.door.answer(typed(username: nil), from: .host)
        XCTAssertEqual(try state(several), "choose")
    }

    func testAUsernameNoLoginHasOffersThemAsAnother() async throws {
        let rig = await rig([login("a", "one", "kanarya-1"), login("b", "two", "kanarya-2")])
        let answer = await rig.door.answer(typed(), from: .host)
        XCTAssertEqual(try state(answer), "another")
        XCTAssertEqual(Set(try listed(answer)), ["a", "b"])
    }

    func testALoginWithNoUsernameIsTheOneForAUsername() async throws {
        let rig = await rig([login("a", nil, Self.held), login("b", "other", "kanarya-2")])
        let answer = await rig.door.answer(typed(), from: .host)
        XCTAssertEqual(try state(answer), "update")
        XCTAssertEqual(try listed(answer), ["a"])
    }

    func testAnotherSitesLoginIsNotCounted() async throws {
        let rig = await rig([login("a", "kanarya@example.test", Self.typed, at: "https://elsewhere.test")])
        let answer = await rig.door.answer(typed(), from: .host)
        XCTAssertEqual(try state(answer), "new", "the same password on another site says nothing of this one")
    }

    func testKnownHoldsNoPassword() async throws {
        let rig = await rig([login("a", "kanarya@example.test", Self.held), login("b", "other", "kanarya-else")])
        let answer = await rig.door.answer(typed(), from: .host)
        let text = String(decoding: answer.body, as: UTF8.self)
        for word in [Self.held, Self.typed, "kanarya-else", "mark", "key", "password"] {
            XCTAssertFalse(text.contains(word), word)
        }
        XCTAssertEqual("\(answer)", "BridgeAnswer(known)")
    }

    func testAnAddressThatIsNoPageIsRefused() async throws {
        let rig = await rig()
        for url in ["file:///etc/passwd", "about:blank", "not an address"] {
            let answer = await rig.door.answer(typed(url: url), from: .host)
            XCTAssertEqual(try reason(answer), "page", url)
        }
    }

    func testTheProviderMayAskNoneOfThem() async throws {
        let rig = await rig()
        for request in [typed(), order(), BridgeRequest.never(url: Self.page)] {
            let answer = await rig.door.answer(request, from: .autofill)
            XCTAssertEqual(try reason(answer), "page")
        }
        XCTAssertFalse(rig.backend.calls.contains("create"))
        XCTAssertTrue(rig.preferences.settings.browser.neverSave.isEmpty)
    }

    func testAnIconIsTheAppsOwnAndASmallOne() async throws {
        let small = await rig { host in host == "shop.example.test" ? Data([1, 2, 3]) : nil }
        let answer = await small.door.answer(typed(), from: .host)
        XCTAssertEqual(try said(answer)["icon"] as? String, Data([1, 2, 3]).base64EncodedString())
        let big = await rig { _ in Data(count: SaveDoor.mostIcon + 1) }
        let left = await big.door.answer(typed(), from: .host)
        XCTAssertNil(try said(left)["icon"])
    }

    // MARK: save

    func testANewLoginIsMadeOnceAtThePagesOrigin() async throws {
        let rig = await rig()
        let password = SecretBytes(Self.typed)
        let answer = await rig.door.answer(order(password: password), from: .host)
        let id = try XCTUnwrap(try said(answer)["id"] as? String)
        XCTAssertEqual(answer.type, "saved")
        XCTAssertEqual(try said(answer)["title"] as? String, "example.test")
        let item = try XCTUnwrap(rig.store.entry(id: id)?.item)
        XCTAssertEqual(item.login?.username, "kanarya@example.test")
        XCTAssertEqual(item.login?.password, Self.typed)
        XCTAssertEqual(item.login?.uris.map(\.uri), [Self.site], "not the page's whole address, which held a query")
        XCTAssertEqual(rig.backend.calls.filter { $0 == "create" }.count, 1)
        XCTAssertTrue(password.isWiped)
        XCTAssertTrue(rig.authoriser.asked.isEmpty, "nothing is overwritten")
        XCTAssertFalse(String(decoding: answer.body, as: UTF8.self).contains(Self.typed))

        let again = await rig.door.answer(typed(), from: .host)
        XCTAssertEqual(try state(again), "same", "and it is known at once")
    }

    func testAPortStaysAndADefaultOneDoesNot() async throws {
        let rig = await rig()
        for (url, kept) in [("https://shop.example.test:8443/in", "https://shop.example.test:8443"),
                            ("http://192.168.1.1/admin", "http://192.168.1.1")] {
            let answer = await rig.door.answer(order(url: url), from: .host)
            let id = try XCTUnwrap(try said(answer)["id"] as? String)
            XCTAssertEqual(rig.store.entry(id: id)?.item.login?.uris.map(\.uri), [kept])
        }
    }

    func testAnUpdateChangesOneLoginUnderAFingerAndKeepsTheOldInTheHistory() async throws {
        let rig = await rig([login("a", "kanarya@example.test", Self.held), login("b", "other", "kanarya-else")])
        let password = SecretBytes(Self.typed)
        let answer = await rig.door.answer(order("a", password: password), from: .host)
        XCTAssertEqual(answer.type, "saved")
        XCTAssertEqual(rig.authoriser.asked, [.overwrite])
        let item = try XCTUnwrap(rig.store.entry(id: "a")?.item)
        XCTAssertEqual(item.login?.password, Self.typed)
        XCTAssertEqual(item.passwordHistory.first?.password, Self.held)
        XCTAssertEqual(rig.store.entry(id: "b")?.item.login?.password, "kanarya-else")
        XCTAssertEqual(rig.store.entry(id: "a")?.item.login?.uris.map(\.uri), [Self.site], "the login's addresses stay")
        XCTAssertFalse(rig.backend.calls.contains("create"))
        XCTAssertTrue(password.isWiped)
    }

    func testAnUpdateAlwaysTakesAFingerAndARefusedOneWritesNothing() async throws {
        let rig = await rig([login("a", "kanarya@example.test", Self.held)])
        rig.authoriser.answer = false
        let password = SecretBytes(Self.typed)
        let answer = await rig.door.answer(order("a", password: password), from: .host)
        XCTAssertEqual(try reason(answer), "declined")
        XCTAssertEqual(rig.store.entry(id: "a")?.item.login?.password, Self.held)
        XCTAssertFalse(rig.backend.calls.contains("save"))
        XCTAssertTrue(password.isWiped)

        rig.authoriser.answer = true
        _ = await rig.door.answer(order("a"), from: .host)
        _ = await rig.door.answer(order("a", password: SecretBytes("kanarya-third")), from: .host)
        XCTAssertEqual(rig.authoriser.asked, [.overwrite, .overwrite, .overwrite], "a yes is not kept")
    }

    func testAnUpdateGivesAUsernameToALoginWithNoneAndLeavesOneThatHasOne() async throws {
        let rig = await rig([login("a", nil, Self.held), login("b", "kept", "kanarya-else")])
        _ = await rig.door.answer(order("a"), from: .host)
        _ = await rig.door.answer(order("b", password: SecretBytes("kanarya-third")), from: .host)
        XCTAssertEqual(rig.store.entry(id: "a")?.item.login?.username, "kanarya@example.test")
        XCTAssertEqual(rig.store.entry(id: "b")?.item.login?.username, "kept")
    }

    func testAPageCannotChangeAnotherSitesLogin() async throws {
        let rig = await rig([login("a", "kanarya@example.test", Self.held, at: "https://elsewhere.test")])
        let answer = await rig.door.answer(order("a"), from: .host)
        XCTAssertEqual(try reason(answer), "page")
        XCTAssertTrue(rig.authoriser.asked.isEmpty, "nobody is asked for what cannot be done")
        XCTAssertEqual(rig.store.entry(id: "a")?.item.login?.password, Self.held)

        let gone = await rig.door.answer(order("nobody"), from: .host)
        XCTAssertEqual(try reason(gone), "gone")
    }

    func testAPlainPageCannotChangeALoginSavedForASecureOne() async throws {
        let rig = await rig([login("a", "kanarya@example.test", Self.held)])
        let answer = await rig.door.answer(order("a", url: "http://shop.example.test/login"), from: .host)
        XCTAssertEqual(try reason(answer), "insecure")
    }

    func testALockUnderTheFingerWritesNothing() async throws {
        let rig = await rig([login("a", "kanarya@example.test", Self.held)])
        rig.authoriser.holds = true
        let door = rig.door
        let request = order("a")
        let asking = Task { await door.answer(request, from: .host) }
        while rig.authoriser.asked.isEmpty { await Task.yield() }
        await rig.store.lock()
        let answer = await asking.value
        XCTAssertNotEqual(answer.type, "saved")
        XCTAssertFalse(rig.backend.calls.contains("save"))
    }

    func testOverAShutVaultNothingIsWrittenAndThePasswordIsWiped() async throws {
        let rig = await rig()
        await rig.store.lock()
        let password = SecretBytes(Self.typed)
        let answer = await rig.door.answer(order(password: password), from: .host)
        XCTAssertEqual(answer.type, "locked")
        XCTAssertTrue(password.isWiped)
    }

    func testARefusalByTheEngineIsSaidAndChangesNothing() async throws {
        let rig = await rig()
        rig.backend.refuse("item", with: .refused("no"))
        let answer = await rig.door.answer(order(), from: .host)
        XCTAssertEqual(try reason(answer), "unsaved")
    }

    // MARK: never

    func testAHostToldNeverToAskIsKeptAloneAndNeverAsksAgain() async throws {
        let rig = await rig()
        _ = await rig.door.answer(.never(url: Self.page), from: .host)
        _ = await rig.door.answer(.never(url: Self.page), from: .safari)
        XCTAssertEqual(rig.preferences.settings.browser.neverSave, ["shop.example.test"], "a host, once, and no path")
        let answer = await rig.door.answer(typed(), from: .host)
        XCTAssertEqual(try state(answer), "never")
        XCTAssertEqual(try listed(answer), [])
        let other = await rig.door.answer(typed(url: "https://other.example.test/"), from: .host)
        XCTAssertEqual(try state(other), "new", "a host and not the site")
    }

    func testTheHostIsKeptThroughTheFileAndABadOneCostsOnlyItself() throws {
        var choices = BrowserChoices()
        choices.neverSave = ["shop.example.test"]
        let decoded = try JSONDecoder().decode(BrowserChoices.self, from: JSONEncoder().encode(choices))
        XCTAssertEqual(decoded.neverSave, ["shop.example.test"])
        let older = try JSONDecoder().decode(BrowserChoices.self, from: Data(#"{"inOrion":true}"#.utf8))
        XCTAssertEqual(older.neverSave, [])
        XCTAssertTrue(older.inOrion)
    }

    // MARK: The wire

    private func request(_ fields: [String: Any]) throws -> BridgeRequest? {
        BridgeRequest(try JSONSerialization.data(withJSONObject: fields.merging(["v": 1]) { $1 }))
    }

    func testASaveCrossesAsSecretBytesAndSaysNothingOfThem() throws {
        let sent = Data(Self.typed.utf8).base64EncodedString()
        let read = try request(["type": "save", "url": Self.page, "id": "a", "username": "u", "password": sent])
        guard case .save(let order)? = read else { return XCTFail("not a save") }
        XCTAssertEqual(order.id, "a")
        XCTAssertEqual(order.username, "u")
        XCTAssertTrue(order.password.matches(SecretBytes(Self.typed)))
        XCTAssertEqual(read?.redactedLabel, "BridgeRequest(save a)")
        XCTAssertFalse("\(order)".contains(Self.typed))
    }

    func testWhatTheWireDoesNotHaveClosesTheConnection() throws {
        let fine = Data("x".utf8).base64EncodedString()
        for fields: [String: Any] in [
            ["type": "save", "url": Self.page],
            ["type": "save", "url": Self.page, "password": ""],
            ["type": "save", "password": fine],
            ["type": "save", "url": Self.page, "password": "not base64!"],
            ["type": "known", "url": Self.page],
            ["type": "known", "url": Self.page, "key": fine],
            ["type": "known", "key": fine, "mark": fine],
            ["type": "never"],
        ] {
            XCTAssertNil(try request(fields), "\(fields)")
        }
    }
}
