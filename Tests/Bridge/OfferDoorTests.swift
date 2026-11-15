import Foundation
import XCTest
@testable import OriPass

/// What a field with no login is offered: `usernames` and `generate`, over the
/// fake backend, with logins and identities of the test's.
@MainActor
final class OfferDoorTests: XCTestCase {
    private static let page = "https://hic.example.test/kayit"

    private func login(_ id: String, _ username: String?, password: String = "kanarya-offer-password",
                       deleted: Bool = false, archived: Bool = false) -> JSONValue {
        let template = DemoVault.objects().items.first { $0["type"]?.int == 1 } ?? .null
        var made = template.setting(["id"], to: .string(id))
            .setting(["login", "username"], to: JSONValue(username))
            .setting(["login", "password"], to: .string(password))
        if deleted { made = made.setting(["deletedDate"], to: .string("2026-10-01T00:00:00.000Z")) }
        if archived { made = made.setting(["archivedDate"], to: .string("2026-10-01T00:00:00.000Z")) }
        return made
    }

    private func identity(_ id: String, email: String) -> JSONValue {
        let template = DemoVault.objects().items.first { $0["type"]?.int == 4 } ?? .null
        return template.setting(["id"], to: .string(id)).setting(["identity", "email"], to: .string(email))
    }

    private func rig(_ items: [JSONValue], generator: @escaping () -> GeneratorSettings = { GeneratorSettings() }) async -> (door: BrowserDoor, store: VaultStore, backend: FakeBackend) {
        let backend = FakeBackend(items: items, folders: [], password: DemoVault.password)
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        let reprompt = Reprompt(store: store, authoriser: FakeAuthoriser())
        let door = BrowserDoor(store: store, reprompt: reprompt, preferences: Preferences(), generator: generator)
        await store.unlock(password: SecretBytes(DemoVault.password))
        await store.indexing?.value
        return (door, store, backend)
    }

