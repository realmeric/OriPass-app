import CommonCrypto
import CryptoKit
import Foundation

/// How a master password becomes the master key, as the account's prelogin
/// says. The salt is the email, trimmed and in lower case: as it is for
/// PBKDF2, and through SHA-256 for Argon2id, whose memory is given in MiB.
enum Kdf: Equatable, Sendable, Codable {
    case pbkdf2(iterations: Int)
    case argon2id(iterations: Int, memory: Int, parallelism: Int)

    static func salt(for email: String) -> Data {
        Data(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8)
    }

    func masterKey(password: SecretBytes, email: String) throws -> Data {
        try masterKey(password: password, salt: Kdf.salt(for: email))
    }

    func masterKey(password: SecretBytes, salt: Data) throws -> Data {
        switch self {
        case .pbkdf2(let iterations):
            return try password.withBytes { try PBKDF2.sha256(password: $0, salt: salt, rounds: iterations) }
        case .argon2id(let iterations, let memory, let parallelism):
            return try password.withBytes {
                try Argon2id.hash(password: $0, salt: Data(SHA256.hash(data: salt)),
                                  iterations: iterations, memoryKiB: memory * 1024, parallelism: parallelism)
            }
        }
    }

    /// The master key made into a key that can open the user key: HKDF's
    /// expand step alone, once with "enc" and once with "mac".
    static func stretch(_ masterKey: Data) -> VaultKey {
        VaultKey(encryption: HKDF.expand(prk: masterKey, info: Data("enc".utf8)),
                 authentication: HKDF.expand(prk: masterKey, info: Data("mac".utf8)))
    }

    /// What the server is sent in place of the password: one more round of
    /// PBKDF2 over the master key, salted with the password.
    static func serverHash(masterKey: Data, password: SecretBytes) throws -> String {
        try password.withBytes { passwordBytes in
            try masterKey.withUnsafeBytes { keyBytes in
                try PBKDF2.sha256(password: keyBytes, salt: Data(passwordBytes), rounds: 1)
            }
        }.base64EncodedString()
    }
}

enum PBKDF2 {
    static func sha256(password: UnsafeRawBufferPointer, salt: Data, rounds: Int, length: Int = 32) throws -> Data {
        var out = Data(count: length)
        let status = out.withUnsafeMutableBytes { outBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     password.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                     saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                                     outBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), length)
            }
        }
        guard status == kCCSuccess else { throw CryptoError.failed(status) }
        return out
    }
}

enum HKDF {
    /// RFC 5869's expand, with SHA-256, for at most one block, which is all
    /// Bitwarden asks of it.
    static func expand(prk: Data, info: Data, length: Int = 32) -> Data {
        precondition(length <= 32)
        let block = HMAC<SHA256>.authenticationCode(for: info + Data([1]), using: SymmetricKey(data: prk))
        return Data(block).prefix(length)
    }
}

/// The Mac's `SecretBytes`, which a password is on the phone too. It goes to
/// the thread the KDF runs on and comes back; nothing holds it on two
/// threads at once.
extension SecretBytes: @unchecked Sendable {}
