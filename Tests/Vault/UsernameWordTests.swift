import XCTest
@testable import OriPass

/// What a login's username is called from what is in it (`Login.word`).
final class UsernameWordTests: XCTestCase {
    func testAnAddressIsAnEmailAndAnythingElseIsAUsername() {
        XCTAssertEqual(Login.word(forUsername: "deniz"), "username")
        XCTAssertEqual(Login.word(forUsername: "deniz@example.test"), "email")
        XCTAssertEqual(Login.word(forUsername: nil), "username")
        XCTAssertEqual(Login.word(forUsername: ""), "username")
    }

    /// Each letter of an address as it is typed: the word changes once,
    /// at the first letter after the host's dot.
    func testTheWordChangesOnceAsAnAddressIsTyped() throws {
        let address = "deniz@example.test"
        let words = address.indices.map { Login.word(forUsername: String(address[...$0])) }
        let first = try XCTUnwrap(words.firstIndex(of: "email"))
        XCTAssertEqual(first, "deniz@example.t".count - 1)
        XCTAssertEqual(Set(words[..<first]), ["username"])
        XCTAssertEqual(Set(words[first...]), ["email"])
    }

    func testWhatIsNoAddress() {
        for username in [
            "deniz@", "@example.test", "@", "deniz@example", "deniz@localhost",
            "deniz@example.", "deniz@example.test.", "deniz@.com", "deniz@example..test",
            "deniz@@example.test", "deniz@example@com.tr", "a@b@c.d",
            "deniz @example.test", "deniz@exam ple.test", " deniz@example.test", "deniz@example.test ",
            "deniz@example.test\n", "deniz\t@example.test", "deniz@example.test\u{00A0}",
            "deniz.example.test", "10000000146", "example.test", " ", ".",
        ] {
            XCTAssertFalse(Login.isEmail(username), username)
            XCTAssertEqual(Login.word(forUsername: username), "username", username)
        }
    }

    func testWhatIsAnAddress() {
        for username in [
            "deniz@example.test", "DENIZ@EXAMPLE.TEST", "Deniz.Yilmaz@Mail.Example.Com.Tr",
            "çağrı@örnek.com.tr", "İREM@ŞİŞECAM.COM.TR", "ığüşöç@ığüşöç.tr",
            "deniz+alisveris@kanarya.invalid", "a@b.c", "o'neil@example.org", "x_y-z@sub.example.co",
        ] {
            XCTAssertTrue(Login.isEmail(username), username)
            XCTAssertEqual(Login.word(forUsername: username), "email", username)
        }
    }

    func testALoginSaysItsOwn() throws {
        func login(_ username: JSONValue) -> Login {
            Login(json: .object(["username": username, "password": .null, "totp": .null, "uris": .array([])]))
        }
        XCTAssertEqual(login(.string("deniz")).usernameWord, "username")
        XCTAssertEqual(login(.string("deniz@kanarya.invalid")).usernameWord, "email")
        XCTAssertEqual(login(.null).usernameWord, "username")
    }
}
