import Foundation
import XCTest
@testable import OriPass

/// A one-time code through the door, over a socketpair and the fake backend:
/// the test is the provider. The bank's login holds a secret and asks for
/// nothing, GitHub's holds one and asks, and Spotify's holds none.
@MainActor
final class CodeDoorTests: XCTestCase {
    private static let bank = "https://www.isbank.com.tr/giris"
    private static let github = "https://github.com/login"
    private static let spotify = "https://accounts.spotify.com/"
    private static let moment = Date(timeIntervalSince1970: 1_000_000_000)

    private var ends: [Int32] = []
    private var connections: [BridgeConnection] = []
    private var clock = CodeDoorTests.moment

    override func setUp() {
        clock = Self.moment
    }

    override func tearDown() {
        connections.forEach { $0.cut() }
        connections = []
        ends.forEach { close($0) }
        ends = []
    }

    private struct Rig {
        let store: VaultStore
        let authoriser: FakeAuthoriser
        let door: BrowserDoor
    }

    private func rig(change: (JSONValue) -> JSONValue = { $0 }) async -> Rig {
        let vault = DemoVault.objects()
        let backend = FakeBackend(items: vault.items.map(change), folders: vault.folders, password: DemoVault.password)
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend, now: { [unowned self] in self.clock })
        let authoriser = FakeAuthoriser()
        let door = BrowserDoor(store: store, reprompt: Reprompt(store: store, authoriser: authoriser), preferences: Preferences())
        await store.unlock(password: SecretBytes(DemoVault.password))
        await store.indexing?.value
        return Rig(store: store, authoriser: authoriser, door: door)
    }

    private func connect(_ rig: Rig, as caller: BridgeCaller = .autofill) async throws -> Int32 {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        var wait = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(pair[1], SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(pair[1], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let door = rig.door
        let connection = BridgeConnection(descriptor: pair[0], caller: caller) { await door.answer($0, from: $1) }
        connection.start()
        connections.append(connection)
        ends.append(pair[1])
        try say(["v": 1, "type": "hello"], on: pair[1])
        let said = try await heard(on: pair[1])
        XCTAssertEqual(said["type"] as? String, "ready")
        return pair[1]
    }

    private func say(_ message: [String: Any], on end: Int32) throws {
        try BridgeWire.write(JSONSerialization.data(withJSONObject: message), to: end)
    }

    private func raw(on end: Int32) async -> Data? {
        await Task.detached { try? BridgeWire.read(from: end) }.value
    }

    private func heard(on end: Int32) async throws -> [String: Any] {
        let body = await raw(on: end)
        let said = try JSONSerialization.jsonObject(with: try XCTUnwrap(body, "the door hung up"))
        return try XCTUnwrap(said as? [String: Any])
    }

    private func list(_ url: String, on end: Int32) async throws -> [[String: Any]] {
        try say(["v": 1, "type": "codes", "url": url], on: end)
        return try await heard(on: end)["logins"] as? [[String: Any]] ?? []
    }

    private func ask(_ id: String, on url: String, end: Int32) throws {
        try say(["v": 1, "type": "code", "id": id, "url": url], on: end)
    }

    private func item(_ name: String, in rig: Rig) throws -> Item {
        try XCTUnwrap(rig.store.shelves.all.first { $0.item.name == name }?.item)
    }

    private func until(_ isSo: () -> Bool) async {
        for _ in 0..<400 where !isSo() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// The demo vault with Spotify's login at the bank's address, changed as
    /// a test needs, so that one page has a login of each kind.
    private func spotifyAtTheBank(_ change: @escaping (JSONValue) -> JSONValue = { $0 }) -> (JSONValue) -> JSONValue {
        { item in
            guard item["name"]?.string == "Spotify" else { return item }
            let uris = JSONValue.array([.object(["match": .null, "uri": .string(Self.bank)])])
            return change(item.setting(["login", "uris"], to: uris))
        }
    }

    // MARK: The list

    func testTheListHoldsTheLoginsForThePageThatCanMakeACode() async throws {
        let rig = await rig(change: spotifyAtTheBank())
        let end = try await connect(rig)
        let rows = try await list(Self.bank, on: end)
        XCTAssertEqual(rows.map { $0["title"] as? String }, ["İş Bankası"])
        XCTAssertEqual(Set(rows.flatMap(\.keys)), ["id", "title", "username"])
        try say(["v": 1, "type": "logins", "url": Self.bank], on: end)
        let logins = try await heard(on: end)["logins"] as? [[String: Any]]
        XCTAssertEqual(logins?.count, 2, "the password's list is another list")
    }

    func testASecretThatDoesNotReadIsNotListed() async throws {
        let rig = await rig { item in
            item["name"]?.string == "İş Bankası" ? item.setting(["login", "totp"], to: .string("1 is not base32")) : item
        }
        let end = try await connect(rig)
        let rows = try await list(Self.bank, on: end)
        XCTAssertEqual(rows.count, 0)
    }

    func testAPageNoLoginHoldsForListsNothing() async throws {
        let rig = await rig()
        let end = try await connect(rig)
        let rows = try await list(Self.spotify, on: end)
        XCTAssertEqual(rows.count, 0)
    }

    // MARK: The code

    func testAMatchingLoginsCodeIsItsCodeAtThatMoment() async throws {
        let rig = await rig()
        let bank = try item("İş Bankası", in: rig)
        let end = try await connect(rig)
        try ask(bank.id, on: Self.bank, end: end)
        let said = try await heard(on: end)
        XCTAssertEqual(said["type"] as? String, "code")
        XCTAssertEqual(said["code"] as? String, Totp(DemoVault.totpSecrets[0])?.code(at: Self.moment))
        XCTAssertEqual(rig.authoriser.asked, [], "the item does not ask")
    }

    func testTheAnswerHoldsTheCodeAndNeverTheSecret() async throws {
        let rig = await rig()
        let bank = try item("İş Bankası", in: rig)
        let end = try await connect(rig)
        try ask(bank.id, on: Self.bank, end: end)
        let heard = await raw(on: end)
        let body = try XCTUnwrap(heard)
        let said = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(said.keys), ["v", "type", "code"])
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(text.contains(DemoVault.totpSecrets[0]))
        XCTAssertFalse(text.contains(try XCTUnwrap(bank.login?.password)))
    }

    func testALoginWithNoSecretHasNoCodeAndAsksNobody() async throws {
        let rig = await rig(change: spotifyAtTheBank { $0.setting(["reprompt"], to: .int(1)) })
        let spotify = try item("Spotify", in: rig)
        let end = try await connect(rig)
        try ask(spotify.id, on: Self.bank, end: end)
        let said = try await heard(on: end)
        XCTAssertEqual(said["type"] as? String, "refused")
        XCTAssertEqual(said["reason"] as? String, "gone")
        XCTAssertNil(said["code"])
        XCTAssertEqual(rig.authoriser.asked, [])
    }

    func testAnIdNobodyHasIsGone() async throws {
        let rig = await rig()
        let end = try await connect(rig)
        try ask("nobody", on: Self.bank, end: end)
        let said = try await heard(on: end)
        XCTAssertEqual(said["reason"] as? String, "gone")
    }

    func testAnotherPagesLoginIsRefusedBeforeAnyoneIsAsked() async throws {
        let rig = await rig()
        let github = try item("GitHub", in: rig)
        let end = try await connect(rig)
        try ask(github.id, on: Self.bank, end: end)
        let said = try await heard(on: end)
        XCTAssertEqual(said["reason"] as? String, "page")
        XCTAssertNil(said["code"])
        XCTAssertEqual(rig.authoriser.asked, [])
    }

    func testAnInsecurePageIsRefused() async throws {
        let rig = await rig()
        let bank = try item("İş Bankası", in: rig)
        let end = try await connect(rig)
        try ask(bank.id, on: "http://www.isbank.com.tr/giris", end: end)
        let said = try await heard(on: end)
        XCTAssertEqual(said["reason"] as? String, "insecure")
        XCTAssertNil(said["code"])
    }

    func testALoginInTheTrashHasNoCode() async throws {
        let rig = await rig { item in
            item["name"]?.string == "İş Bankası" ? item.setting(["deletedDate"], to: .string("2026-10-01T00:00:00.000Z")) : item
        }
        let bank = try XCTUnwrap(rig.store.shelves.trash.first { $0.item.name == "İş Bankası" })
        let end = try await connect(rig)
        let rows = try await list(Self.bank, on: end)
        XCTAssertEqual(rows.count, 0)
        try ask(bank.id, on: Self.bank, end: end)
        let said = try await heard(on: end)
        XCTAssertEqual(said["reason"] as? String, "gone")
    }

    // MARK: Who says yes

    func testAnItemThatAsksWaitsForRepromptAndTheCodeIsMadeAfterIt() async throws {
        let rig = await rig()
        let github = try item("GitHub", in: rig)
        rig.authoriser.holds = true
        let end = try await connect(rig)
        try ask(github.id, on: Self.github, end: end)
        await until { !rig.authoriser.asked.isEmpty }
        XCTAssertEqual(rig.authoriser.asked, [.fill])
        clock = Self.moment.addingTimeInterval(120)
        rig.authoriser.release(true)
        let said = try await heard(on: end)
        let totp = try XCTUnwrap(github.oneTimeCode)
        XCTAssertEqual(said["code"] as? String, totp.code(at: clock))
        XCTAssertNotEqual(said["code"] as? String, totp.code(at: Self.moment))
    }

    func testAnItemAnsweredForIsNotAskedAboutAgain() async throws {
        let rig = await rig()
        let github = try item("GitHub", in: rig)
        let end = try await connect(rig)
        for _ in 0..<2 {
            try ask(github.id, on: Self.github, end: end)
            let said = try await heard(on: end)
            XCTAssertEqual(said["type"] as? String, "code")
        }
        XCTAssertEqual(rig.authoriser.asked, [.fill])
    }

    func testARefusedFingerGivesNothing() async throws {
        let rig = await rig()
        let github = try item("GitHub", in: rig)
        rig.authoriser.answer = false
        let end = try await connect(rig)
        try ask(github.id, on: Self.github, end: end)
        let said = try await heard(on: end)
        XCTAssertEqual(said["reason"] as? String, "declined")
        XCTAssertNil(said["code"])
    }

    func testALockUnderAQuestionIsNoAnswer() async throws {
        let rig = await rig()
        let github = try item("GitHub", in: rig)
        rig.authoriser.holds = true
        let end = try await connect(rig)
        try ask(github.id, on: Self.github, end: end)
        await until { !rig.authoriser.asked.isEmpty }
        await rig.store.lock()
        let said = try await heard(on: end)
        XCTAssertEqual(said["reason"] as? String, "declined")
        XCTAssertNil(said["code"])
        let after = await rig.door.answer(.code(id: github.id, .page(url: Self.github)), from: .autofill)
        XCTAssertEqual(after.type, "locked")
    }

    // MARK: An app

    func testAnAppHearsOnlyWhatIsListedForIt() async throws {
        let rig = await rig { item in
            item["name"]?.string == "Slack" ? item.setting(["login", "totp"], to: .string(DemoVault.totpSecrets[0])) : item
        }
        let slack = try item("Slack", in: rig)
        let bank = try item("İş Bankası", in: rig)
        let app = BridgeApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
        let listed = await rig.door.answer(.codes(.app(app)), from: .autofill)
        guard case .logins(_, let rows) = listed else { return XCTFail("no list") }
        XCTAssertEqual(rows.map(\.id), [slack.id])
        let code = await rig.door.answer(.code(id: slack.id, .app(app)), from: .autofill)
        XCTAssertEqual(code.type, "code")
        let other = await rig.door.answer(.code(id: bank.id, .app(app)), from: .autofill)
        guard case .refused(.page) = other else { return XCTFail("heard \(other.type)") }
    }

    func testAnAppsLoginWithNoSecretIsNotListed() async throws {
        let rig = await rig()
        let app = BridgeApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
        let listed = await rig.door.answer(.codes(.app(app)), from: .autofill)
        guard case .logins(_, let rows) = listed else { return XCTFail("no list") }
        XCTAssertEqual(rows.count, 0)
    }

    // MARK: Who may ask

    func testNoCallerButTheProviderIsAnswered() async throws {
        let rig = await rig()
        let bank = try item("İş Bankası", in: rig)
        for caller in [BridgeCaller.host, .safari] {
            for request in [BridgeRequest.codes(.page(url: Self.bank)), .code(id: bank.id, .page(url: Self.bank))] {
                let answer = await rig.door.answer(request, from: caller)
                guard case .refused(.page) = answer else { return XCTFail("\(caller) heard \(answer.type)") }
            }
        }
    }

    // MARK: The wire

    func testACodeForNeitherAPageNorAnAppClosesTheConnection() {
        for message: [String: Any] in [["v": 1, "type": "code", "id": "a"], ["v": 1, "type": "codes"],
                                       ["v": 1, "type": "code", "url": Self.bank]] {
            let body = try? JSONSerialization.data(withJSONObject: message)
            XCTAssertNil(body.flatMap(BridgeRequest.init))
        }
    }

    func testAnAnswerSaysNothingOfItsCode() {
        let answer = BridgeAnswer.code("123456")
        XCTAssertFalse("\(answer)".contains("123456"))
        XCTAssertFalse(String(reflecting: answer).contains("123456"))
    }
}
