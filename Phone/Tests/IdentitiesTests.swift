import AuthenticationServices
import XCTest
@testable import OriPass

final class IdentitiesTests: XCTestCase {
    private func summaries() throws -> [Summary] {
        let plain = FakeServer.vault["plain"] as! [String: Any]
        let sync = try JSONSerialization.data(withJSONObject: FakeServer.vault["sync"]!)
        return try Vault(data: sync, userKey: VaultKey(Data(b64: plain["userKey"]))).summaries()
    }

    func testEveryLoginAddressIsAnIdentityAndAnAndroidAppIsNot() throws {
        let identities = Identities.make(from: try summaries())
        let passwords = identities.compactMap { $0 as? ASPasswordCredentialIdentity }
        XCTAssertEqual(Set(passwords.map(\.serviceIdentifier.identifier)), [
            "localhost", "mail.kanarya.example", "bank.kanarya.example", "router.kanarya.example", "passkey.kanarya.example",
        ])
        XCTAssertEqual(passwords.filter { $0.serviceIdentifier.identifier == "localhost" }.count, 2, "two logins on one host")
        XCTAssertFalse(passwords.contains { $0.serviceIdentifier.identifier.hasPrefix("androidapp") })
        XCTAssertFalse(passwords.contains { $0.user.contains("kanarya-user-6") }, "the trash is not suggested")
        XCTAssertEqual(passwords.first { $0.user == "kanarya-user-1" }?.rank, 1, "a favourite first")
    }

    func testALoginWithACodeHasACodeIdentity() throws {
        let codes = Identities.make(from: try summaries()).compactMap { $0 as? ASOneTimeCodeCredentialIdentity }
        XCTAssertEqual(Set(codes.map(\.label)), ["Kanarya Mail", "Stand-in login page"])
        XCTAssertEqual(codes.first { $0.label == "Kanarya Mail" }?.serviceIdentifier.identifier, "mail.kanarya.example")
    }

    func testAPasskeyIsAPasskeyIdentity() throws {
        let passkeys = Identities.make(from: try summaries()).compactMap { $0 as? ASPasskeyCredentialIdentity }
        XCTAssertEqual(passkeys.count, 1)
        XCTAssertEqual(passkeys.first?.relyingPartyIdentifier, "passkey.kanarya.example")
        XCTAssertEqual(passkeys.first?.credentialID.count, 16)
        XCTAssertEqual(passkeys.first?.userHandle, Data("kanarya-user-handle-5".utf8))
    }

    func testAddressesAreReadTheWayTheyAreWritten() {
        XCTAssertEqual(Identities.service(for: "Kanarya.example/path")?.identifier, "kanarya.example")
        XCTAssertNil(Identities.service(for: "androidapp://com.kanarya"))
        XCTAssertNil(Identities.service(for: "ftp://kanarya.example"))
        XCTAssertNil(Identities.service(for: "  "))
        if #available(iOS 26.2, *) {
            XCTAssertEqual(Identities.service(for: "iosapp://com.kanarya.app")?.type, .app)
        }
        XCTAssertEqual(Passkeys.credentialID("b64.AQID"), Data([1, 2, 3]))
    }
}
