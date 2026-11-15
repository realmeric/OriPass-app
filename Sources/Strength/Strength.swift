import Foundation

/// How strong a password is, in five levels, weakest first. The words are
/// this app's and are written here and nowhere else.
///
/// The level is an estimate of how many tries a guesser who knows how people
/// choose passwords would need (`Guesswork`), cut at the four counts zxcvbn
/// cuts at: a thousand, a million, a hundred million and ten thousand
/// million. It is not zxcvbn, and will sometimes sit a level away from what
/// Bitwarden's own apps say about the same password (`docs/notes.md`, "How
/// strong").
enum Strength: Int, CaseIterable, Comparable {
    case guessable, weak, fair, good, strong

    var word: String {
        switch self {
        case .guessable: return "Guessable"
        case .weak: return "Weak"
        case .fair: return "Fair"
        case .good: return "Good"
        case .strong: return "Strong"
        }
    }

    /// How much of its ring a level fills: a fifth for each.
    var share: Double { Double(rawValue + 1) / Double(Self.allCases.count) }

    static func < (one: Strength, other: Strength) -> Bool { one.rawValue < other.rawValue }

    /// The fewest guesses each level above the first starts at.
    private static let floors: [Double] = [1e3, 1e6, 1e8, 1e10]

    init(guesses: Double) {
        self = Self(rawValue: Self.floors.filter { guesses >= $0 }.count) ?? .strong
    }

    /// The year dates are counted from. A year near it is a likelier guess
    /// than one far away.
    static var thisYear: Int { Calendar(identifier: .gregorian).component(.year, from: Date()) }

    /// The same level for the same password, whenever it is asked, within
    /// one `year`.
    static func of(_ password: String, year: Int = thisYear) -> Strength {
        Strength(guesses: Guesswork(year: year).guesses(for: password))
    }
}
