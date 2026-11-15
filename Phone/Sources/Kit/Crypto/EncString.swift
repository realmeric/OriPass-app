import CommonCrypto
import CryptoKit
import Foundation

/// A value as Bitwarden encrypts it: a type, a dot, and its parts in base64
/// joined by bars. Type 2 is AES-256-CBC with an HMAC-SHA256 over the IV and
/// the ciphertext, and is what nearly every string in a vault is. Type 0 is
/// the same with no MAC, kept for the oldest user keys. Types 3 to 6 are RSA,
/// for an organisation's key. Type 7 is the newer COSE format, recognised and
/// refused. A string with no type before a dot is the oldest form of all, 0
/// with two parts.
struct EncString: Redacted, Sendable, Equatable {
    enum Body: Equatable, Sendable {
        case aesCbc(iv: Data, data: Data)
        case aesCbcHmac(iv: Data, data: Data, mac: Data)
        case rsa(type: Int, data: Data)
        case cose(Data)
    }

    let body: Body

    var redactedLabel: String { "EncString(\(type))" }

    var type: Int {
        switch body {
        case .aesCbc: 0
        case .aesCbcHmac: 2
        case .rsa(let type, _): type
        case .cose: 7
        }
    }

    init(_ body: Body) {
        self.body = body
    }

    init(_ text: String) throws {
        let header = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let type: Int
        let rest: Substring
        if header.count == 2, let written = Int(header[0]) {
            type = written
            rest = header[1]
        } else {
            type = 0
            rest = Substring(text)
        }
        let parts = try rest.split(separator: "|", omittingEmptySubsequences: false).map { part in
            guard let data = Data(base64Encoded: String(part)) else { throw CryptoError.unreadable }
            return data
        }
        switch (type, parts.count) {
        case (0, 2) where parts[0].count == 16:
            body = .aesCbc(iv: parts[0], data: parts[1])
        case (2, 3) where parts[0].count == 16 && parts[2].count == 32:
            body = .aesCbcHmac(iv: parts[0], data: parts[1], mac: parts[2])
        case (3, 1), (4, 1):
            body = .rsa(type: type, data: parts[0])
        case (5, 2), (6, 2):
            // The MAC beside an RSA string was never checked by anyone and
            // proves nothing: whoever can encrypt to the key can make one.
            body = .rsa(type: type, data: parts[0])
        case (7, 1):
            body = .cose(parts[0])
        case (1, _), (7, _), (8..., _):
            throw CryptoError.unsupported(type: type)
        default:
            throw CryptoError.unreadable
        }
    }

    var text: String {
        switch body {
        case .aesCbc(let iv, let data): "0.\(iv.base64EncodedString())|\(data.base64EncodedString())"
        case .aesCbcHmac(let iv, let data, let mac):
            "2.\(iv.base64EncodedString())|\(data.base64EncodedString())|\(mac.base64EncodedString())"
        case .rsa(let type, let data): "\(type).\(data.base64EncodedString())"
        case .cose(let data): "7.\(data.base64EncodedString())"
        }
    }

    // MARK: Symmetric

    /// The bytes inside. A type 2 string is opened only after its MAC is
    /// found to be the key's; a type 2 string under a key with no MAC key,
    /// and a type 0 string under one that has one, are refused.
    func decrypt(with key: VaultKey) throws -> Data {
        switch body {
        case .aesCbc(let iv, let data):
            guard key.authentication == nil else { throw CryptoError.wrongKey }
            return try AES.cbc(decrypting: data, key: key.encryption, iv: iv)
        case .aesCbcHmac(let iv, let data, let mac):
            guard let macKey = key.authentication else { throw CryptoError.wrongKey }
            guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: iv + data, using: SymmetricKey(data: macKey))
            else { throw CryptoError.wrongKey }
            return try AES.cbc(decrypting: data, key: key.encryption, iv: iv)
        case .rsa, .cose:
            throw CryptoError.unsupported(type: type)
        }
    }

    func decryptString(with key: VaultKey) throws -> String {
        guard let string = String(data: try decrypt(with: key), encoding: .utf8) else { throw CryptoError.unreadable }
        return string
    }

    /// Type 2 under a fresh IV.
    static func encrypt(_ plain: Data, with key: VaultKey) throws -> EncString {
        guard let macKey = key.authentication else { throw CryptoError.badKey }
        let iv = Random.bytes(16)
        let data = try AES.cbc(encrypting: plain, key: key.encryption, iv: iv)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: iv + data, using: SymmetricKey(data: macKey)))
        return EncString(.aesCbcHmac(iv: iv, data: data, mac: mac))
    }

    static func encrypt(_ plain: String, with key: VaultKey) throws -> EncString {
        try encrypt(Data(plain.utf8), with: key)
    }

    // MARK: Asymmetric

    /// The bytes inside an RSA string: 3 and 5 are OAEP with SHA-256, 4 and
    /// 6 OAEP with SHA-1, which is what the server sends organisations' keys
    /// in.
    func decrypt(with key: RSAPrivateKey) throws -> Data {
        guard case .rsa(let type, let data) = body else { throw CryptoError.unsupported(type: self.type) }
        return try key.decrypt(data, sha256: type == 3 || type == 5)
    }
}

/// AES-256 in CBC mode with PKCS#7 padding, which CryptoKit does not have.
enum AES {
    static func cbc(decrypting data: Data, key: Data, iv: Data) throws -> Data {
        try crypt(CCOperation(kCCDecrypt), data, key: key, iv: iv)
    }

    static func cbc(encrypting data: Data, key: Data, iv: Data) throws -> Data {
        try crypt(CCOperation(kCCEncrypt), data, key: key, iv: iv)
    }

    private static func crypt(_ operation: CCOperation, _ data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES256, iv.count == kCCBlockSizeAES128 else { throw CryptoError.badKey }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var written = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                dataBytes.baseAddress, data.count,
                                outBytes.baseAddress, outCount, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.failed(status) }
        return out.prefix(written)
    }
}
