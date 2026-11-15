import XCTest
@testable import OriPass

final class SignInTests: XCTestCase {
    private let keychain = Keychain(service: "com.meric.oripass.tests")
    private var plainUserKey: Data!

    override func setUpWithError() throws {
        FakeServer.reset()
        keychain.deleteAll()
        plainUserKey = Data(b64: (FakeServer.vault["plain"] as! [String: Any])["userKey"])
    }

    override func tearDown() {
        keychain.deleteAll()
    }

    private func signIn(_ password: String = "demo", email: String = " Kanarya@Example.invalid") -> SignIn {
        SignIn(client: FakeServer.client(), email: email, password: SecretBytes(password), keychain: keychain)
    }

    func testAPasswordOpensTheUserKey() async throws {
        let signIn = signIn()
        let step = try await signIn.start()
        XCTAssertEqual(step, .done)
        let maybe = await signIn.opened
        let opened = try XCTUnwrap(maybe)
        XCTAssertEqual(opened.userKey.bytes, plainUserKey)
        XCTAssertEqual(opened.account.email, "kanarya@example.invalid")
        XCTAssertEqual(opened.account.kdf, .pbkdf2(iterations: 600_000))
        XCTAssertEqual(opened.tokens.refresh, "kanarya-refresh")
        XCTAssertEqual(try opened.account.userKey(password: SecretBytes("demo")).bytes, plainUserKey)
    }

    func testThePasswordIsNeverSent() async throws {
        _ = try await signIn().start()
        XCTAssertFalse(FakeServer.seen.isEmpty)
        for (_, body) in FakeServer.seen {
            XCTAssertFalse(FakeServer.form(body).values.contains("demo"))
            XCTAssertFalse(body.contains("\"demo\""))
        }
        let form = FakeServer.form(FakeServer.seen.last!.body)
        XCTAssertEqual(form["client_id"], "mobile")
        XCTAssertEqual(form["deviceType"], "1")
        XCTAssertEqual(form["deviceName"], "OriPass")
        XCTAssertEqual(form["deviceIdentifier"], Device.identifier(in: keychain), "the same device each time")
    }

    func testAWrongPasswordIsTheServersSentence() async throws {
        do {
            _ = try await signIn("not demo").start()
            XCTFail("signed in")
        } catch {
            XCTAssertEqual(error as? SignIn.Failure, .refused("Username or password is incorrect. Try again."))
        }
    }

    func testAnAuthenticatorCodeIsAskedForAndTaken() async throws {
        FakeServer.twoFactor = true
        let signIn = signIn()
        let first = try await signIn.start()
        XCTAssertEqual(first, .code(.authenticator))
        do {
            _ = try await signIn.submit(code: "000000")
            XCTFail("a wrong code was taken")
        } catch {
            XCTAssertEqual(error as? SignIn.Failure, .refused("Two-step token is invalid. Try again."))
        }
        let second = try await signIn.submit(code: "123 456")
        XCTAssertEqual(second, .done)
        XCTAssertEqual(FakeServer.form(FakeServer.seen.last!.body)["twoFactorProvider"], "0")
        let opened = await signIn.opened
        XCTAssertEqual(opened?.userKey.bytes, plainUserKey)
    }

    func testANewDeviceCodeIsAskedForAndTaken() async throws {
        FakeServer.newDevice = true
        let signIn = signIn()
        let first = try await signIn.start()
        XCTAssertEqual(first, .deviceCode)
        let second = try await signIn.submit(code: "654321")
        XCTAssertEqual(second, .done)
        XCTAssertEqual(FakeServer.form(FakeServer.seen.last!.body)["newdeviceotp"], "654321")
    }

    func testAServerOfOnesOwnIsHttpsOrThisPhone() {
        XCTAssertEqual(Server.own(typed: "vault.example.org"), .own(URL(string: "https://vault.example.org")!))
        XCTAssertEqual(Server.own(typed: "http://localhost:8099"), .own(URL(string: "http://localhost:8099")!))
        XCTAssertNil(Server.own(typed: "http://vault.example.org"))
        XCTAssertEqual(Server.own(typed: "https://vault.example.org/")?.identity.absoluteString,
                       "https://vault.example.org/identity")
    }
}
