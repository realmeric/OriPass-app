import Foundation

/// A page's password rules, in the `passwordrules` form Apple and the
/// WHATWG proposal write ("minlength: 20; required: lower; required: upper;
/// required: digit; allowed: [-_]"), read for what a generated password
/// has to be. Anything the reader does not know is left out.
struct PasswordRules: Equatable, Sendable {
    var minLength: Int?
    var maxLength: Int?
    /// Each set of characters at least one of which must be in the password.
    var required: [Set<Character>] = []
    /// What else may be in it; nil is any of the generator's characters.
    var allowed: Set<Character>?

    static let lower = Set("abcdefghijklmnopqrstuvwxyz")
    static let upper = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let digit = Set("0123456789")
    static let special = Set("-~!@#$%^&*_+=`|(){}[:;\"'<>,.?]/ ")

    init(_ written: String?) {
        guard let written else { return }
        for rule in written.split(separator: ";") {
            let parts = rule.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let (name, value) = (parts[0].lowercased(), parts[1])
            switch name {
            case "minlength": minLength = Int(value)
            case "maxlength": maxLength = Int(value)
            case "required": required.append(PasswordRules.characters(in: value))
            case "allowed": allowed = (allowed ?? []).union(PasswordRules.characters(in: value))
            default: continue
            }
        }
    }

    /// The characters a class list names: lower, upper, digit, special,
    /// ascii-printable, unicode, and characters in brackets.
    static func characters(in value: String) -> Set<Character> {
        var set = Set<Character>()
        for item in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch item.lowercased() {
            case "lower": set.formUnion(lower)
            case "upper": set.formUnion(upper)
            case "digit": set.formUnion(digit)
            case "special": set.formUnion(special)
            case "ascii-printable", "unicode": set.formUnion(lower.union(upper).union(digit).union(special))
            default:
                if item.hasPrefix("["), item.hasSuffix("]") { set.formUnion(item.dropFirst().dropLast()) }
            }
        }
        return set
    }

    /// A password the rules take: twenty characters where they allow it,
    /// one from each required set, the rest from everything they allow.
    func password(length wanted: Int = 20) -> String {
        let floor = max(minLength ?? 0, required.count)
        let length = min(max(wanted, floor), maxLength ?? .max)
        let everything = allowed.map { $0.union(required.reduce(into: Set()) { $0.formUnion($1) }) }
            ?? PasswordRules.lower.union(PasswordRules.upper).union(PasswordRules.digit).union(Set(Generator.marks))
        let pool = Array(everything.subtracting(Generator.ambiguous)).sorted()
        var characters = required.compactMap { set -> Character? in
            let choices = Array(set).sorted()
            return choices.isEmpty ? nil : choices[Generator.uniform(below: choices.count)]
        }
        while characters.count < length { characters.append(pool[Generator.uniform(below: pool.count)]) }
        for index in stride(from: characters.count - 1, to: 0, by: -1) {
            characters.swapAt(index, Generator.uniform(below: index + 1))
        }
        return String(characters.prefix(length))
    }
}