    private func said(_ answer: BridgeAnswer) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: answer.body) as? [String: Any])
    }

    private func words(_ answer: BridgeAnswer) throws -> [String] {
        XCTAssertEqual(answer.type, "usernames")
        return try said(answer)["usernames"] as? [String] ?? []
    }

    private func request(_ fields: [String: Any]) -> BridgeRequest? {
        (try? JSONSerialization.data(withJSONObject: fields.merging(["v": 1]) { $1 })).flatMap(BridgeRequest.init)
    }

    // MARK: usernames

    func testTheMostUsedComesFirstOneRowHoweverItIsSpelled() async throws {
        let (door, _, _) = await rig([login("1", "b@example.test"), login("2", "a@example.test"), login("3", "A@Example.test"),
                                      login("4", "name"), login("5", nil), login("6", "  ")])
        let answer = await door.answer(.usernames(url: Self.page, addressesOnly: false), from: .safari)
        XCTAssertEqual(try words(answer), ["a@example.test", "b@example.test", "name"])
    }

    func testTheTrashAndTheArchiveDoNotCount() async throws {
        let (door, _, _) = await rig([login("1", "here"), login("2", "binned", deleted: true), login("3", "shelved", archived: true)])
        let answer = await door.answer(.usernames(url: Self.page, addressesOnly: false), from: .host)
        XCTAssertEqual(try words(answer), ["here"])
    }

    func testAnIdentitysEmailComesBehindTheLoginsOnce() async throws {
        let (door, _, _) = await rig([login("1", "first@example.test"), identity("2", email: "own@example.test"),
                                      identity("3", email: "First@example.test")])
        let answer = await door.answer(.usernames(url: Self.page, addressesOnly: false), from: .host)
        XCTAssertEqual(try words(answer), ["first@example.test", "own@example.test"])
    }

    func testAnAddressFieldHearsOnlyAddresses() async throws {
        let (door, _, _) = await rig([login("1", "name"), login("2", "name"), login("3", "one@example.test")])
        let answer = await door.answer(.usernames(url: Self.page, addressesOnly: true), from: .host)
        XCTAssertEqual(try words(answer), ["one@example.test"], "what was asked and no more")
    }

    func testNoMessageListsTheVault() async throws {
        let (door, _, _) = await rig((0..<30).map { login("\($0)", "user\($0)") })
        let answer = await door.answer(.usernames(url: Self.page, addressesOnly: false), from: .host)
        XCTAssertEqual(try words(answer).count, OfferDoor.mostUsernames)
    }

    func testTheAnswerHoldsTheWordsAndNothingElseOfAnyLogin() async throws {
        let (door, _, _) = await rig([login("1", "name", password: "kanarya-held")])
        let answer = await door.answer(.usernames(url: Self.page, addressesOnly: false), from: .host)
        let text = String(decoding: answer.body, as: UTF8.self)
        XCTAssertFalse(text.contains("kanarya-held"))
        XCTAssertEqual(Set(try said(answer).keys), ["v", "type", "usernames"], "no id, no title and no site")
    }

    func testOnlyAPagesCallerAsksAndOnlyForAPage() async throws {
        let (door, _, _) = await rig([login("1", "name")])
        let provider = await door.answer(.usernames(url: Self.page, addressesOnly: false), from: .autofill)
        XCTAssertEqual(try said(provider)["reason"] as? String, "page")
        let noPage = await door.answer(.usernames(url: "file:///etc/hosts", addressesOnly: false), from: .host)
        XCTAssertEqual(try said(noPage)["reason"] as? String, "page")
        let generated = await door.answer(.generate(url: Self.page, most: nil), from: .autofill)
        XCTAssertEqual(try said(generated)["reason"] as? String, "page")
    }

    func testAShutVaultSaysSo() async throws {
        let (door, store, _) = await rig([login("1", "name")])
        await store.lock()
        let words = await door.answer(.usernames(url: Self.page, addressesOnly: false), from: .host)
        XCTAssertEqual(words.type, "locked")
        let made = await door.answer(.generate(url: Self.page, most: nil), from: .host)
        XCTAssertEqual(made.type, "locked")
    }

    func testBothAreReadFromTheWire() throws {
        guard case .usernames(let url, let addressesOnly)? = request(["type": "usernames", "url": Self.page, "address": true]) else {
            return XCTFail("usernames")
        }
        XCTAssertEqual(url, Self.page)
        XCTAssertTrue(addressesOnly)
        guard case .generate(_, let most)? = request(["type": "generate", "url": Self.page, "most": 16]) else {
            return XCTFail("generate")
        }
        XCTAssertEqual(most, 16)
        XCTAssertNil(request(["type": "usernames"]), "a page's address is part of the message")
        XCTAssertNil(request(["type": "generate"]))
    }

    func testARequestSaysItsKindAndNoMore() throws {
        XCTAssertEqual(BridgeRequest.usernames(url: Self.page, addressesOnly: false).redactedLabel, "BridgeRequest(usernames)")
        XCTAssertEqual(BridgeRequest.generate(url: Self.page, most: nil).redactedLabel, "BridgeRequest(generate)")
        XCTAssertEqual(BridgeAnswer.generated("kanarya-secret").redactedLabel, "BridgeAnswer(generated)")
    }

    // MARK: generate

    func testAPasswordComesFromTheEngineByTheControlsAsTheyStand() async throws {
        var settings = GeneratorSettings()
        settings.length = 31
        settings.symbols = false
        let (door, _, _) = await rig([], generator: { settings })
        let answer = await door.answer(.generate(url: Self.page, most: nil), from: .host)
        XCTAssertEqual(answer.type, "generated")
        XCTAssertEqual(try said(answer)["password"] as? String, DemoVault.generated(.random(length: 31, digits: true, symbols: false)))
    }

    func testAFieldsLimitHoldsAndAPINIsNoPasswordForASite() {
        var settings = GeneratorSettings()
        settings.length = 30
        XCTAssertEqual(settings.recipe(forAFieldOf: 12), .random(length: 12, digits: true, symbols: true))
        XCTAssertEqual(settings.recipe(forAFieldOf: 64), .random(length: 30, digits: true, symbols: true))
        XCTAssertEqual(settings.recipe(forAFieldOf: 2), .random(length: ServeBackend.shortest, digits: true, symbols: true))
        settings.kind = .pin
        XCTAssertEqual(settings.recipe(forAFieldOf: nil), GeneratorSettings().recipe)
        settings.kind = .memorable
        XCTAssertEqual(settings.recipe(forAFieldOf: nil), settings.recipe)
        XCTAssertEqual(settings.recipe(forAFieldOf: 16), .random(length: 16, digits: true, symbols: true))
    }
}
