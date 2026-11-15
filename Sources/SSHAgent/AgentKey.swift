import CryptoKit
import Foundation
import Security

/// The kinds of key the agent signs with, by the name the protocol gives
/// each. A key of any other kind stays in the vault and is not listed.
enum AgentKeyKind: String {
    case ed25519 = "ssh-ed25519"
    case p256 = "ecdsa-sha2-nistp256"
    case p384 = "ecdsa-sha2-nistp384"
    case p521 = "ecdsa-sha2-nistp521"
    case rsa = "ssh-rsa"

    /// The curve as a key's own bytes name it, and how long its numbers are.
    fileprivate var curve: (name: String, width: Int)? {
        switch self {
        case .p256: return ("nistp256", 32)
        case .p384: return ("nistp384", 48)
        case .p521: return ("nistp521", 66)
        case .ed25519, .rsa: return nil
        }
    }
}

/// One key the agent can offer: the public half and what to call it, which
/// is all it holds of an item between signatures. In memory only, and the
/// lock drops it (D6).
struct AgentKey: Hashable {
    /// The item it was read from.
    let id: String
    let name: String
    let kind: AgentKeyKind
    /// The public half as the protocol writes it.
    let blob: Data

    /// The two flags that ask for a signature an RSA key will make.
    static let rsaFlags = RSA.sha256 | RSA.sha512

    var fingerprint: String { SSHFingerprint(of: blob) }
}

/// A key's public half as `ssh-keygen -l` names it.
func SSHFingerprint(of blob: Data) -> String {
    "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().trimmingCharacters(in: ["="])
}

/// The private half of one key, read out of the item's OpenSSH file for as
/// long as it takes to sign, and wiped by whoever made it (D4, D6).
///
/// `PastedKey`'s reader, taken further and over `SecretBytes`: the file goes
/// from the item's text into one allocation with no `Data` and no `String`
/// on the way, the numbers are read where they lie, and what CryptoKit and
/// Security are handed they keep in memory of their own that they wipe. A
/// file with a passphrase on it, and any kind not named above, is no key
/// here.
final class PrivateHalf: Redacted {
    private let file: SecretBytes

    var redactedLabel: String { "PrivateHalf" }

    /// Nil for anything but OpenSSH's armour around base64. What is inside
    /// is `publicKey`'s to say.
    init?(_ text: String) {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count > 2, lines.first == PastedKey.first, lines.last == PastedKey.last,
              let file = SecretBytes.decodingBase64(lines[1..<(lines.count - 1)].lazy.flatMap(\.utf8),
                                                    capacity: lines.reduce(0) { $0 + $1.utf8.count })
        else { return nil }
        self.file = file
    }

    deinit { file.wipe() }

    func wipe() { file.wipe() }

    /// For a pass, which keeps this for hours: the pages stay in memory and
    /// out of the swap file. Nothing is lost if the system says no but that.
    func pin() { file.withBytes { _ = mlock($0.baseAddress, $0.count) } }

    func unpin() { file.withBytes { _ = munlock($0.baseAddress, $0.count) } }

    /// For a test, which keeps these to read them back after a wipe.
    var heldBytes: SecretBytes { file }

    /// The public half and the name of its kind, when the private half
    /// says it is the same kind: that first look is what tells a key from a
    /// file that only has the shape of one.
    var publicKey: (kind: AgentKeyKind, blob: Data)? {
        file.withBytes { bytes in
            guard let (publicHalf, privateHalf) = Self.sections(of: bytes) else { return nil }
            var named = SSHReader(publicHalf)
            var inside = SSHReader(privateHalf)
            guard let kind = named.word().flatMap(AgentKeyKind.init(rawValue:)),
                  let first = inside.number(), first == inside.number(), inside.word() == kind.rawValue
            else { return nil }
            return (kind, Data(publicHalf))
        }
    }

    /// A signature as the protocol carries one. Nil when the file does not
    /// hold what it says it holds, and for `ssh-rsa`'s SHA-1, which is
    /// never made: an RSA key signs only under one of the two `flags` ask
    /// for.
    func sign(_ data: Data, flags: UInt32 = 0) -> Data? {
        file.withBytes { bytes in
            guard let (_, privateHalf) = Self.sections(of: bytes) else { return nil }
            var reader = SSHReader(privateHalf)
            guard let first = reader.number(), first == reader.number(),
                  let kind = reader.word().flatMap(AgentKeyKind.init(rawValue:))
            else { return nil }
            switch kind {
            case .ed25519: return Self.signEd25519(&reader, data)
            case .p256, .p384, .p521: return Self.signECDSA(kind, &reader, data)
            case .rsa: return Self.signRSA(&reader, data, flags: flags)
            }
        }
    }

