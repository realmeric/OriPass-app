import XCTest
@testable import OriPass

final class Argon2idTests: XCTestCase {
    /// RFC 7693, appendix A.
    func testBlake2bOfABC() {
        XCTAssertEqual(Blake2b.hash(Data("abc".utf8)), Data(hex: """
            ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d1
            7d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923
            """))
    }

    /// RFC 9106, section 5.3.
    func testRFC9106() throws {
        let tag = try Data(repeating: 1, count: 32).withUnsafeBytes {
            try Argon2id.hash(password: $0, salt: Data(repeating: 2, count: 16), iterations: 3, memoryKiB: 32,
                              parallelism: 4, secret: Data(repeating: 3, count: 8), associated: Data(repeating: 4, count: 12))
        }
        XCTAssertEqual(tag, Data(hex: "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659"))
    }

    /// `bitwarden-crypto`'s `test_master_key_derive_argon2`, its values only.
    func testBitwardensArgon2idVector() throws {
        let key = try Kdf.argon2id(iterations: 4, memory: 32, parallelism: 2)
            .masterKey(password: SecretBytes("67t9b5g67$%Dh89n"), email: "test_key")
        XCTAssertEqual([UInt8](key), [207, 240, 225, 177, 162, 19, 163, 76, 98, 106, 179, 175, 224, 9, 17, 240,
                                      20, 147, 237, 47, 246, 150, 141, 184, 62, 225, 131, 242, 51, 53, 225, 242])
    }

    /// `bitwarden-crypto`'s `test_password_hash_argon2id`.
    func testBitwardensArgon2idServerHash() throws {
        let password = SecretBytes("asdfasdf")
        let key = try Kdf.argon2id(iterations: 4, memory: 32, parallelism: 2).masterKey(password: password, email: "test_salt")
        XCTAssertEqual(try Kdf.serverHash(masterKey: key, password: password), "PR6UjYmjmppTYcdyTiNbAhPJuQQOmynKbdEl1oyi/iQ=")
    }

    /// Bitwarden's defaults, 64 MiB over three passes and four lanes, against
    /// what `openssl kdf ... ARGON2ID` gave for the same, and timed for
    /// docs/notes-ios.md.
    func testTheDefaultsAreOpenSSLs() throws {
        let start = Date()
        let key = try Kdf.argon2id(iterations: 3, memory: 64, parallelism: 4).masterKey(password: SecretBytes("demo"), email: "a@b.c")
        print("argon2id-defaults-seconds", String(format: "%.3f", Date().timeIntervalSince(start)))
        XCTAssertEqual(key, Data(hex: "33c614add9c51db1a0f41c5a7721ba97e09b03c4395485a4ca6906ee7dcdcd5f"))
    }
}
