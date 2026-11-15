import Foundation
import Security

/// An account's private key, which the server keeps as PKCS#8 encrypted
/// under the user key. It opens what an organisation's key was sent in.
struct RSAPrivateKey: Redacted, @unchecked Sendable {
    private let key: SecKey

    var redactedLabel: String { "RSAPrivateKey" }

    /// Security wants the PKCS#1 key inside the PKCS#8 wrapper, so the
    /// wrapper's DER is read just far enough to find it.
    init(pkcs8: Data) throws {
        let inner = try DER.pkcs1(fromPKCS8: pkcs8)
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(inner as CFData, attributes as CFDictionary, &error) else {
            throw CryptoError.badKey
        }
        self.key = key
    }

    func decrypt(_ data: Data, sha256: Bool) throws -> Data {
        let algorithm: SecKeyAlgorithm = sha256 ? .rsaEncryptionOAEPSHA256 : .rsaEncryptionOAEPSHA1
        var error: Unmanaged<CFError>?
        guard let plain = SecKeyCreateDecryptedData(key, algorithm, data as CFData, &error) else {
            throw CryptoError.wrongKey
        }
        return plain as Data
    }
}

/// Just enough DER to take a key out of PKCS#8: a SEQUENCE holding a
/// version INTEGER, an algorithm SEQUENCE and an OCTET STRING with the key.
enum DER {
    static func pkcs1(fromPKCS8 data: Data) throws -> Data {
        var reader = Reader(bytes: [UInt8](data))
        var outer = try reader.element(tag: 0x30)
        _ = try outer.element(tag: 0x02)
        _ = try outer.element(tag: 0x30)
        let key = try outer.element(tag: 0x04)
        return Data(key.bytes)
    }

    struct Reader {
        var bytes: ArraySlice<UInt8>

        init(bytes: [UInt8]) { self.bytes = bytes[...] }
        init(slice: ArraySlice<UInt8>) { bytes = slice }

        mutating func element(tag: UInt8) throws -> Reader {
            guard let first = bytes.first, first == tag else { throw CryptoError.badKey }
            bytes = bytes.dropFirst()
            guard let lengthByte = bytes.first else { throw CryptoError.badKey }
            bytes = bytes.dropFirst()
            var length = Int(lengthByte)
            if lengthByte & 0x80 != 0 {
                let count = Int(lengthByte & 0x7f)
                guard count <= 4, bytes.count >= count else { throw CryptoError.badKey }
                length = bytes.prefix(count).reduce(0) { $0 << 8 | Int($1) }
                bytes = bytes.dropFirst(count)
            }
            guard bytes.count >= length else { throw CryptoError.badKey }
            let content = bytes.prefix(length)
            bytes = bytes.dropFirst(length)
            return Reader(slice: content)
        }
    }
}
