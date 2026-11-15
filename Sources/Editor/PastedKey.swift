import CryptoKit
import Foundation

/// A private key as it was pasted, with the two things an item keeps beside
/// it (`docs/notes.md`, "Editing an item"). OpenSSH's file carries the
/// public half in the clear ahead of the private one, so both are read off
/// it and nothing is computed from the key itself: the public key is that
/// half as a `.pub` file writes it, and the fingerprint is its SHA-256.
///
/// Only a whole file in OpenSSH's own format with no passphrase on it is
/// one. Anything else is refused with a sentence, and the form keeps the key
/// it had.
struct PastedKey: Equatable, Redacted {
    enum Refusal: Error, Equatable {
        case notAKey, anotherFormat, cutShort, locked

        var sentence: String {
            switch self {
            case .notAKey:
                return "The pasteboard does not hold a private key."
            case .anotherFormat:
                return "That key is in a format this form does not read. "
                    + "Paste one that begins \(PastedKey.first)."
            case .cutShort:
                return "That is not a whole key. Copy the file from its first line to its last."
            case .locked:
                return "That key has a passphrase on it. Paste it with the passphrase taken off."
            }
        }
    }

    static let first = "-----BEGIN OPENSSH PRIVATE KEY-----"
    static let last = "-----END OPENSSH PRIVATE KEY-----"
    private static let magic = Data("openssh-key-v1\0".utf8)

    let privateKey: String
    let publicKey: String
    let fingerprint: String

    var redactedLabel: String { "PastedKey" }

    init(pasted: String) throws {
        let lines = pasted.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let opening = lines.first, opening.hasPrefix("-----BEGIN "), opening.contains("PRIVATE KEY") else {
            throw Refusal.notAKey
        }
        guard opening == Self.first else { throw Refusal.anotherFormat }
        guard lines.count > 2, lines.last == Self.last,
              let file = Data(base64Encoded: lines[1..<(lines.count - 1)].joined()),
              file.starts(with: Self.magic)
        else { throw Refusal.cutShort }

        // The names of the cipher and of the way its key is made, that
        // way's options, how many keys, the public half, the private half.
        var rest = file.dropFirst(Self.magic.count)
        guard let cipher = Self.string(from: &rest), Self.string(from: &rest) != nil,
              Self.string(from: &rest) != nil, let count = Self.number(from: &rest),
              let publicHalf = Self.string(from: &rest), let privateHalf = Self.string(from: &rest),
              count == 1, rest.isEmpty, !privateHalf.isEmpty
        else { throw Refusal.cutShort }
        guard cipher == Data("none".utf8) else { throw Refusal.locked }
        var named = publicHalf
        guard let kind = Self.string(from: &named).flatMap({ String(data: $0, encoding: .ascii) }),
              !kind.isEmpty, !named.isEmpty
        else { throw Refusal.cutShort }

        privateKey = lines.joined(separator: "\n") + "\n"
        publicKey = "\(kind) \(publicHalf.base64EncodedString())"
        let digest = Data(SHA256.hash(data: publicHalf)).base64EncodedString()
        fingerprint = "SHA256:" + digest.trimmingCharacters(in: ["="])
    }

    /// Four bytes of length, most significant first.
    private static func number(from data: inout Data) -> Int? {
        guard data.count >= 4 else { return nil }
        let length = data.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        data = data.dropFirst(4)
        return length
    }

    /// A length and that many bytes.
    private static func string(from data: inout Data) -> Data? {
        guard let length = number(from: &data), data.count >= length else { return nil }
        defer { data = data.dropFirst(length) }
        return Data(data.prefix(length))
    }
}
