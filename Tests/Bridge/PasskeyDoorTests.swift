import CryptoKit
import Foundation
import XCTest
@testable import OriPass

/// A passkey through the door, over a socketpair and the fake backend: the
/// test is the provider. GitHub's passkey is the demo's, a real key under an
/// invented scalar, and it is the login that asks.
@MainActor
final class PasskeyDoorTests: XCTestCase {
    private static let hash = Data(SHA256.hash(data: Data(#"{"type":"webauthn.get","challenge":"canary"}"#.utf8)))
    private static let key = try! P256.Signing.PrivateKey(rawRepresentation: Data(DemoVault.passkeySeed.utf8))
    private static let id = withUnsafeBytes(of: UUID(uuidString: DemoVault.passkeyCredential)!.uuid) { Data($0) }

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
        let door: BrowserDoor
    }

    private func rig(change: (JSONValue) -> JSONValue = { $0 }) async -> Rig {
        let vault = DemoVault.objects()
        let backend = FakeBackend(items: vault.items.map(change), folders: vault.folders, password: DemoVault.password)
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        let authoriser = FakeAuthoriser()
        let reprompt = Reprompt(store: store, authoriser: authoriser)
        let door = BrowserDoor(store: store, reprompt: reprompt, preferences: Preferences())
        await store.unlock(password: SecretBytes(DemoVault.password))
        return Rig(store: store, authoriser: authoriser, reprompt: reprompt, door: door)
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
        let said = try await hear(on: pair[1])
        XCTAssertEqual(said?["type"] as? String, "ready")
        return pair[1]
    }

    private func say(_ message: [String: Any], on end: Int32) throws {
        try BridgeWire.write(JSONSerialization.data(withJSONObject: message), to: end)
    }

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

    private func list(_ rp: String = "github.com", allowed: [Data] = [], on end: Int32) throws {
        try say(["v": 1, "type": "passkeys", "rp": rp, "allowed": allowed.map { $0.base64EncodedString() }], on: end)
    }

    private func assert(_ id: Data = id, rp: String = "github.com", allowed: [Data] = [], hash: Data = hash,
                        on end: Int32) throws {
        try say(["v": 1, "type": "assert", "id": id.base64EncodedString(), "rp": rp,
                 "allowed": allowed.map { $0.base64EncodedString() }, "hash": hash.base64EncodedString()], on: end)
    }

    private func until(_ isSo: () -> Bool) async {
        for _ in 0..<400 where !isSo() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func assertion(in said: [String: Any]) throws -> (data: Data, signature: P256.Signing.ECDSASignature) {
        XCTAssertEqual(said["type"] as? String, "asserted")
        let assertion = try XCTUnwrap(said["assertion"] as? [String: String])
        let data = try XCTUnwrap(assertion["authenticatorData"].flatMap { Data(base64Encoded: $0) })
        let signature = try XCTUnwrap(assertion["signature"].flatMap { Data(base64Encoded: $0) })
        return (data, try P256.Signing.ECDSASignature(derRepresentation: signature))
    }

    /// The demo vault with a second passkey on its Spotify, which asks for
    /// nothing, changed as a test needs.
    private func withAnotherPasskey(_ change: @escaping ([String: JSONValue]) -> [String: JSONValue] = { $0 }) -> (JSONValue) -> JSONValue {
        { item in
            guard item["name"]?.string == "Spotify" else { return item }
            let entry = change(["credentialId": .string("b64.c3BvdGlmeQ"), "keyAlgorithm": .string("ECDSA"),
                                "keyCurve": .string("P-256"), "keyValue": .string(DemoVault.passkey),
                                "rpId": .string("spotify.com"), "userName": .string("deniz")])
            return item.setting(["login", "fido2Credentials"], to: .array([.object(entry)]))
        }
    }

    // MARK: The list

    func testAListHoldsAnIdATitleAndAUsernameAndNoKey() async throws {
        let rig = await rig()
        let end = try await connect(rig)
        try list(on: end)
        let body = await raw(on: end)
        let text = String(decoding: try XCTUnwrap(body), as: UTF8.self)
        let said = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(body)) as? [String: Any])
        let rows = try XCTUnwrap(said["logins"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["id"] as? String, Self.id.base64EncodedString())
        XCTAssertEqual(rows.first?["title"] as? String, "GitHub")
        XCTAssertEqual(rows.first?["username"] as? String, "deniz")
        XCTAssertEqual(Set(rows.flatMap(\.keys)), ["id", "title", "username"])
        XCTAssertFalse(text.contains(DemoVault.passkey))
        XCTAssertFalse(text.contains(DemoVault.passkeySeed))
    }

    func testAListHoldsNoOtherRelyingPartyAndNoIdThePageDidNotAllow() async throws {
        let rig = await rig()
        let end = try await connect(rig)
        try list("github.com.example.org", on: end)
        var said = try await heard(on: end)
        XCTAssertEqual((said["logins"] as? [Any])?.count, 0)
        try list(allowed: [Data(repeating: 1, count: 16)], on: end)
        said = try await heard(on: end)
        XCTAssertEqual((said["logins"] as? [Any])?.count, 0)
        try list(allowed: [Self.id], on: end)
        said = try await heard(on: end)
        XCTAssertEqual((said["logins"] as? [Any])?.count, 1)
    }

    func testAKeyThatIsNotES256IsNeitherListedNorAnswered() async throws {
        let rig = await rig(change: withAnotherPasskey { entry in
            entry.merging(["keyCurve": .string("P-384")]) { $1 }
        })
        let end = try await connect(rig)
        try list("spotify.com", on: end)
        let said = try await heard(on: end)
        XCTAssertEqual((said["logins"] as? [Any])?.count, 0)
        try assert(Data("spotify".utf8), rp: "spotify.com", on: end)
        let answer = try await heard(on: end)
        XCTAssertEqual(answer["reason"] as? String, "gone")
        XCTAssertEqual(rig.authoriser.asked, [])
    }

    func testAPasskeyInTheTrashIsNotThere() async throws {
        let rig = await rig { item in
            item["name"]?.string == "GitHub" ? item.setting(["deletedDate"], to: .string("2026-10-01T00:00:00.000Z")) : item
        }
        let end = try await connect(rig)
        try list(on: end)
        let said = try await heard(on: end)
        XCTAssertEqual((said["logins"] as? [Any])?.count, 0)
        try assert(on: end)
        let answer = try await heard(on: end)
        XCTAssertEqual(answer["reason"] as? String, "gone")
    }

    // MARK: An assertion

    func testCryptoKitVerifiesAnAssertionOverItsAuthenticatorDataAndTheHash() async throws {
        let rig = await rig()
        let end = try await connect(rig)
        try assert(allowed: [Self.id], on: end)
        let said = try await heard(on: end)
        let (data, signature) = try assertion(in: said)
        XCTAssertTrue(Self.key.publicKey.isValidSignature(signature, for: data + Self.hash))
        XCTAssertFalse(Self.key.publicKey.isValidSignature(signature, for: data + Data(count: 32)))
        let answer = try XCTUnwrap(said["assertion"] as? [String: String])
        XCTAssertEqual(answer["credential"], Self.id.base64EncodedString())
        XCTAssertEqual(answer["userHandle"].flatMap { Data(base64Encoded: $0) }, Data("deniz".utf8))
        XCTAssertEqual(Set(said.keys), ["v", "type", "assertion"])
    }

    func testTheAnswerHoldsNoKey() async throws {
        let rig = await rig()
        let end = try await connect(rig)
        try assert(on: end)
        let body = await raw(on: end)
        let text = String(decoding: try XCTUnwrap(body), as: UTF8.self)
        XCTAssertFalse(text.contains(DemoVault.passkey))
        XCTAssertFalse(text.contains(Self.key.rawRepresentation.base64EncodedString()))
    }

    func testAnIdThePageDidNotAllowIsRefusedBeforeAnyoneIsAsked() async throws {
        let rig = await rig()
        let end = try await connect(rig)
        try assert(allowed: [Data(repeating: 1, count: 16)], on: end)
        let said = try await heard(on: end)
        XCTAssertEqual(said["type"] as? String, "refused")
        XCTAssertEqual(said["reason"] as? String, "page")
        XCTAssertEqual(rig.authoriser.asked, [])
    }

    func testAPasskeyOfAnotherRelyingPartyIsRefusedBeforeAnyoneIsAsked() async throws {
        let rig = await rig()
        let end = try await connect(rig)
        try assert(rp: "github.com.example.org", on: end)
        let said = try await heard(on: end)
        XCTAssertEqual(said["reason"] as? String, "page")
        XCTAssertNil(said["assertion"])
        XCTAssertEqual(rig.authoriser.asked, [])
    }

    func testAnIdNobodyHasIsGone() async throws {
        let rig = await rig()
        let end = try await connect(rig)
        try assert(Data(repeating: 2, count: 16), on: end)
        let said = try await heard(on: end)
        XCTAssertEqual(said["reason"] as? String, "gone")
    }

    func testAKeyThatDoesNotReadIsGone() async throws {
        let rig = await rig(change: withAnotherPasskey { entry in
            entry.merging(["keyValue": .string("CANARY-PASSKEY-KEY")]) { $1 }
        })
        let end = try await connect(rig)
        try assert(Data("spotify".utf8), rp: "spotify.com", on: end)
        let said = try await heard(on: end)
        XCTAssertEqual(said["reason"] as? String, "gone")
    }

    func testNoCallerButTheProviderIsAnswered() async throws {
        let rig = await rig()
        let ask = PasskeyAsk(relyingParty: "github.com", allowed: [])
        for caller in [BridgeCaller.host, .safari] {
            for request in [BridgeRequest.passkeys(ask), .assert(id: Self.id, ask, hash: Self.hash)] {
                let answer = await rig.door.answer(request, from: caller)
                guard case .refused(.page) = answer else { return XCTFail("\(caller) heard \(answer.type)") }
            }
        }
        XCTAssertEqual(rig.authoriser.asked, [])
    }

    func testAProviderThatNamesAPageIsNotAnswered() async throws {
        let rig = await rig()
        let ask = PasskeyAsk(relyingParty: "github.com", allowed: [], page: Self.page)
        for request in [BridgeRequest.passkeys(ask), .assert(id: Self.id, ask, hash: Self.hash), .passkeysNear(url: Self.page)] {
            let answer = await rig.door.answer(request, from: .autofill)
            guard case .refused(.page) = answer else { return XCTFail("heard \(answer.type)") }
        }
    }

    // MARK: A page's caller

    private static let page = "https://github.com/login?return=kanarya"

    func testAPagesCallerHearsItsOwnRelyingPartyWithTheSiteAndNoKey() async throws {
        let icon = Data("icon".utf8)
        let rig = await rig()
        let door = BrowserDoor(store: rig.store, reprompt: rig.reprompt, preferences: Preferences(), icons: { host in
            host == "github.com" ? icon : nil
        })
        let ask = PasskeyAsk(relyingParty: "github.com", allowed: [], page: Self.page)
        for caller in [BridgeCaller.host, .safari] {
            let answer = await door.answer(.passkeys(ask), from: caller)
            let said = try XCTUnwrap(JSONSerialization.jsonObject(with: answer.body) as? [String: Any])
            XCTAssertEqual(said["type"] as? String, "logins", "\(caller)")
            XCTAssertEqual(said["site"] as? String, "github.com")
            XCTAssertEqual(said["icon"] as? String, icon.base64EncodedString())
            XCTAssertEqual((said["logins"] as? [[String: Any]])?.first?["id"] as? String, Self.id.base64EncodedString())
            XCTAssertFalse(String(decoding: answer.body, as: UTF8.self).contains(DemoVault.passkey))
        }
    }

    func testAPageGetsNoIconPastTheSizeAToastTakes() async throws {
        let rig = await rig()
        let door = BrowserDoor(store: rig.store, reprompt: rig.reprompt, preferences: Preferences(), icons: { _ in
            Data(count: SaveDoor.mostIcon + 1)
        })
        let answer = await door.answer(.passkeys(PasskeyAsk(relyingParty: "github.com", allowed: [], page: Self.page)), from: .safari)
        guard case .listed(_, let logins, let icon) = answer else { return XCTFail("heard \(answer.type)") }
        XCTAssertEqual(logins.count, 1)
        XCTAssertNil(icon)
    }

    func testAPageCannotNameAnotherRelyingParty() async throws {
        let rig = await rig()
        for page in ["https://github.com.example.test/login", "https://example.test/", "http://github.com/login"] {
            let ask = PasskeyAsk(relyingParty: "github.com", allowed: [], page: page)
            for request in [BridgeRequest.passkeys(ask), .assert(id: Self.id, ask, hash: Self.hash)] {
                let answer = await rig.door.answer(request, from: .safari)
                guard case .refused(.page) = answer else { return XCTFail("\(page) heard \(answer.type)") }
            }
        }
        XCTAssertEqual(rig.authoriser.asked, [], "refused before anyone was asked")
    }

    func testARelyingPartyIsThePagesHostOrAParentShortOfItsSuffix() throws {
        let page = try XCTUnwrap(Address.page("https://www.login.example.com.tr/in"))
        for named in ["www.login.example.com.tr", "login.example.com.tr", "example.com.tr", "EXAMPLE.com.tr"] {
            XCTAssertTrue(page.mayName(named), named)
        }
        for named in ["com.tr", "tr", "other.com.tr", "example.com", "ww.login.example.com.tr",
                      "example.com.tr/in", "example.com.tr:443", "user@example.com.tr", ""] {
            XCTAssertFalse(page.mayName(named), named)
        }
        XCTAssertTrue(try XCTUnwrap(Address.page("http://localhost:8080/")).mayName("localhost"))
        XCTAssertFalse(try XCTUnwrap(Address.page("http://example.com/")).mayName("example.com"), "not a secure page")
        XCTAssertFalse(try XCTUnwrap(Address.page("https://192.168.1.1/")).mayName("192.168.1.1"), "no domain to name")
    }

    func testASignatureForAPageTakesAFingerEveryTimeAndCarriesNoKey() async throws {
        let rig = await rig(change: withAnotherPasskey())
        let ask = PasskeyAsk(relyingParty: "github.com", allowed: [], page: Self.page)
        for count in 1...2 {
            let answer = await rig.door.answer(.assert(id: Self.id, ask, hash: Self.hash), from: .safari)
            guard case .asserted(let assertion) = answer else { return XCTFail("heard \(answer.type)") }
            let signature = try P256.Signing.ECDSASignature(derRepresentation: assertion.signature)
            XCTAssertTrue(Self.key.publicKey.isValidSignature(signature, for: assertion.authenticatorData + Self.hash))
            XCTAssertEqual(rig.authoriser.asked.count, count)
            XCTAssertEqual(rig.authoriser.asked.last, .passkey)
            XCTAssertFalse(String(decoding: answer.body, as: UTF8.self).contains(DemoVault.passkey))
        }
    }

    func testARefusedFingerGivesAPageNothing() async throws {
        let rig = await rig()
        rig.authoriser.answer = false
        let ask = PasskeyAsk(relyingParty: "github.com", allowed: [], page: Self.page)
        let answer = await rig.door.answer(.assert(id: Self.id, ask, hash: Self.hash), from: .host)
        guard case .refused(.declined) = answer else { return XCTFail("heard \(answer.type)") }
    }

    func testAMarkHearsWhateverThePageCouldAskForAndAProviderDoesNot() async throws {
        let rig = await rig()
        let near = await rig.door.answer(.passkeysNear(url: "https://gist.github.com/x"), from: .safari)
        guard case .logins(_, let logins) = near else { return XCTFail("heard \(near.type)") }
        XCTAssertEqual(logins.count, 1, "a parent of the page's host")
        let elsewhere = await rig.door.answer(.passkeysNear(url: "https://example.test/"), from: .safari)
        guard case .logins(_, let none) = elsewhere else { return XCTFail("heard \(elsewhere.type)") }
        XCTAssertTrue(none.isEmpty)
        let plain = await rig.door.answer(.passkeysNear(url: "http://github.com/"), from: .safari)
        guard case .logins(_, let insecure) = plain else { return XCTFail("heard \(plain.type)") }
        XCTAssertTrue(insecure.isEmpty, "not a page that could use one")
        let noPage = await rig.door.answer(.passkeysNear(url: "about:blank"), from: .safari)
        guard case .refused(.page) = noPage else { return XCTFail("heard \(noPage.type)") }
    }

    func testAPageIsNamedOnTheWire() throws {
        func read(_ message: [String: Any]) throws -> BridgeRequest? {
            BridgeRequest(try JSONSerialization.data(withJSONObject: message.merging(["v": 1]) { $1 }))
        }
        guard case .passkeys(let ask)? = try read(["type": "passkeys", "rp": "github.com", "url": Self.page]) else {
            return XCTFail("no list")
        }
        XCTAssertEqual(ask, PasskeyAsk(relyingParty: "github.com", allowed: [], page: Self.page))
        guard case .passkeysNear(let url)? = try read(["type": "passkeys", "url": Self.page]) else {
            return XCTFail("no mark's list")
        }
        XCTAssertEqual(url, Self.page)
        XCTAssertNil(try read(["type": "passkeys"]), "neither a relying party nor a page")
    }

    // MARK: Who says yes

    func testAnItemThatDoesNotAskStillTakesAFingerForEverySignature() async throws {
        let rig = await rig(change: withAnotherPasskey())
        let end = try await connect(rig)
        for _ in 0..<2 {
            try assert(Data("spotify".utf8), rp: "spotify.com", on: end)
            let said = try await heard(on: end)
            XCTAssertEqual(said["type"] as? String, "asserted")
        }
        XCTAssertEqual(rig.authoriser.asked, [.passkey, .passkey])
    }

    func testAnItemThatAsksWaitsForRepromptAndHasOneQuestion() async throws {
        let rig = await rig()
        rig.authoriser.holds = true
        let end = try await connect(rig)
        try assert(on: end)
        await until { !rig.authoriser.asked.isEmpty }
        XCTAssertEqual(rig.authoriser.asked, [.passkey])
        XCTAssertNotNil(rig.reprompt.asking)
        rig.authoriser.release(true)
        let said = try await heard(on: end)
        XCTAssertEqual(said["type"] as? String, "asserted")
        XCTAssertEqual(rig.authoriser.asked, [.passkey], "one finger, and it stands for the item as well")
        let item = try XCTUnwrap(rig.store.shelves.all.first { $0.item.name == "GitHub" }?.item)
        XCTAssertFalse(rig.reprompt.asks(about: item))
    }

    func testARefusedFingerGivesNothing() async throws {
        let rig = await rig()
        rig.authoriser.answer = false
        let end = try await connect(rig)
        try assert(on: end)
        let said = try await heard(on: end)
        XCTAssertEqual(said["type"] as? String, "refused")
        XCTAssertEqual(said["reason"] as? String, "declined")
        XCTAssertNil(said["assertion"])
    }

    /// The file and the connection going with the lock are in
    /// `SheetDoorTests`, over a real server. This is the question.
    func testALockUnderAQuestionIsNoAnswer() async throws {
        let rig = await rig()
        rig.authoriser.holds = true
        let end = try await connect(rig)
        try assert(on: end)
        await until { !rig.authoriser.asked.isEmpty }
        await rig.store.lock()
        let said = try await heard(on: end)
        XCTAssertEqual(said["reason"] as? String, "declined")
        XCTAssertNil(said["assertion"])
        XCTAssertEqual(rig.authoriser.withdrawn, 1)
        let after = await rig.door.answer(.assert(id: Self.id, PasskeyAsk(relyingParty: "github.com", allowed: []), hash: Self.hash),
                                          from: .autofill)
        XCTAssertEqual(after.type, "locked")
    }

    // MARK: The wire

    func testAHashOfAnyOtherLengthClosesTheConnection() async throws {
        let rig = await rig()
        let end = try await connect(rig)
        try assert(hash: Data(count: 31), on: end)
        let said = try await hear(on: end)
        XCTAssertNil(said)
        XCTAssertEqual(rig.authoriser.asked, [])
    }

    func testARelyingPartyOfNothingClosesTheConnection() {
        let body = try? JSONSerialization.data(withJSONObject: ["v": 1, "type": "passkeys", "rp": ""])
        XCTAssertNil(body.flatMap(BridgeRequest.init))
    }

    func testAnEntryWithNoIdThatReadsIsNoPasskey() {
        XCTAssertNil(Passkey(json: .object(["rpId": .string("a.example"), "credentialId": .string("demo-credential"),
                                            "keyValue": .string("x")])))
    }

    func testPasskeysAreRedacted() throws {
        let object = try XCTUnwrap(DemoVault.objects().items.first { $0["name"]?.string == "GitHub" })
        let passkey = try XCTUnwrap(Passkey.all(in: Item(json: object)).first)
        for said in ["\(passkey)", String(reflecting: passkey)] {
            XCTAssertFalse(said.contains(DemoVault.passkey))
        }
    }

    // MARK: The phone's vector

    /// The item `Phone/Tests/PasskeyTests.swift` signs with, as its fixture
    /// has it, with the same three things held of what comes out.
    func testThePhonesVectorGivesTheSameAuthenticatorData() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Phone/Tests/Fixtures/vault.json")))
        let items = try XCTUnwrap(((fixture as? [String: Any])?["plain"] as? [String: Any])?["items"] as? [[String: Any]])
        let kept = try XCTUnwrap(items.first { $0["name"] as? String == "Kanarya Passkey Site" })
        let entry = try XCTUnwrap((kept["login"] as? [String: Any])?["passkey"] as? [String: Any])
        let passkey = try XCTUnwrap(Passkey(json: JSONValue(data: JSONSerialization.data(withJSONObject: entry))))

        XCTAssertEqual(passkey.authenticatorData.count, 37)
        XCTAssertEqual(passkey.authenticatorData.prefix(32), Data(SHA256.hash(data: Data("passkey.kanarya.example".utf8))))
        XCTAssertEqual(passkey.authenticatorData[32], 0x1d, "present, verified, eligible for backup and backed up")
        XCTAssertEqual(passkey.authenticatorData.suffix(4), Data([0, 0, 0, 0]))
        XCTAssertEqual(passkey.credentialID, withUnsafeBytes(of: UUID(uuidString: "1adebd86-8b59-4f6e-9ee6-f893ca385a36")!.uuid) { Data($0) })
        XCTAssertEqual(passkey.userHandle, Data("kanarya-user-handle-5".utf8))

        let publicKey = try P256.Signing.PublicKey(derRepresentation: XCTUnwrap(Data(base64Encoded: try XCTUnwrap(entry["publicKey"] as? String))))
        let assertion = try XCTUnwrap(passkey.assertion(over: Self.hash))
        let signature = try P256.Signing.ECDSASignature(derRepresentation: assertion.signature)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: assertion.authenticatorData + Self.hash))
    }

    func testTheKeyReadsInEitherAlphabet() throws {
        let der = Self.key.derRepresentation
        let standard = der.base64EncodedString()
        let url = standard.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        for written in [standard, url] {
            let passkey = try XCTUnwrap(Passkey(json: .object([
                "rpId": .string("a.example"), "credentialId": .string("b64.AA"), "keyValue": .string(written),
            ])))
            XCTAssertNotNil(passkey.assertion(over: Self.hash), written.count.description)
        }
    }
}
