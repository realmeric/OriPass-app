import Foundation
import SafariServices
import XCTest
@testable import OriPass

/// The extension's handler, which runs in Safari's process tree and is never
/// started here, over a real `BridgeServer` on a temporary path. The tests'
/// own host is let in under the extension's name, and `AnsweringContext`
/// stands where Safari's `NSExtensionContext` would.
@MainActor
final class SafariHandlerTests: XCTestCase {
    private static let bank = "https://www.isbank.com.tr/giris"
    /// A bundle id nothing has, for a Mac where the app is not running.
    private static let nobody = "com.meric.oripass.nobody"

    private var directory: URL!
    private var kept: [BrowserDoor] = []

    private var path: URL { directory.appendingPathComponent("bridge") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("op-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() async throws {
        kept = []
        try? FileManager.default.removeItem(at: directory)
    }

    private func open(peers: PeerCheck = PeerCheck(identifiers: [.safari: AppInfo.bundleID]))
        async -> (door: BrowserDoor, store: VaultStore) {
        let backend = DemoVault.backend()
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        let door = BrowserDoor(store: store, reprompt: Reprompt(store: store, authoriser: FakeAuthoriser()),
                               preferences: Preferences(), path: path, peers: peers)
        kept.append(door)
        await store.unlock(password: SecretBytes(DemoVault.password))
        await store.indexing?.value
        return (door, store)
    }

    private func answer(to message: Any?, app: String = AppInfo.bundleID, door: URL? = nil,
                        file: StaticString = #filePath, line: UInt = #line) async throws -> [String: Any] {
        let handler = SafariWebExtensionHandler(door: door ?? path, app: app)
        let context = AnsweringContext(message: message)
        let items = await withCheckedContinuation { waiting in
            context.done = { waiting.resume(returning: $0) }
            handler.beginRequest(with: context)
        }
        XCTAssertEqual(items.count, 1, file: file, line: line)
        let item = try XCTUnwrap(items.first as? NSExtensionItem, file: file, line: line)
        return try XCTUnwrap(item.userInfo?[SFExtensionMessageKey] as? [String: Any], file: file, line: line)
    }

    private func kind(of said: [String: Any]) -> String? { said["type"] as? String }

    private func item(_ name: String, in store: VaultStore) throws -> Item {
        try XCTUnwrap(store.shelves.all.first { $0.item.name == name }?.item)
    }

    private func until(_ isSo: () -> Bool) async {
        for _ in 0..<400 where !isSo() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: Through the door

    func testAHelloOfTheExtensionsIsAnsweredWithItsOwn() async throws {
        _ = await open()
        let said = try await answer(to: ["v": 1, "type": "hello"])
        XCTAssertEqual(kind(of: said), "ready")
    }

    /// What a script might write in its own `hello` is never read: the door
    /// hears the handler's, and a second one would have closed on it.
    func testAHelloThatClaimsSomeoneElseGoesNoFurther() async throws {
        _ = await open()
        let said = try await answer(to: ["v": 1, "type": "hello", "origin": "chrome-extension://other/",
                                         "browser": "com.kagi.kagimacOS"])
        XCTAssertEqual(kind(of: said), "ready")
    }

    func testAListComesBackAsTheDoorSaidIt() async throws {
        _ = await open()
        let said = try await answer(to: ["v": 1, "type": "logins", "url": Self.bank])
        XCTAssertEqual(kind(of: said), "logins")
        XCTAssertEqual(said["site"] as? String, "isbank.com.tr")
        let logins = try XCTUnwrap(said["logins"] as? [[String: Any]])
        XCTAssertEqual(logins.compactMap { $0["title"] as? String }, ["İş Bankası"])
    }

    func testAFillComesBackWithItsSecretsWhole() async throws {
        let (_, store) = await open()
        let bank = try item("İş Bankası", in: store)
        let said = try await answer(to: ["v": 1, "type": "fill", "id": bank.id, "url": Self.bank])
        XCTAssertEqual(kind(of: said), "filled")
        XCTAssertEqual(said["username"] as? String, bank.login?.username)
        XCTAssertEqual(said["password"] as? String, bank.login?.password)
    }

    /// What the sheet asks with nothing named is the provider's alone.
    func testTheHandlerHearsPageForWhatIsInFrontAWordAndAPick() async throws {
        let (_, store) = await open()
        let bank = try item("İş Bankası", in: store)
        for message: [String: Any] in [["v": 1, "type": "front"], ["v": 1, "type": "find", "word": "bank"],
                                       ["v": 1, "type": "pick", "id": bank.id]] {
            let said = try await answer(to: message)
            XCTAssertEqual(kind(of: said), "refused")
            XCTAssertEqual(said["reason"] as? String, "page")
        }
    }

    func testARefusalComesBackWithItsReason() async throws {
        _ = await open()
        let said = try await answer(to: ["v": 1, "type": "fill", "id": "nobody", "url": Self.bank])
        XCTAssertEqual(kind(of: said), "refused")
        XCTAssertEqual(said["reason"] as? String, "gone")
    }

    /// Every message has a connection of its own and shuts it, so the handler
    /// holds nothing between two of them and the door counts none.
    func testNoConnectionIsLeftBehindAMessage() async throws {
        let (door, _) = await open()
        for _ in 0..<3 {
            let said = try await answer(to: ["v": 1, "type": "logins", "url": Self.bank])
            XCTAssertEqual(kind(of: said), "logins")
        }
        await until { door.connected == 0 }
        XCTAssertEqual(door.connected, 0)
    }

    /// `background.js` sends `hello` and `logins` a moment apart, and this is
    /// that, with one handler as Safari keeps one or not.
    func testOneHandlerAnswersAsManyMessagesAsItIsHanded() async throws {
        _ = await open()
        let handler = SafariWebExtensionHandler(door: path, app: AppInfo.bundleID)
        for message in [["v": 1, "type": "hello"], ["v": 1, "type": "logins", "url": Self.bank]] as [[String: Any]] {
            let context = AnsweringContext(message: message)
            let items = await withCheckedContinuation { waiting in
                context.done = { waiting.resume(returning: $0) }
                handler.beginRequest(with: context)
            }
            XCTAssertEqual(items.count, 1)
        }
    }

    // MARK: When the door says nothing

    func testNoDoorWithTheAppUpIsLocked() async throws {
        let said = try await answer(to: ["v": 1, "type": "hello"])
        XCTAssertEqual(kind(of: said), "locked")
    }

    func testNoDoorAndNoAppIsClosed() async throws {
        let said = try await answer(to: ["v": 1, "type": "logins", "url": Self.bank], app: Self.nobody)
        XCTAssertEqual(kind(of: said), "closed")
    }

    func testTheLockShutsTheDoorOnTheNextMessage() async throws {
        let (_, store) = await open()
        await store.lock()
        let said = try await answer(to: ["v": 1, "type": "logins", "url": Self.bank])
        XCTAssertEqual(kind(of: said), "locked")
    }

    /// A door that closes on who it takes this for, with no answer.
    func testADoorThatClosesOnItIsTheSameAsNone() async throws {
        _ = await open(peers: PeerCheck())
        let said = try await answer(to: ["v": 1, "type": "hello"], app: Self.nobody)
        XCTAssertEqual(kind(of: said), "closed")
    }

    func testAContainerWithoutTheGroupFindsNoDoor() async throws {
        let handler = SafariWebExtensionHandler(door: nil, app: Self.nobody)
        let context = AnsweringContext(message: ["v": 1, "type": "hello"])
        let items = await withCheckedContinuation { waiting in
            context.done = { waiting.resume(returning: $0) }
            handler.beginRequest(with: context)
        }
        let said = try XCTUnwrap((items.first as? NSExtensionItem)?.userInfo?[SFExtensionMessageKey] as? [String: Any])
        XCTAssertEqual(kind(of: said), "closed")
    }

    func testWhatIsNoMessageNeverReachesTheDoor() async throws {
        let (door, _) = await open()
        for message in [nil, "words", ["v": 1], ["v": 1, "type": 2]] as [Any?] {
            let said = try await answer(to: message)
            XCTAssertEqual(kind(of: said), "locked", "\(String(describing: message))")
        }
        XCTAssertEqual(door.connected, 0)
    }
}

/// Stands where Safari's context would: a message going in, and what the
/// handler handed back.
private final class AnsweringContext: NSExtensionContext {
    private let message: Any?
    var done: (([Any]) -> Void)?

    init(message: Any?) {
        self.message = message
        super.init()
    }

    override var inputItems: [Any] {
        let item = NSExtensionItem()
        if let message { item.userInfo = [SFExtensionMessageKey: message] }
        return [item]
    }

    override func completeRequest(returningItems items: [Any]?, completionHandler: ((Bool) -> Void)? = nil) {
        done?(items ?? [])
    }
}