    // MARK: The file

    private static let magic = Data("openssh-key-v1\0".utf8)

    /// The names of the cipher and of the way its key is made, that way's
    /// options, how many keys, the public half, the private half.
    private static func sections(of file: UnsafeRawBufferPointer)
        -> (publicHalf: UnsafeRawBufferPointer, privateHalf: UnsafeRawBufferPointer)? {
        guard file.starts(with: magic) else { return nil }
        var reader = SSHReader(UnsafeRawBufferPointer(rebasing: file.dropFirst(magic.count)))
        guard reader.word() == "none", reader.string() != nil, reader.string() != nil, reader.number() == 1,
              let publicHalf = reader.string(), let privateHalf = reader.string(), reader.isAtEnd
        else { return nil }
        return (publicHalf, privateHalf)
    }

    // MARK: Signing

    private static func written(_ kind: String, _ signature: some Collection<UInt8>) -> Data {
        var blob = Data()
        blob.appendCounted(Data(kind.utf8))
        blob.appendCounted(signature)
        return blob
    }

    /// The public half, and sixty-four bytes of which the first thirty-two
    /// are the key.
    private static func signEd25519(_ reader: inout SSHReader, _ data: Data) -> Data? {
        guard reader.string()?.count == 32, let both = reader.string(), both.count == 64,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: UnsafeRawBufferPointer(rebasing: both.prefix(32))),
              let signature = try? key.signature(for: data)
        else { return nil }
        return written(AgentKeyKind.ed25519.rawValue, signature)
    }

    /// The curve's name, the public point, the private number.
    private static func signECDSA(_ kind: AgentKeyKind, _ reader: inout SSHReader, _ data: Data) -> Data? {
        guard let curve = kind.curve, reader.word() == curve.name, reader.string() != nil,
              let number = reader.integer(), number.count <= curve.width
        else { return nil }
        let scalar = SecretBytes(capacity: curve.width)
        defer { scalar.wipe() }
        zeros(curve.width - number.count).withUnsafeBytes { scalar.append($0) }
        scalar.append(number)
        let raw: Data?
        switch kind {
        case .p256: raw = scalar.withBytes { try? P256.Signing.PrivateKey(rawRepresentation: $0).signature(for: data).rawRepresentation }
        case .p384: raw = scalar.withBytes { try? P384.Signing.PrivateKey(rawRepresentation: $0).signature(for: data).rawRepresentation }
        case .p521: raw = scalar.withBytes { try? P521.Signing.PrivateKey(rawRepresentation: $0).signature(for: data).rawRepresentation }
        case .ed25519, .rsa: raw = nil
        }
        guard let raw, raw.count == curve.width * 2 else { return nil }
        var pair = Data()
        pair.appendInteger(raw.prefix(curve.width))
        pair.appendInteger(raw.suffix(curve.width))
        return written(kind.rawValue, pair)
    }

    /// The modulus, the two exponents, the inverse of q, the two primes, in
    /// the file's order. PKCS#1 wants two numbers the file leaves out.
    private static func signRSA(_ reader: inout SSHReader, _ data: Data, flags: UInt32) -> Data? {
        guard let (name, algorithm) = rsaAlgorithm(flags: flags),
              let n = reader.integer(), let e = reader.integer(), let d = reader.integer(),
              let inverse = reader.integer(), let p = reader.integer(), let q = reader.integer(),
              let p1 = lessOne(p), let q1 = lessOne(q)
        else { return nil }
        let dp = remainder(of: d, by: p1), dq = remainder(of: d, by: q1)
        defer { [p1, q1, dp, dq].forEach { $0.wipe() } }
        let der = dp.withBytes { dp in
            dq.withBytes { dq in DER.sequence(of: [UnsafeRawBufferPointer(start: nil, count: 0), n, e, d, p, q, dp, dq, inverse]) }
        }
        defer { der.wipe() }
        guard let key = RSA.key(der, isPrivate: true),
              let signature = SecKeyCreateSignature(key, algorithm, data as CFData, nil) as Data?
        else { return nil }
        return written(name, signature)
    }

    private static func rsaAlgorithm(flags: UInt32) -> (String, SecKeyAlgorithm)? {
        if flags & RSA.sha256 != 0 { return (RSA.name256, .rsaSignatureMessagePKCS1v15SHA256) }
        if flags & RSA.sha512 != 0 { return (RSA.name512, .rsaSignatureMessagePKCS1v15SHA512) }
        return nil
    }

    private static func zeros(_ count: Int) -> [UInt8] { [UInt8](repeating: 0, count: count) }

    /// A prime less one, which for an odd number is its last bit off.
    private static func lessOne(_ prime: UnsafeRawBufferPointer) -> SecretBytes? {
        guard prime.last.map({ $0 & 1 == 1 }) == true else { return nil }
        let less = SecretBytes(capacity: prime.count)
        less.append(prime)
        less.withMutableBytes { $0[$0.count - 1] &= 0xFE }
        return less
    }

    /// `value` modulo `modulus`, a bit at a time: double, bring the next
    /// bit in, take the modulus off if it went in. Slow, and for two numbers
    /// a signature.
    private static func remainder(of value: UnsafeRawBufferPointer, by modulus: SecretBytes) -> SecretBytes {
        let rest = SecretBytes(capacity: modulus.count)
        zeros(modulus.count).withUnsafeBytes { rest.append($0) }
        modulus.withBytes { modulus in
            rest.withMutableBytes { rest in
                for byte in value {
                    for shift in stride(from: 7, through: 0, by: -1) {
                        var carry = (byte >> UInt8(shift)) & 1
                        for index in rest.indices.reversed() {
                            let held = rest[index]
                            rest[index] = held << 1 | carry
                            carry = held >> 7
                        }
                        guard carry == 1 || !rest.lexicographicallyPrecedes(modulus) else { continue }
                        var borrow = 0
                        for index in rest.indices.reversed() {
                            let difference = Int(rest[index]) - Int(modulus[index]) - borrow
                            rest[index] = UInt8(truncatingIfNeeded: difference)
                            borrow = difference < 0 ? 1 : 0
                        }
                    }
                }
            }
        }
        return rest
    }
}

