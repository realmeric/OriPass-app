import Foundation
import XCTest
@testable import OriPass

/// The door's answers, over a socketpair and the fake backend: no file and
/// no peer check, the test is the caller. The demo's GitHub is the login
/// that asks, and its İş Bankası has a code.
@MainActor
final class BridgeTests: XCTestCase {
    private static let origin = "chrome-extension://abcdefghijklmnop/"
    private static let orion = "com.kagi.kagimacOS"

    private var ends: [Int32] = []
    private var connections: [BridgeConnection] = []

    override func tearDown() {
        connections.forEach { $0.cut() }
        connections = []
        ends.forEach { close($0) }
        ends = []
    }

    private struct Rig {
        let store: VaultStore
        let authoriser: FakeAuthoriser
        let reprompt: Reprompt
        let stage: RememberingBrowserStage
        let door: BrowserDoor
        let preferences: Preferences
    }

    private func rig(allowing origins: [String] = [origin], open: Bool = true,
                     change: (JSONValue) -> JSONValue = { $0 }) async -> Rig {
        let vault = DemoVault.objects()
        let backend = FakeBackend(items: vault.items.map(change), folders: vault.folders, password: DemoVault.password)
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        let authoriser = FakeAuthoriser()
        let reprompt = Reprompt(store: store, authoriser: authoriser)
        let preferences = Preferences()
        preferences.settings.browser.inOrion = true
        origins.forEach { preferences.settings.browser.answer($0, allowed: true) }
        let stage = RememberingBrowserStage()
        let door = BrowserDoor(store: store, reprompt: reprompt, preferences: preferences, stage: stage)
        if open { await store.unlock(password: SecretBytes(DemoVault.password)) }
        await store.indexing?.value
        return Rig(store: store, authoriser: authoriser, reprompt: reprompt, stage: stage, door: door,
                   preferences: preferences)
    }

    /// The caller's end of a connection the door is serving.
    private func connect(_ rig: Rig, as caller: BridgeCaller = .host) throws -> Int32 {
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
        return pair[1]
    }

    private func say(_ message: [String: Any], on end: Int32) throws {
        try BridgeWire.write(JSONSerialization.data(withJSONObject: message), to: end)
    }

    /// What the door said next, as the bytes it was, and nil if it hung up.
    private func raw(on end: Int32) async -> Data? {
        await Task.detached { try? BridgeWire.read(from: end) }.value
    }

