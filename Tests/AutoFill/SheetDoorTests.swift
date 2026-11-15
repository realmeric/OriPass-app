import CryptoKit
import Foundation
import XCTest
@testable import OriPass

/// `BridgeSheetDoor` over a real `BridgeServer` on a temporary path and the
/// demo vault, the tests' own host let in under the provider's name.
@MainActor
final class SheetDoorTests: XCTestCase {
    private static let bank = AutoFillService.page(url: "https://www.isbank.com.tr/giris", name: "isbank.com.tr")
    private static let nobody = "com.meric.oripass.nobody"

    private var directory: URL!
    private var kept: [BrowserDoor] = []
    private let tabsAsked = Count()

    private var path: URL { directory.appendingPathComponent("bridge") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("op-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() async throws {
        kept = []
        try? FileManager.default.removeItem(at: directory)
    }

    private func open(as caller: BridgeCaller = .autofill, change: (JSONValue) -> JSONValue = { $0 },
                      authoriser: FakeAuthoriser? = nil, inFront: FrontApp? = nil, tab: String? = nil) async -> VaultStore {
        let vault = DemoVault.objects()
        let backend = FakeBackend(items: vault.items.map(change), folders: vault.folders, password: DemoVault.password)
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        let door = BrowserDoor(store: store, reprompt: Reprompt(store: store, authoriser: authoriser ?? FakeAuthoriser()), preferences: Preferences(),
                               path: path, peers: PeerCheck(identifiers: [caller: AppInfo.bundleID]),
                               front: { inFront }, tabs: AskedTab(tab, count: tabsAsked))
        kept.append(door)
        await store.unlock(password: SecretBytes(DemoVault.password))
        await store.indexing?.value
        return store
    }

    private var door: BridgeSheetDoor { BridgeSheetDoor(door: path, app: AppInfo.bundleID) }

    private func item(_ name: String, in store: VaultStore) throws -> Item {
        try XCTUnwrap(store.shelves.all.first { $0.item.name == name }?.item)
    }

    func testTheThirdNameIsLetInLikeTheOtherTwo() {
        XCTAssertEqual(BridgeCaller.autofill.rawValue, "com.meric.oripass.autofill")
        XCTAssertNotNil(PeerCheck().identifiers[.autofill])
    }

    func testTheListForAPageIsWhatTheDoorFound() async throws {
        _ = await open()
        guard case .logins(let site, let logins) = await door.ask(.logins(Self.bank)) else { return XCTFail("no list") }
        XCTAssertEqual(site, "isbank.com.tr")
        XCTAssertEqual(logins.map(\.title), ["İş Bankası"])
    }

    func testAFillComesBackWhole() async throws {
        let store = await open()
        let bank = try item("İş Bankası", in: store)
        let answer = await door.ask(.fill(id: bank.id, Self.bank))
        XCTAssertEqual(answer, .filled(SheetCredential(username: bank.login?.username ?? "", password: bank.login?.password ?? "")))
    }

    func testAPasskeyComesBackSignedOverTheHash() async throws {
        let authoriser = FakeAuthoriser()
        _ = await open(authoriser: authoriser)
        let hash = Data(repeating: 9, count: 32)
        let service = AutoFillService.passkey(relyingParty: "github.com", allowed: [], clientDataHash: hash)
        guard case .logins(_, let rows) = await door.ask(.passkeys(service)), let row = rows.first else { return XCTFail("no list") }
        XCTAssertEqual(rows.map(\.title), ["GitHub"])
        guard case .asserted(let assertion) = await door.ask(.assert(id: row.id, service)) else { return XCTFail("no assertion") }
        XCTAssertEqual(authoriser.asked, [.passkey])
        let signature = try P256.Signing.ECDSASignature(derRepresentation: assertion.signature)
        let key = try P256.Signing.PrivateKey(rawRepresentation: Data(DemoVault.passkeySeed.utf8))
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: assertion.authenticatorData + hash))
    }

    func testTheLockCutsAPasskeyUnderItsFingerAndTheDoorIsGone() async throws {
        let authoriser = FakeAuthoriser()
        authoriser.holds = true
        let store = await open(authoriser: authoriser)
        let id = withUnsafeBytes(of: UUID(uuidString: DemoVault.passkeyCredential)!.uuid) { Data($0) }.base64EncodedString()
        let service = AutoFillService.passkey(relyingParty: "github.com", allowed: [], clientDataHash: Data(count: 32))
        let door = self.door
        let asking = Task { await door.ask(.assert(id: id, service)) }
        for _ in 0..<400 where authoriser.asked.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(authoriser.asked, [.passkey])
        await store.lock()
        let answer = await asking.value
        XCTAssertEqual(answer, .shut(isRunning: true), "the connection was cut with nothing said on it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testACodeComesBackOverTheRealDoor() async throws {
        let store = await open()
        let bank = try item("İş Bankası", in: store)
        guard case .logins(_, let rows) = await door.ask(.codes(Self.bank)) else { return XCTFail("no list") }
        XCTAssertEqual(rows.map(\.id), [bank.id])
        guard case .code(let said) = await door.ask(.code(id: bank.id, Self.bank)) else { return XCTFail("no code") }
        let totp = try XCTUnwrap(bank.oneTimeCode)
        XCTAssertTrue([Date(), Date().addingTimeInterval(-1)].map(totp.code(at:)).contains(said.code))
    }

    func testAnAppIsAskedForItsCodeByItsNameAndItsId() async throws {
        let store = await open(change: Self.slackWithACode)
        let slack = try item("Slack", in: store)
        let service = AutoFillService.app(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
        guard case .logins(_, let rows) = await door.ask(.codes(service)) else { return XCTFail("no list") }
        XCTAssertEqual(rows.map(\.id), [slack.id])
        guard case .code = await door.ask(.code(id: slack.id, service)) else { return XCTFail("no code") }
    }

    func testTheSheetHandsACodeOverTheRealDoor() async throws {
        let store = await open()
        let bank = try item("İş Bankası", in: store)
        var handed: [SheetCode] = []
        let sheet = AutoFillSheet(services: [Self.bank], door: door, isForCodes: true, finish: { _ in }, code: { handed.append($0) }, dismiss: {})
        sheet.begin()
        for _ in 0..<400 where sheet.state != .listed { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(sheet.rows.map(\.id), [bank.id])
        sheet.choose(sheet.rows[0])
        for _ in 0..<400 where handed.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(handed.count, 1)
    }

    func testARefusalComesBackWithItsReason() async throws {
        _ = await open()
        let answer = await door.ask(.fill(id: "nobody", Self.bank))
        XCTAssertEqual(answer, .refused("gone"))
    }

    func testANameOnAnotherLoginIsRefusedForThePage() async throws {
        let store = await open()
        let other = try XCTUnwrap(store.shelves.all.first {
            $0.item.login != nil && $0.item.name != "İş Bankası" && !$0.item.reprompt
        }?.item)
        let answer = await door.ask(.fill(id: other.id, Self.bank))
        XCTAssertEqual(answer, .refused("page"))
    }

    func testAnAppIsAskedForByItsNameAndItsId() async throws {
        let store = await open()
        let slack = try item("Slack", in: store)
        let service = AutoFillService.app(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
        guard case .logins(_, let logins) = await door.ask(.logins(service)) else { return XCTFail("no list") }
        XCTAssertEqual(logins.map(\.id), [slack.id])
        let answer = await door.ask(.fill(id: slack.id, service))
        XCTAssertEqual(answer, .filled(SheetCredential(username: slack.login?.username ?? "", password: slack.login?.password ?? "")))
    }

    /// A browser that asks by its app is on a page nobody knows.
    func testABrowserAskedForAsAnAppIsOfferedNothing() async throws {
        _ = await open()
        let service = AutoFillService.app(bundleID: "com.apple.Safari", name: "Safari")
        let answer = await door.ask(.logins(service))
        XCTAssertEqual(answer, .logins(site: nil, []))
    }

    func testAnAppIsHandedOnlyWhatIsListedForIt() async throws {
        let store = await open()
        let bank = try item("İş Bankası", in: store)
        let service = AutoFillService.app(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
        let answer = await door.ask(.fill(id: bank.id, service))
        XCTAssertEqual(answer, .refused("page"))
    }

    /// The asking for an app is the system's, so a browser's extension,
    /// which a page's script can reach, gets no list the page's address
    /// does not hold.
    func testNobodyButTheProviderMayAskByApp() async throws {
        _ = await open(as: .safari)
        let service = AutoFillService.app(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
        let answer = await door.ask(.logins(service))
        XCTAssertEqual(answer, .refused("page"))
        let fill = await door.ask(.fill(id: "x", service))
        XCTAssertEqual(fill, .refused("page"))
    }

    func testAnItemThatAsksIsAskedAboutForAnAppToo() async throws {
        let authoriser = FakeAuthoriser()
        authoriser.answer = false
        let store = await open(change: Self.asking, authoriser: authoriser)
        let slack = try item("Slack", in: store)
        let service = AutoFillService.app(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
        let answer = await door.ask(.fill(id: slack.id, service))
        XCTAssertEqual(answer, .refused("declined"))
    }

    func testNoDoorWithTheAppUpIsShut() async {
        let answer = await door.ask(.logins(Self.bank))
        XCTAssertEqual(answer, .shut(isRunning: true))
    }

    func testNoDoorAndNoAppIsShutAndNotOpen() async {
        let answer = await BridgeSheetDoor(door: path, app: Self.nobody).ask(.logins(Self.bank))
        XCTAssertEqual(answer, .shut(isRunning: false))
    }

    func testAContainerWithoutTheGroupFindsNoDoor() async {
        let answer = await BridgeSheetDoor(door: nil, app: Self.nobody).ask(.logins(Self.bank))
        XCTAssertEqual(answer, .shut(isRunning: false))
    }

    func testTheLockShutsTheDoorOnTheNextRequest() async {
        let store = await open()
        await store.lock()
        let answer = await door.ask(.logins(Self.bank))
        XCTAssertEqual(answer, .shut(isRunning: true))
    }

    func testTheSheetOverTheRealDoorIsTheSameAsOverAFake() async throws {
        let store = await open()
        let bank = try item("İş Bankası", in: store)
        var handed: [SheetCredential] = []
        let sheet = AutoFillSheet(services: [Self.bank], door: door, finish: { handed.append($0) }, dismiss: {})
        sheet.begin()
        for _ in 0..<400 where sheet.state != .listed { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(sheet.rows.map(\.id), [bank.id])
        sheet.choose(sheet.rows[0])
        for _ in 0..<400 where handed.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(handed.first?.password, bank.login?.password)
    }

    // MARK: When the system names nothing

    private static let orion = FrontApp(pid: 1, bundleID: "com.kagi.kagimacOS", name: "Orion")
    private static let slack = FrontApp(pid: 2, bundleID: "com.tinyspeck.slackmacgap", name: "Slack")

    private func filling(_ sheet: AutoFillSheet, _ handed: @autoclosure () -> Bool) async throws {
        for _ in 0..<400 where sheet.state != .listed { try? await Task.sleep(nanoseconds: 5_000_000) }
        sheet.choose(try XCTUnwrap(sheet.rows.first))
        for _ in 0..<400 where !handed() { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testOrionInFrontListsThatSiteAndFillsIt() async throws {
        let store = await open(inFront: Self.orion, tab: "https://www.isbank.com.tr/giris?token=a")
        let bank = try item("İş Bankası", in: store)
        var handed: [SheetCredential] = []
        let sheet = AutoFillSheet(services: [], door: door, looksInFront: true, finish: { handed.append($0) }, dismiss: {})
        sheet.begin()
        try await filling(sheet, !handed.isEmpty)
        XCTAssertEqual(sheet.name, "isbank.com.tr")
        XCTAssertEqual(handed.first?.password, bank.login?.password)
    }

    /// `AskedTab` says nothing, which is what the event comes back with
    /// when macOS has not been told yes.
    func testNoGrantNamesNothing() async throws {
        _ = await open(inFront: Self.orion, tab: nil)
        let answer = await door.ask(.front)
        XCTAssertEqual(answer, .front(nil, []))
        XCTAssertEqual(tabsAsked.value, 1)
    }

    func testABrowserNobodyCanAskNamesNothingAndIsNotAsked() async throws {
        let chrome = FrontApp(pid: 3, bundleID: "com.google.Chrome", name: "Chrome")
        _ = await open(inFront: chrome, tab: "https://www.isbank.com.tr/giris")
        let answer = await door.ask(.front)
        XCTAssertEqual(answer, .front(nil, []))
        XCTAssertEqual(tabsAsked.value, 0)
    }

    func testATabOnNoWebPageNamesNothing() async throws {
        _ = await open(inFront: Self.orion, tab: "file:///Users/someone/page.html")
        let answer = await door.ask(.front)
        XCTAssertEqual(answer, .front(nil, []))
    }

    func testNothingInFrontNamesNothing() async throws {
        _ = await open()
        let answer = await door.ask(.front)
        XCTAssertEqual(answer, .front(nil, []))
    }

    func testAnAppInFrontListsByItsNameAndFillsAsItWouldBeNamed() async throws {
        let store = await open(inFront: Self.slack)
        let slack = try item("Slack", in: store)
        guard case .front(let service?, let logins) = await door.ask(.front) else { return XCTFail("nothing named") }
        XCTAssertEqual(service, .app(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"))
        XCTAssertEqual(logins.map(\.id), [slack.id])
        let answer = await door.ask(.fill(id: slack.id, service))
        XCTAssertEqual(answer, .filled(SheetCredential(username: slack.login?.username ?? "", password: slack.login?.password ?? "")))
    }

    /// The address is the app's, and a login that is not that page's is
    /// refused for it as for any other page.
    func testARowOfThePageInFrontIsHeldToThatPage() async throws {
        let store = await open(inFront: Self.orion, tab: "https://www.isbank.com.tr/giris")
        let slack = try item("Slack", in: store)
        guard case .front(let service?, _) = await door.ask(.front) else { return XCTFail("nothing named") }
        let answer = await door.ask(.fill(id: slack.id, service))
        XCTAssertEqual(answer, .refused("page"))
    }

    func testAPageNoLoginHoldsForIsNamedAndEmpty() async throws {
        _ = await open(inFront: Self.orion, tab: "https://www.nobody.example/")
        guard case .front(let service?, let logins) = await door.ask(.front) else { return XCTFail("nothing named") }
        XCTAssertEqual(service.name, "nobody.example")
        XCTAssertEqual(logins, [])
    }

    func testAnEmptyWordFindsNothing() async throws {
        _ = await open()
        for word in ["", "   ", "\n"] {
            let answer = await door.ask(.find(word))
            XCTAssertEqual(answer, .logins(site: nil, []), "\"\(word)\"")
        }
    }

    func testAWordFindsAtMostEightLoginsAndNoOtherKind() async throws {
        let store = await open(change: { object in
            guard object["login"] != nil else { return object }
            return object.setting(["name"], to: .string("Common \(object["name"]?.string ?? "")"))
        })
        XCTAssertGreaterThan(store.shelves.all.filter { $0.item.login != nil }.count, BrowserDoor.mostFound)
        guard case .logins(_, let logins) = await door.ask(.find("common")) else { return XCTFail("no list") }
        XCTAssertEqual(logins.count, BrowserDoor.mostFound)
        let empty = await door.ask(.find("zzzzqqqq"))
        XCTAssertEqual(empty, .logins(site: nil, []))
    }

    func testAListAWordFoundHoldsNoSecret() async throws {
        let authoriser = FakeAuthoriser()
        let store = await open(authoriser: authoriser)
        let answer = await kept[0].answer(.find(word: "github"), from: .autofill)
        let said = String(decoding: answer.body, as: UTF8.self)
        XCTAssertTrue(said.contains("GitHub"))
        for entry in store.shelves.all {
            if let password = entry.item.login?.password { XCTAssertFalse(said.contains(password)) }
        }
        XCTAssertEqual(authoriser.asked, [], "a list is nobody's to answer for")
    }

    func testAPickTakesAFingerEvenForAnItemThatDoesNotAsk() async throws {
        let authoriser = FakeAuthoriser()
        let store = await open(authoriser: authoriser)
        let bank = try item("İş Bankası", in: store)
        XCTAssertFalse(bank.reprompt)
        let answer = await door.ask(.pick(id: bank.id))
        XCTAssertEqual(authoriser.asked, [.pick])
        XCTAssertEqual(answer, .filled(SheetCredential(username: bank.login?.username ?? "", password: bank.login?.password ?? "")))
        let again = await door.ask(.pick(id: bank.id))
        XCTAssertEqual(again, answer)
        XCTAssertEqual(authoriser.asked, [.pick, .pick], "every time")
    }

    func testARefusedFingerGivesNothing() async throws {
        let authoriser = FakeAuthoriser()
        authoriser.answer = false
        let store = await open(authoriser: authoriser)
        let answer = await door.ask(.pick(id: try item("İş Bankası", in: store).id))
        XCTAssertEqual(answer, .refused("declined"))
    }

    func testAPickOfWhatIsNoLoginAsksNobody() async throws {
        let authoriser = FakeAuthoriser()
        let store = await open(authoriser: authoriser)
        let note = try XCTUnwrap(store.shelves.all.first { $0.item.login == nil }?.item)
        for id in [note.id, "nobody"] {
            let answer = await door.ask(.pick(id: id))
            XCTAssertEqual(answer, .refused("gone"))
        }
        XCTAssertEqual(authoriser.asked, [])
    }

    func testTheLockCutsAPickUnderItsFinger() async throws {
        let authoriser = FakeAuthoriser()
        authoriser.holds = true
        let store = await open(authoriser: authoriser)
        let id = try item("İş Bankası", in: store).id
        let door = self.door
        let asking = Task { await door.ask(.pick(id: id)) }
        for _ in 0..<400 where authoriser.asked.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        await store.lock()
        let answer = await asking.value
        XCTAssertEqual(answer, .shut(isRunning: true))
    }

    /// The three reach no further than the provider: an extension can be
    /// given to a page's script, and a list of what is in front would tell
    /// it about another app.
    func testNobodyButTheProviderHearsAnythingOfTheThree() async throws {
        let authoriser = FakeAuthoriser()
        let store = await open(authoriser: authoriser, inFront: Self.slack)
        let door = try XCTUnwrap(kept.first)
        let bank = try item("İş Bankası", in: store)
        for caller in [BridgeCaller.host, .safari] {
            for request in [BridgeRequest.front, .find(word: "bank"), .pick(id: bank.id)] {
                let answer = await door.answer(request, from: caller)
                XCTAssertEqual(answer.type, "refused", "\(request)")
                XCTAssertTrue(String(decoding: answer.body, as: UTF8.self).contains(#""reason":"page""#), "\(request)")
            }
        }
        XCTAssertEqual(authoriser.asked, [])
    }

    func testAMessageWithNoWordClosesTheConnection() {
        XCTAssertNil(BridgeRequest(Data(#"{"v":1,"type":"find"}"#.utf8)))
        XCTAssertNil(BridgeRequest(Data(#"{"v":1,"type":"pick"}"#.utf8)))
        XCTAssertNil(BridgeRequest(Data(#"{"v":1,"type":"front","url":"https://github.com/"}"#.utf8)))
        XCTAssertNotNil(BridgeRequest(Data(#"{"v":1,"type":"front"}"#.utf8)))
    }

    func testAWordIsNotShownInADump() {
        let request = BridgeRequest.find(word: "kanarya")
        XCTAssertFalse("\(request)".contains("kanarya"))
        XCTAssertFalse(String(reflecting: SheetRequest.find("kanarya")).contains("kanarya"))
    }

    private static func slackWithACode(_ object: JSONValue) -> JSONValue {
        object["name"]?.string == "Slack" ? object.setting(["login", "totp"], to: .string(DemoVault.totpSecrets[0])) : object
    }

    private static func asking(_ object: JSONValue) -> JSONValue {
        guard case .object(var keys) = object, keys["name"] == .string("Slack") else { return object }
        keys["reprompt"] = .int(1)
        return .object(keys)
    }
}

private final class Count: @unchecked Sendable {
    var value = 0
}

/// A browser's tab that says what it was told, as a real one does once macOS
/// has been told yes, and nothing otherwise.
private struct AskedTab: TabAsker {
    let written: String?
    let count: Count

    init(_ written: String?, count: Count) {
        self.written = written
        self.count = count
    }

    func address(of app: FrontApp) async -> String? {
        count.value += 1
        return written
    }
}
