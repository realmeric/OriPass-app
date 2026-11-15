import XCTest
@testable import OriPass

final class SignOutTests: XCTestCase {
    private let keychain = Keychain(service: "com.meric.oripass.tests")

    override func tearDown() {
        keychain.deleteAll()
    }

    func testNothingOfTheAccountIsLeft() async throws {
        let plain = FakeServer.vault["plain"] as! [String: Any]
        let sync = try JSONSerialization.data(withJSONObject: FakeServer.vault["sync"]!)
        try VaultFile.write(sync)
        try Account(email: "kanarya@example.invalid", server: FakeServer.server, kdf: .pbkdf2(iterations: 600_000),
                    protectedUserKey: "2.x").store()
        Recents.used("kanarya-id")
        try Tokens(access: "kanarya-access", refresh: "kanarya-refresh", expires: .distantFuture).store(in: keychain)
        try keychain.write(Data("kanarya-key".utf8), as: "userKey")
        let device = Device.identifier(in: keychain)
        let vault = try Vault(data: sync, userKey: VaultKey(Data(b64: plain["userKey"])))
        await IdentityStore.replace(with: vault.summaries())

        await SignOut.wipe(keychain: keychain)

        let left = try FileManager.default.contentsOfDirectory(atPath: Shared.container!.path)
            .filter { !$0.hasPrefix(".") && $0 != "Library" }
        XCTAssertEqual(left, [], "no file of the account in the App Group")
        XCTAssertNil(Tokens.stored(in: keychain))
        XCTAssertNil(try keychain.read("userKey"))
        XCTAssertEqual(Device.identifier(in: keychain), device, "the install's id stays")
        // The store cannot be read back from the app (docs/notes-ios.md); that it
        // is empty is SettingsUITests', in Safari.
    }
}