/// What the two sides of an RSA signature share.
fileprivate enum RSA {
    /// `SSH_AGENT_RSA_SHA2_256` and `_512`.
    static let sha256: UInt32 = 2
    static let sha512: UInt32 = 4
    static let name256 = "rsa-sha2-256"
    static let name512 = "rsa-sha2-512"

    /// Handed over with no copy of its own, so the only copy left to think
    /// about is the one Security makes and looks after.
    static func key(_ der: SecretBytes, isPrivate: Bool) -> SecKey? {
        der.withBytes { bytes in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                  let data = CFDataCreateWithBytesNoCopy(nil, base, bytes.count, kCFAllocatorNull)
            else { return nil }
            let attributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                              kSecAttrKeyClass: isPrivate ? kSecAttrKeyClassPrivate : kSecAttrKeyClassPublic] as CFDictionary
            return SecKeyCreateWithData(data, attributes, nil)
        }
    }
}

/// The two shapes PKCS#1 needs: a sequence of integers.
private enum DER {
    private static func appendLength(_ length: Int, to out: SecretBytes) {
        var written: [UInt8] = length < 0x80 ? [UInt8(length)] : []
        if length >= 0x80 {
            let bytes = withUnsafeBytes(of: UInt32(length).bigEndian, Array.init).drop { $0 == 0 }
            written = [0x80 | UInt8(bytes.count)] + bytes
        }
        written.withUnsafeBytes { out.append($0) }
    }

    /// An empty number is a zero.
    static func sequence(of integers: [UnsafeRawBufferPointer]) -> SecretBytes {
        let body = SecretBytes(capacity: integers.reduce(0) { $0 + $1.count + 8 })
        defer { body.wipe() }
        for integer in integers {
            let value = UnsafeRawBufferPointer(rebasing: integer.drop { $0 == 0 })
            let pads = value.first.map { $0 >= 0x80 } ?? true
            [UInt8(2)].withUnsafeBytes { body.append($0) }
            appendLength(value.count + (pads ? 1 : 0), to: body)
            if pads { [UInt8(0)].withUnsafeBytes { body.append($0) } }
            body.append(value)
        }
        let out = SecretBytes(capacity: body.count + 8)
        [UInt8(0x30)].withUnsafeBytes { out.append($0) }
        appendLength(body.count, to: out)
        out.append(body)
        return out
    }
}

