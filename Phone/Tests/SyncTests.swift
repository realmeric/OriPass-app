import XCTest
@testable import OriPass

final class SyncTests: XCTestCase {
    private let defaults = UserDefaults(suiteName: "com.meric.oripass.tests.sync")!
    private let keychain = Keychain(service: "com.meric.oripass.tests")

    override func tearDown() {
        defaults.removePersistentDomain(forName: "com.meric.oripass.tests.sync")
        keychain.deleteAll()
    }

    func testAnAccountThatDidNotChangeIsNotDownloadedAgain() async throws {
        FakeServer.reset()
        let api = Api(client: FakeServer.client(),
                      tokens: Tokens(access: "kanarya-access", refresh: "kanarya-refresh", expires: .distantFuture),
                      keychain: keychain)
        let first = try await VaultFile.syncIfChanged(with: api, defaults: defaults)
        XCTAssertNotNil(first)
        let second = try await VaultFile.syncIfChanged(with: api, defaults: defaults)
        XCTAssertNil(second, "the same revision")
        FakeServer.revision += 1
        let third = try await VaultFile.syncIfChanged(with: api, defaults: defaults)
        XCTAssertNotNil(third, "a new revision")
        XCTAssertEqual(FakeServer.seen.filter { $0.path == "/api/sync" }.count, 2)
        XCTAssertNotNil(VaultFile.lastSynced(defaults: defaults))
    }

    func testTheBackgroundSyncDownloadsWhatChangedAndSaysSo() async throws {
        FakeServer.reset()
        let api = Api(client: FakeServer.client(),
                      tokens: Tokens(access: "kanarya-access", refresh: "kanarya-refresh", expires: .distantFuture),
                      keychain: keychain)
        FakeServer.revision += 7
        let done = await BackgroundSync.run(with: api, defaults: defaults)
        XCTAssertTrue(done)
        XCTAssertEqual(FakeServer.seen.map(\.path), ["/api/accounts/revision-date", "/api/sync"])
        XCTAssertNotNil(VaultFile.read())
    }
}
