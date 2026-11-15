import CryptoKit
import Foundation

/// A one-time code's secret, read once from what `login.totp` holds, and the
/// code it makes at any moment (`docs/notes.md`, "One-time codes"; D12).
///
/// The field holds one of three things: a bare base32 secret, an
/// `otpauth://` address that may also say the period, the number of digits
/// and the hash, or `steam://` and a secret, whose codes are five characters
/// from an alphabet of Steam's own. The arithmetic is RFC 6238's, with
/// CryptoKit's HMAC. Nothing here keeps time: a code is asked for with the
/// moment it is wanted at.
struct Totp: Redacted, Equatable {
    enum Hash: String {
        case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512"
    }

    /// What a row says in the code's place when the secret cannot be read.
    static let invalid = "invalid secret"

    static let standardPeriod = 30
    static let standardDigits = 6
    /// The most digits a code is given, as the other clients have it.
    static let mostDigits = 10
    static let steamAlphabet = Array("23456789BCDFGHJKMNPQRTVWXY")
    static let steamLength = 5

    private let key: [UInt8]
    /// How many seconds a code stands for.
    let period: Int
    let digits: Int
    let hash: Hash
    let isSteam: Bool

    var redactedLabel: String { "Totp" }

    /// Nil when there is no secret in `written`, or it is not base32.
    init?(_ written: String) {
        let written = written.trimmingCharacters(in: .whitespacesAndNewlines)
        var secret = written
        var period = Self.standardPeriod
        var digits = Self.standardDigits
        var hash = Hash.sha1
        var isSteam = false

        let lowered = written.lowercased()
        if lowered.hasPrefix("otpauth://") {
            let query = URLComponents(string: written)?.queryItems ?? []
            func named(_ name: String) -> String? {
                query.first { $0.name.lowercased() == name }?.value
            }
            guard let said = named("secret") else { return nil }
            secret = said
            if let said = named("period").flatMap(Int.init), said > 0 { period = said }
            if let said = named("digits").flatMap(Int.init), said > 0 { digits = min(said, Self.mostDigits) }
            if let said = named("algorithm").flatMap({ Hash(rawValue: $0.uppercased()) }) { hash = said }
        } else if lowered.hasPrefix("steam://") {
            secret = String(written.dropFirst("steam://".count))
            digits = Self.steamLength
            isSteam = true
        }

        guard let key = Self.base32(secret), !key.isEmpty else { return nil }
        self.key = key
        self.period = period
        self.digits = digits
        self.hash = hash
        self.isSteam = isSteam
    }

    // MARK: The code

    /// The code that stands at `moment`.
    func code(at moment: Date) -> String {
        let counter = UInt64(max(0, moment.timeIntervalSince1970)) / UInt64(period)
        let message = withUnsafeBytes(of: counter.bigEndian) { Data($0) }
        let mac = signed(message)
        // RFC 4226's truncation: the last four bits say where to read
        // thirty-one of the rest.
        let offset = Int(mac[mac.count - 1] & 0x0F)
        var number = UInt32(mac[offset] & 0x7F) << 24 | UInt32(mac[offset + 1]) << 16
            | UInt32(mac[offset + 2]) << 8 | UInt32(mac[offset + 3])

        if isSteam {
            var code = ""
            let count = UInt32(Self.steamAlphabet.count)
            for _ in 0..<digits {
                code.append(Self.steamAlphabet[Int(number % count)])
                number /= count
            }
            return code
        }
        var modulus: UInt64 = 1
        for _ in 0..<digits { modulus *= 10 }
        let tail = String(UInt64(number) % modulus)
        return String(repeating: "0", count: max(0, digits - tail.count)) + tail
    }

    private func signed(_ message: Data) -> [UInt8] {
        let key = SymmetricKey(data: key)
        switch hash {
        case .sha1: return Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: return Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: return Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
    }

    /// Whole seconds until the code at `moment` gives way to the next, from
    /// the period down to one.
    func secondsLeft(at moment: Date) -> Int {
        period - Int(max(0, moment.timeIntervalSince1970)) % period
    }

    /// How much of its period the code at `moment` still has, from one down
    /// towards nought: what the ring is filled by.
    func share(at moment: Date) -> Double {
        Double(secondsLeft(at: moment)) / Double(period)
    }

    /// A code in the groups it is read out in: two of three for six digits,
    /// two of four for eight, and anything that does not halve as it is.
    static func grouped(_ code: String) -> [String] {
        guard code.count >= 6, code.count.isMultiple(of: 2) else { return [code] }
        let half = code.count / 2
        return [String(code.prefix(half)), String(code.suffix(half))]
    }

    // MARK: Base32

    /// RFC 4648's alphabet, in either case, with the spaces and hyphens a
    /// site prints its secret in and the padding at its end left out. Nil
    /// for any other character.
    static func base32(_ written: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        var held: UInt32 = 0
        var bits = 0
        for scalar in written.unicodeScalars {
            let value: UInt32
            switch scalar {
            case "A"..."Z": value = scalar.value - 65
            case "a"..."z": value = scalar.value - 97
            case "2"..."7": value = scalar.value - 50 + 26
            case " ", "-", "=": continue
            default: return nil
            }
            held = (held << 5 | value) & 0xFFF
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8(held >> UInt32(bits) & 0xFF))
            }
        }
        return bytes
    }
}