/// Whether `signature`, as the protocol carries one, is `key`'s over `data`.
/// `session-bind` is what asks: it says which host a connection is for, and
/// a host that did not sign is not that host. SHA-1 is no signature here, as
/// on the way out.
func SSHVerifies(_ signature: Data, over data: Data, by key: Data) -> Bool {
    signature.withUnsafeBytes { signature in
        key.withUnsafeBytes { key in
            var said = SSHReader(signature)
            var named = SSHReader(key)
            guard let algorithm = said.word(), let body = said.data(), said.isAtEnd,
                  let kind = named.word().flatMap(AgentKeyKind.init(rawValue:))
            else { return false }
            switch kind {
            case .ed25519:
                guard algorithm == kind.rawValue, let point = named.data(),
                      let verifier = try? Curve25519.Signing.PublicKey(rawRepresentation: point)
                else { return false }
                return verifier.isValidSignature(body, for: data)
            case .p256, .p384, .p521:
                guard algorithm == kind.rawValue, let curve = kind.curve, named.word() == curve.name,
                      let point = named.data()
                else { return false }
                return verifyECDSA(kind, curve.width, body, data, point)
            case .rsa:
                let chosen: SecKeyAlgorithm
                switch algorithm {
                case RSA.name256: chosen = .rsaSignatureMessagePKCS1v15SHA256
                case RSA.name512: chosen = .rsaSignatureMessagePKCS1v15SHA512
                default: return false
                }
                guard let e = named.integer(), let n = named.integer() else { return false }
                let der = DER.sequence(of: [n, e])
                defer { der.wipe() }
                guard let verifier = RSA.key(der, isPrivate: false) else { return false }
                return SecKeyVerifySignature(verifier, chosen, data as CFData, body as CFData, nil)
            }
        }
    }
}

private func verifyECDSA(_ kind: AgentKeyKind, _ width: Int, _ body: Data, _ data: Data, _ point: Data) -> Bool {
    let raw: Data? = body.withUnsafeBytes { body in
        var pair = SSHReader(body)
        guard let r = pair.integer(), let s = pair.integer(), pair.isAtEnd, r.count <= width, s.count <= width
        else { return nil }
        return Data(count: width - r.count) + r + Data(count: width - s.count) + s
    }
    guard let raw else { return false }
    switch kind {
    case .p256:
        guard let verifier = try? P256.Signing.PublicKey(x963Representation: point),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw) else { return false }
        return verifier.isValidSignature(signature, for: data)
    case .p384:
        guard let verifier = try? P384.Signing.PublicKey(x963Representation: point),
              let signature = try? P384.Signing.ECDSASignature(rawRepresentation: raw) else { return false }
        return verifier.isValidSignature(signature, for: data)
    case .p521:
        guard let verifier = try? P521.Signing.PublicKey(x963Representation: point),
              let signature = try? P521.Signing.ECDSASignature(rawRepresentation: raw) else { return false }
        return verifier.isValidSignature(signature, for: data)
    case .ed25519, .rsa:
        return false
    }
}

extension SecretBytes {
    /// Base64 by hand, since `Data(base64Encoded:)` would leave a copy of
    /// the key that nobody can wipe. Nil for a character it does not have.
    static func decodingBase64(_ characters: some Sequence<UInt8>, capacity: Int) -> SecretBytes? {
        let file = SecretBytes(capacity: capacity)
        var held: UInt32 = 0
        var bits = 0
        var padding = 0
        for character in characters {
            if character == UInt8(ascii: "=") {
                padding += 1
                continue
            }
            guard padding == 0, let value = sextet(character) else {
                file.wipe()
                return nil
            }
            held = held << 6 | value
            bits += 6
            if bits >= 8 {
                bits -= 8
                var byte = UInt8(truncatingIfNeeded: held >> UInt32(bits))
                withUnsafeBytes(of: &byte) { file.append($0) }
            }
        }
        held = 0
        return file
    }

    private static func sextet(_ character: UInt8) -> UInt32? {
        switch character {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return UInt32(character) - 65
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return UInt32(character) - 71
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt32(character) + 4
        case UInt8(ascii: "+"): return 62
        case UInt8(ascii: "/"): return 63
        default: return nil
        }
    }
}
