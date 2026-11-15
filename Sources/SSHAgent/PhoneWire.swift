import CryptoKit
import Foundation

/// The wire to OriCode for a phone's answer, as OP-88 writes it down: one JSON
/// object to a line, and what is signed. The one place its shapes are. OriCode
/// carries this and cannot make it: every signature is the phone's, over bytes
/// OriPass works out from its own copy of what it sent.
enum PhoneWire {
    /// A line longer than this closes the connection.
    static let most = 16_384
    static let version = 1
    /// The longest name a phone may give itself.
    static let longestName = 64
    private static let approving = "oripass.approve.v1"
    private static let registering = "oripass.register.v1"
    /// `04`, X and Y.
    private static let publicKeySize = 65
    private static let shownOfHash = 8

    /// Four bytes of length, most significant first, and these bytes. No JSON
    /// is signed, so none has to be put in any one order.
    static func field(_ bytes: some Collection<UInt8>) -> Data {
        var field = Data()
        field.appendCounted(bytes)
        return field
    }

    static func field(_ words: String) -> Data { field(Data(words.utf8)) }

    /// The first eight bytes of the key's hash, as the phone shows them too.
    static func fingerprint(of publicKey: Data) -> String {
        let hex = SHA256.hash(data: publicKey).prefix(shownOfHash).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { start -> String in
            let from = hex.index(hex.startIndex, offsetBy: start)
            return String(hex[from..<hex.index(from, offsetBy: 4)])
        }.joined(separator: "-")
    }

    /// What a new key signs to show it is the phone's and not only a key.
    static func registration(name: String, publicKey: Data) -> Data {
        Data(registering.utf8) + [0] + field(name) + field(publicKey)
    }

    static func verifies(_ signature: Data, over message: Data, by publicKey: Data) -> Bool {
        guard publicKey.count == publicKeySize, let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signature)
        else { return false }
        return key.isValidSignature(signature, for: message)
    }

    /// Thirty-two bytes from the system.
    static func nonce() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// The `id` and `nonce` go in by their bytes, and the rest behind a hash.
    fileprivate static func approval(id: String, nonce: Data, wordsHash: Data) -> Data {
        Data(approving.utf8) + [0] + field(id) + field(nonce) + wordsHash
    }

    static func time(_ moment: Date) -> String {
        ISO8601DateFormatter().string(from: moment)
    }
}

/// What a phone's yes is being asked for. A commit and a login to a known host
/// are not here: a pass signs those by itself.
enum PhoneAct: String {
    case stranger, forwarded, signature, list
}

/// How a request ended, which OriCode hears as `closed`.
enum PhoneOutcome: String {
    case approved, denied, expired, withdrawn, refused
    case answeredAtMac = "answered-at-mac"
}

enum PhoneRefusal: String {
    case badSignature = "bad-signature"
    case expired, replay
    case noPass = "no-pass"
}

/// One request as it goes down the socket, and the bytes the phone signs for
/// it. Empty strings stand for what has nothing to say, so that every field is
/// always hashed.
struct PhoneRequest: Equatable {
    let id: String
    let nonce: Data
    let act: PhoneAct
    let words: String
    let app: String
    let appID: String
    let key: String
    let keyFingerprint: String
    let host: String
    let hostKey: String
    let expires: String

    private var shown: [String] { [act.rawValue, words, app, appID, key, keyFingerprint, host, hostKey, expires] }

    var wordsHash: Data {
        Data(SHA256.hash(data: shown.reduce(into: Data()) { $0.append(PhoneWire.field($1)) }))
    }

    var message: Data { PhoneWire.approval(id: id, nonce: nonce, wordsHash: wordsHash) }

    var line: [String: Any] {
        ["type": "request", "id": id, "nonce": nonce.base64EncodedString(), "act": act.rawValue, "words": words,
         "app": app, "appID": appID, "key": key, "keyFingerprint": keyFingerprint, "host": host, "hostKey": hostKey,
         "expires": expires]
    }
}

extension SSHPhone {
    var fingerprint: String { PhoneWire.fingerprint(of: publicKey) }
}
