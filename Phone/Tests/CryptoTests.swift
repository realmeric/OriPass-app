import XCTest
@testable import OriPass

final class CryptoTests: XCTestCase {
    private var fixture: [String: Any]!

    override func setUpWithError() throws {
        fixture = try Fixture.json("crypto.json")
    }

    // MARK: Published vectors

    /// `bitwarden-crypto`'s `test_master_key_derive_pbkdf2`, its values only.
    func testBitwardensPBKDF2Vector() throws {
        let key = try Kdf.pbkdf2(iterations: 10_000).masterKey(password: SecretBytes("67t9b5g67$%Dh89n"), email: "test_key")
        XCTAssertEqual([UInt8](key), [31, 79, 104, 226, 150, 71, 177, 90, 194, 80, 172, 209, 17, 129, 132, 81,
                                      138, 167, 69, 167, 254, 149, 2, 27, 39, 197, 64, 42, 22, 195, 86, 75])
    }

    /// `bitwarden-crypto`'s `test_password_hash_pbkdf2`: the same hash for an
    /// email in another case and with a space before it.
    func testBitwardensServerHashVector() throws {
        for email in ["test@bitwarden.com", "TEST@bitwarden.com", " test@bitwarden.com"] {
            let password = SecretBytes("asdfasdf")
            let key = try Kdf.pbkdf2(iterations: 100_000).masterKey(password: password, email: email)
            XCTAssertEqual(try Kdf.serverHash(masterKey: key, password: password), "wmyadRMyBZOH7P/a/ucTCbSghKgdzDpPqUnu/DAVtSw=")
        }
    }

    /// RFC 7914, section 11, the first PBKDF2-HMAC-SHA256 vector.
    func testRFC7914() throws {
        let out = try Data("passwd".utf8).withUnsafeBytes {
            try PBKDF2.sha256(password: $0, salt: Data("salt".utf8), rounds: 1, length: 64)
        }
        XCTAssertEqual(out, Data(hex: """
            55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc
            49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783
            """))
    }

    /// RFC 5869, test case 1, the expand step, first block.
    func testRFC5869() {
        let prk = Data(hex: "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5")
        XCTAssertEqual(HKDF.expand(prk: prk, info: Data(hex: "f0f1f2f3f4f5f6f7f8f9")),
                       Data(hex: "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf"))
    }

    // MARK: What OpenSSL made

    func testAStringOpenSSLEncryptedOpens() throws {
        let key = try VaultKey(Data(b64: fixture["key"]))
        XCTAssertEqual(try EncString(fixture["type2"] as! String).decryptString(with: key), fixture["plain"] as? String)
    }

    func testAChangedByteIsRefusedBeforeItIsDecrypted() throws {
        let key = try VaultKey(Data(b64: fixture["key"]))
        guard case .aesCbcHmac(let iv, var data, let mac) = try EncString(fixture["type2"] as! String).body else {
            return XCTFail("not type 2")
        }
        data[data.startIndex] ^= 1
        XCTAssertThrowsError(try EncString(.aesCbcHmac(iv: iv, data: data, mac: mac)).decrypt(with: key)) {
            XCTAssertEqual($0 as? CryptoError, .wrongKey)
        }
    }

    func testTheMasterKeyTheStretchAndTheHashAreOpenSSLs() throws {
        let values = fixture["pbkdf2"] as! [String: Any]
        let password = SecretBytes(values["password"] as! String)
        let master = try Kdf.pbkdf2(iterations: values["iterations"] as! Int)
            .masterKey(password: password, email: values["email"] as! String)
        XCTAssertEqual(master, Data(b64: values["masterKey"]))
        let stretched = Kdf.stretch(master)
        XCTAssertEqual(stretched.encryption, Data(b64: values["enc"]))
        XCTAssertEqual(stretched.authentication, Data(b64: values["mac"]))
        XCTAssertEqual(try Kdf.serverHash(masterKey: master, password: password), values["serverHash"] as? String)
        XCTAssertEqual(try EncString(values["protectedUserKey"] as! String).decrypt(with: stretched), Data(b64: values["userKey"]))
    }

    func testAnOrganisationsKeyOpensWithTheAccountsPrivateKey() throws {
        let values = fixture["rsa"] as! [String: Any]
        let userKey = try VaultKey(Data(b64: (fixture["pbkdf2"] as! [String: Any])["userKey"]))
        let pkcs8 = try EncString(values["protectedPrivateKey"] as! String).decrypt(with: userKey)
        XCTAssertEqual(pkcs8, Data(b64: values["privateKey"]))
        let privateKey = try RSAPrivateKey(pkcs8: pkcs8)
        for type in ["type4", "type3"] {
            XCTAssertEqual(try EncString(values[type] as! String).decrypt(with: privateKey), Data(b64: values["orgKey"]))
        }
    }

    // MARK: Shapes

    func testARoundTripAndItsText() throws {
        let key = VaultKey.random()
        let sealed = try EncString.encrypt("çay ☕︎", with: key)
        XCTAssertEqual(try EncString(sealed.text), sealed)
        XCTAssertEqual(try sealed.decryptString(with: key), "çay ☕︎")
        XCTAssertNotEqual(try EncString.encrypt("çay ☕︎", with: key), sealed, "a fresh IV each time")
    }

    func testTypeSevenIsNamedAndRefused() throws {
        let cose = try EncString("7." + Data([0xd2, 0x84]).base64EncodedString())
        XCTAssertEqual(cose.type, 7)
        XCTAssertThrowsError(try cose.decrypt(with: VaultKey.random())) {
            XCTAssertEqual($0 as? CryptoError, .unsupported(type: 7))
        }
    }

    func testTextThatIsNoStringIsUnreadable() {
        for text in ["", "2.abc", "2.AAAA|BBBB", "hello", "9.AAAA"] {
            XCTAssertThrowsError(try EncString(text), text)
        }
    }

    func testAStringSaysItsTypeAndNothingElse() throws {
        let sealed = try EncString.encrypt("kanarya", with: VaultKey.random())
        XCTAssertEqual("\(sealed)", "EncString(2)")
        XCTAssertEqual("\(VaultKey.random())", "VaultKey(64)")
    }
}
