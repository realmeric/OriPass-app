import CryptoKit
import Foundation

/// An SSH key as Bitwarden's apps make one: Ed25519, its private key in
/// OpenSSH's own file with no passphrase and LF line ends, its public key
/// and its SHA-256 fingerprint as `PastedKey` reads them back.
enum SSHKeys {
    static func generate() -> PastedKey {
        let key = Curve25519.Signing.PrivateKey()
        let kind = Data("ssh-ed25519".utf8)
        let publicHalf = string(kind) + string(key.publicKey.rawRepresentation)
        let check = Random.bytes(4)
        var secret = check + check
        secret += string(kind)
        secret += string(key.publicKey.rawRepresentation)
        secret += string(key.rawRepresentation + key.publicKey.rawRepresentation)
        secret += string(Data())
        var pad: UInt8 = 1
        while secret.count % 8 != 0 {
            secret.append(pad)
            pad += 1
        }
        var file = Data("openssh-key-v1\0".utf8)
        file += string(Data("none".utf8)) + string(Data("none".utf8)) + string(Data())
        file += number(1) + string(publicHalf) + string(secret)
        let body = file.base64EncodedString()
        let lines = stride(from: 0, to: body.count, by: 70).map { start -> String in
            let from = body.index(body.startIndex, offsetBy: start)
            return String(body[from..<body.index(from, offsetBy: min(70, body.count - start))])
        }
        let text = ([PastedKey.first] + lines + [PastedKey.last]).joined(separator: "\n") + "\n"
        return try! PastedKey(pasted: text)
    }

    private static func number(_ value: Int) -> Data {
        withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) }
    }

    private static func string(_ data: Data) -> Data {
        number(data.count) + data
    }
}

extension PastedKey: @unchecked Sendable {}
