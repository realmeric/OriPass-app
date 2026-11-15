import CryptoKit
import Foundation

/// A password as Have I Been Pwned is asked about it (`docs/notes.md`,
/// "Icons, breaches and the two-factor list"): its SHA-1 in forty capital
/// hex characters, cut after the fifth. The five go to the server and the
/// thirty-five stay here, to be looked for in what comes back. One is made
/// for the length of a question and kept by nobody.
struct BreachMark: Redacted {
    static let prefixLength = 5

    let prefix: String
    let suffix: String

    var redactedLabel: String { "BreachMark" }

    init(_ password: String) {
        var password = password
        var sha = Insecure.SHA1()
        password.withUTF8 { sha.update(bufferPointer: UnsafeRawBufferPointer($0)) }
        let hex = sha.finalize().map { String(format: "%02X", $0) }.joined()
        prefix = String(hex.prefix(Self.prefixLength))
        suffix = String(hex.dropFirst(Self.prefixLength))
    }

    /// Whether a text is five hex characters, which is all a request's path
    /// may end in.
    static func isPrefix(_ text: String) -> Bool {
        text.utf8.count == prefixLength && text.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
        }
    }
}

/// What the server answers for five characters: every suffix it has seen
/// behind them, one to a line as `SUFFIX:COUNT`. With padding asked for it
/// adds lines whose count is nought, so that the answer's length says
/// nothing of the five; those are made up and are dropped here.
struct BreachRange: Equatable {
    static let suffixLength = 35

    /// The suffixes that have been seen at least once.
    let suffixes: Set<String>

    init(_ body: Data) {
        var suffixes: Set<String> = []
        for line in String(decoding: body, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].utf8.count == Self.suffixLength,
                  let count = Int(parts[1].trimmingCharacters(in: .whitespaces)), count > 0 else { continue }
            suffixes.insert(parts[0].uppercased())
        }
        self.suffixes = suffixes
    }

    func holds(_ mark: BreachMark) -> Bool {
        suffixes.contains(mark.suffix)
    }
}