    private func hear(on end: Int32) async throws -> [String: Any]? {
        guard let body = await raw(on: end) else { return nil }
        return try JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    private func heard(on end: Int32) async throws -> [String: Any] {
        let said = try await hear(on: end)
        return try XCTUnwrap(said, "the door hung up")
    }

    private func hello(on end: Int32, origin: String = origin) async throws -> String? {
        try say(["v": 1, "type": "hello", "origin": origin, "browser": Self.orion], on: end)
        return try await hear(on: end)?["type"] as? String
    }

    private func ready(_ rig: Rig) async throws -> Int32 {
        let end = try connect(rig)
        let said = try await hello(on: end)
        XCTAssertEqual(said, "ready")
        return end
    }

    private func item(_ name: String, in rig: Rig) throws -> Item {
        try XCTUnwrap(rig.store.shelves.all.first { $0.item.name == name }?.item)
    }

    private func until(_ isSo: () -> Bool) async {
        for _ in 0..<400 where !isSo() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: The list

    func testTheListHoldsNoValueOfASecretField() async throws {
        let rig = await rig()
        let end = try await ready(rig)
        try say(["v": 1, "type": "logins", "url": "https://www.isbank.com.tr/giris"], on: end)
        let got = await raw(on: end)
        let body = try XCTUnwrap(got)
        let said = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(said["type"] as? String, "logins")
        XCTAssertEqual(said["site"] as? String, "isbank.com.tr")
        let logins = try XCTUnwrap(said["logins"] as? [[String: Any]])
        let bank = try item("İş Bankası", in: rig)
        XCTAssertEqual(logins.first?["id"] as? String, bank.id)
        XCTAssertEqual(logins.first?["title"] as? String, bank.name)
        XCTAssertEqual(Set(logins.flatMap(\.keys)), ["id", "title", "username"])

        let text = String(decoding: body, as: UTF8.self)
        let login = try XCTUnwrap(bank.login)
        for secret in [login.password, login.totp].compactMap({ $0 }) {
            XCTAssertFalse(text.contains(secret), "a hidden value in the list")
        }
    }

    func testAPageNoLoginHoldsForIsAnEmptyList() async throws {
        let rig = await rig()
        let end = try await ready(rig)
        try say(["v": 1, "type": "logins", "url": "https://nobody.invalid/"], on: end)
        let said = try await heard(on: end)
        XCTAssertEqual(said["type"] as? String, "logins")
        XCTAssertEqual((said["logins"] as? [Any])?.count, 0)
    }

    func testAskedBeforeTheIndexIsMadeTheListWaitsForIt() async throws {
        let rig = await rig(open: false)
        let opening = Task { await rig.store.unlock(password: SecretBytes(DemoVault.password)) }
        await until { rig.store.state == .unlocked }
        let end = try await ready(rig)
        try say(["v": 1, "type": "logins", "url": "https://www.isbank.com.tr/"], on: end)
        let said = try await heard(on: end)
        XCTAssertFalse((said["logins"] as? [Any] ?? []).isEmpty)
        _ = await opening.value
    }

    // MARK: A fill

    func testAFillAnswersTheLoginAndItsCode() async throws {
        let rig = await rig()
        let bank = try item("İş Bankası", in: rig)
        let end = try await ready(rig)
        try say(["v": 1, "type": "fill", "id": bank.id, "url": "https://www.isbank.com.tr/giris"], on: end)
        let said = try await heard(on: end)
        XCTAssertEqual(said["type"] as? String, "filled")
        XCTAssertEqual(said["username"] as? String, bank.login?.username)
        XCTAssertEqual(said["password"] as? String, bank.login?.password)
        let code = bank.login?.totp.flatMap { Totp($0) }?.code(at: rig.store.now())
        XCTAssertEqual(said["code"] as? String, code)
        XCTAssertNotNil(code)
    }

    func testAFillOnAPageTheLoginDoesNotMatchIsRefused() async throws {
        let rig = await rig()
        let bank = try item("İş Bankası", in: rig)
        let end = try await ready(rig)
        try say(["v": 1, "type": "fill", "id": bank.id, "url": "https://isbank.com.tr.example.org/"], on: end)
        let said = try await heard(on: end)
        XCTAssertEqual(said["type"] as? String, "refused")
        XCTAssertEqual(said["reason"] as? String, "page")
        XCTAssertNil(said["password"])
    }

    func testAFillOfAnIdNobodyHasAndOfSomethingThatIsNoPageAreRefused() async throws {
        let rig = await rig()
        let bank = try item("İş Bankası", in: rig)
        let end = try await ready(rig)
        try say(["v": 1, "type": "fill", "id": "nobody", "url": "https://www.isbank.com.tr/"], on: end)
        var said = try await heard(on: end)
        XCTAssertEqual(said["reason"] as? String, "gone")
        try say(["v": 1, "type": "fill", "id": bank.id, "url": "file:///etc/hosts"], on: end)
        said = try await heard(on: end)
        XCTAssertEqual(said["reason"] as? String, "page")
    }

    func testAnItemInTheTrashOrTheArchiveIsNeitherListedNorFilled() async throws {
        let rig = await rig()
        let bank = try item("İş Bankası", in: rig)
        let page = "https://www.isbank.com.tr/giris"
        for change in [ItemChange.archive, .delete] {
            _ = try await rig.store.apply(change, to: bank.id)
            await rig.store.indexing?.value
            let end = try await ready(rig)
            try say(["v": 1, "type": "logins", "url": page], on: end)
            let listed = try await heard(on: end)
            XCTAssertFalse((listed["logins"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == bank.id })
            try say(["v": 1, "type": "fill", "id": bank.id, "url": page], on: end)
            let said = try await heard(on: end)
            XCTAssertEqual(said["reason"] as? String, "gone", "\(change)")
            if change == .archive { _ = try await rig.store.apply(.unarchive, to: bank.id) }
        }
    }

    func testAnHTTPPageGetsNoLoginSavedUnderHTTPS() async throws {
        let rig = await rig()
        let bank = try item("İş Bankası", in: rig)
        let page = "http://www.isbank.com.tr/giris"
        let end = try await ready(rig)
        try say(["v": 1, "type": "logins", "url": page], on: end)
        let listed = try await heard(on: end)
        XCTAssertEqual((listed["logins"] as? [Any])?.count, 0)
        try say(["v": 1, "type": "fill", "id": bank.id, "url": page], on: end)
        let said = try await heard(on: end)
        XCTAssertEqual(said["reason"] as? String, "insecure")
    }

    func testAnAddressWrittenWithNoSchemeIsSavedUnderNeither() async throws {
        let bare = "192.168.1.1"
        let rig = await rig { item in
            guard item["name"]?.string == "İş Bankası" else { return item }
            return item.setting(["login", "uris"], to: .array([.object(["match": .null, "uri": .string(bare)])]))
        }
        let bank = try item("İş Bankası", in: rig)
        let end = try await ready(rig)
        try say(["v": 1, "type": "fill", "id": bank.id, "url": "http://\(bare)/"], on: end)
        let said = try await heard(on: end)
        XCTAssertEqual(said["type"] as? String, "filled")
    }

    func testAFillOfAnItemThatAsksWaitsForReprompt() async throws {
        let rig = await rig()
        rig.authoriser.holds = true
        let github = try item("GitHub", in: rig)
        let page = try XCTUnwrap(github.login?.uris.first?.uri)
        let end = try await ready(rig)
        try say(["v": 1, "type": "fill", "id": github.id, "url": page], on: end)
        await until { rig.authoriser.asked == [.fill] }
        XCTAssertEqual(rig.authoriser.asked, [.fill])

        var chunk: UInt8 = 0
        XCTAssertEqual(recv(end, &chunk, 1, MSG_PEEK | MSG_DONTWAIT), -1, "answered before the question was")

        rig.authoriser.release(true)
        let said = try await heard(on: end)
        XCTAssertEqual(said["password"] as? String, github.login?.password)
    }

    func testANoToAnItemThatAsksFillsNothing() async throws {
        let rig = await rig()
        rig.authoriser.answer = false
        let github = try item("GitHub", in: rig)
        let page = try XCTUnwrap(github.login?.uris.first?.uri)
        let end = try await ready(rig)
        try say(["v": 1, "type": "fill", "id": github.id, "url": page], on: end)
        let said = try await heard(on: end)
        XCTAssertEqual(said["type"] as? String, "refused")
        XCTAssertEqual(said["reason"] as? String, "declined")
        XCTAssertNil(said["password"])
    }

    func testALockUnderTheQuestionFillsNothing() async throws {
        let rig = await rig()
        rig.authoriser.holds = true
        let github = try item("GitHub", in: rig)
        let page = try XCTUnwrap(github.login?.uris.first?.uri)
        let end = try await ready(rig)
        try say(["v": 1, "type": "fill", "id": github.id, "url": page], on: end)
        await until { rig.authoriser.asked == [.fill] }
        await rig.store.lock()
        let said = try await hear(on: end)
        XCTAssertEqual(said?["reason"] as? String, "declined")
        XCTAssertNil(said?["password"])
    }

    // MARK: The wire

    func testALengthOverTheCapClosesTheConnection() async throws {
        let rig = await rig()
        let end = try await ready(rig)
        var length = UInt32(BridgeWire.most + 1).littleEndian
        XCTAssertEqual(write(end, &length, 4), 4)
        let said = await raw(on: end)
        XCTAssertNil(said)
    }

    func testAMessageAtTheCapIsRead() async throws {
        let rig = await rig()
        let end = try await ready(rig)
        let pad = String(repeating: " ", count: BridgeWire.most - 64)
        let message = Data("{\"v\":1,\"type\":\"logins\",\"url\":\"https://example.org/\"\(pad)}".utf8)
        XCTAssertLessThanOrEqual(message.count, BridgeWire.most)
        let writing = Task.detached { try BridgeWire.write(message, to: end) }
        let said = try await heard(on: end)
        XCTAssertEqual(said["type"] as? String, "logins")
        try await writing.value
    }

    func testAnythingTheWireDoesNotHaveClosesTheConnection() async throws {
        let rig = await rig()
        let wrong: [[String: Any]] = [
            ["v": 2, "type": "hello", "origin": Self.origin, "browser": Self.orion],
            ["v": 1, "type": "sing"],
            ["v": 1, "type": "logins", "url": "https://www.isbank.com.tr/"],
        ]
        for message in wrong {
            let end = try connect(rig)
            try say(message, on: end)
            let said = await raw(on: end)
            XCTAssertNil(said, "\(message)")
        }
        let end = try connect(rig)
        try BridgeWire.write(Data("not json".utf8), to: end)
        let said = await raw(on: end)
        XCTAssertNil(said)
    }

    func testASecondHelloClosesTheConnection() async throws {
        let rig = await rig()
        let end = try await ready(rig)
        try say(["v": 1, "type": "hello", "origin": "chrome-extension://other/", "browser": Self.orion], on: end)
        let said = await raw(on: end)
        XCTAssertNil(said)
    }

    // MARK: Who

    func testAnUnknownOriginGetsNoListAndRaisesTheCard() async throws {
        let rig = await rig(allowing: [])
        let end = try connect(rig)
        let said = try await hello(on: end)
        XCTAssertEqual(said, "unknown")
        XCTAssertEqual(rig.stage.showing?.origin, Self.origin)
        XCTAssertEqual(rig.stage.showing?.browser, "Orion")

        try? say(["v": 1, "type": "logins", "url": "https://www.isbank.com.tr/"], on: end)
        let list = await raw(on: end)
        XCTAssertNil(list, "the connection did not end at unknown")
    }

    func testAllowLetsTheOriginInAndNoCardComesUpAgain() async throws {
        let rig = await rig(allowing: [])
        let first = try await hello(on: connect(rig))
        XCTAssertEqual(first, "unknown")
        rig.stage.showing?.allow()
        XCTAssertNil(rig.stage.showing)
        XCTAssertEqual(rig.preferences.settings.browser.allowed, [Self.origin])

        let second = try await hello(on: connect(rig))
        XCTAssertEqual(second, "ready")
        XCTAssertEqual(rig.stage.shows, 1)
    }

    func testDenyIsRememberedAndAsksNoMore() async throws {
        let rig = await rig(allowing: [])
        _ = try await hello(on: connect(rig))
        rig.stage.showing?.deny()
        XCTAssertEqual(rig.preferences.settings.browser.denied, [Self.origin])

        let second = try await hello(on: connect(rig))
        XCTAssertEqual(second, "unknown")
        XCTAssertEqual(rig.stage.shows, 1, "a denied origin raised the card again")
    }

    func testOneCardAtATimeAndTheSecondOriginAsksAfterTheFirstIsAnswered() async throws {
        let rig = await rig(allowing: [])
        let other = "chrome-extension://ponmlkjihgfedcba/"
        _ = try await hello(on: connect(rig))
        let second = try await hello(on: connect(rig), origin: other)
        XCTAssertEqual(second, "unknown")
        XCTAssertEqual(rig.stage.shows, 1)
        XCTAssertEqual(rig.stage.showing?.origin, Self.origin)

        rig.stage.showing?.deny()
        _ = try await hello(on: connect(rig), origin: other)
        XCTAssertEqual(rig.stage.showing?.origin, other)
    }

    func testAHostThatNamesNoOriginOrNoBrowserIsUnknownAndAsksNothing() async throws {
        let rig = await rig(allowing: [])
        let bare = try connect(rig)
        try say(["v": 1, "type": "hello"], on: bare)
        var said = try await hear(on: bare)
        XCTAssertEqual(said?["type"] as? String, "unknown")
        let unnamed = try connect(rig)
        try say(["v": 1, "type": "hello", "origin": Self.origin, "browser": "com.example.browser"], on: unnamed)
        said = try await hear(on: unnamed)
        XCTAssertEqual(said?["type"] as? String, "unknown")
        XCTAssertEqual(rig.stage.shows, 0)
    }

    func testWithOrionsSwitchOffAHostIsUnknownAndNoCardComesUp() async throws {
        let rig = await rig(allowing: [Self.origin])
        rig.preferences.settings.browser.inOrion = false
        var said = try await hello(on: connect(rig))
        XCTAssertEqual(said, "unknown", "what was allowed is not allowed with the switch off")
        said = try await hello(on: connect(rig), origin: "chrome-extension://other/")
        XCTAssertEqual(said, "unknown")
        XCTAssertEqual(rig.stage.shows, 0)

        rig.preferences.settings.browser.inOrion = true
        said = try await hello(on: connect(rig))
        XCTAssertEqual(said, "ready")
    }

    func testTheSafariExtensionNeedsNoCard() async throws {
        let rig = await rig(allowing: [])
        let end = try connect(rig, as: .safari)
        try say(["v": 1, "type": "hello", "browser": "com.apple.Safari"], on: end)
        let said = try await hear(on: end)
        XCTAssertEqual(said?["type"] as? String, "ready")
        XCTAssertEqual(rig.stage.shows, 0)
    }

    func testADoorThatFindsTheVaultLockedSaysSo() async throws {
        let rig = await rig(open: false)
        let end = try connect(rig)
        let said = try await hello(on: end)
        XCTAssertEqual(said, "locked")
        let next = await raw(on: end)
        XCTAssertNil(next, "the connection did not end at locked")
    }

    func testALockTakesTheCardDownUnanswered() async throws {
        let rig = await rig(allowing: [])
        _ = try await hello(on: connect(rig))
        XCTAssertNotNil(rig.stage.showing)
        await rig.store.lock()
        XCTAssertNil(rig.stage.showing)
        XCTAssertNil(rig.door.question)
        XCTAssertTrue(rig.preferences.settings.browser.allowed.isEmpty)
        XCTAssertTrue(rig.preferences.settings.browser.denied.isEmpty)
    }

    // MARK: What it says of itself

    func testAFilledAnswerSaysNothingOfWhatItHolds() {
        let fill = BridgeFill(username: "kanarya-user", password: "kanarya-password", code: "123456")
        let answer = BridgeAnswer.filled(fill)
        for said in ["\(answer)", String(reflecting: answer), "\(fill)", String(reflecting: fill)] {
            XCTAssertFalse(said.contains("kanarya"), said)
            XCTAssertFalse(said.contains("123456"), said)
        }
        var dumped = ""
        dump(answer, to: &dumped)
        XCTAssertFalse(dumped.contains("kanarya"), dumped)
    }
}
