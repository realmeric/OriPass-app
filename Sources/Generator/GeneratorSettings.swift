import Foundation

/// What the generator's controls stand at (`docs/look.md`, "The
/// generator"). All of it is written to the defaults when one of them
/// moves, and none of it is a secret: a kind, four numbers and four
/// switches. No password is ever part of it.
struct GeneratorSettings: Equatable {
    enum Kind: String, CaseIterable {
        case random, memorable, pin

        var name: String {
            switch self {
            case .random: return "Random"
            case .memorable: return "Memorable"
            case .pin: return "PIN"
            }
        }
    }

    /// What stands between the words of a memorable password.
    enum Separator: String, CaseIterable {
        case hyphens, spaces, periods, commas, underscores

        var name: String { rawValue.capitalized }

        var character: String {
            switch self {
            case .hyphens: return "-"
            case .spaces: return " "
            case .periods: return "."
            case .commas: return ","
            case .underscores: return "_"
            }
        }
    }

    /// How far each slider runs. A PIN may be shorter than the engine's
    /// shortest password (`ServeBackend.generate`).
    static let lengths = 8...100
    static let wordCounts = 3...10
    static let pinLengths = 4...12
    static let key = "generator"

    var kind = Kind.random
    var length = 20
    var digits = true
    var symbols = true
    var words = 4
    var separator = Separator.hyphens
    var capitals = false
    var number = false
    var pinDigits = 6

    /// What the engine is asked for with the controls as they stand.
    var recipe: PasswordRecipe {
        switch kind {
        case .random: return .random(length: length, digits: digits, symbols: symbols)
        case .memorable:
            return .memorable(words: words, separator: separator.character, capitals: capitals, number: number)
        case .pin: return .pin(digits: pinDigits)
        }
    }

    /// What a page's field is given: the controls as they stand, but a PIN is
    /// no password for a site, and a memorable one cannot be held to a field
    /// that takes only so many characters, so those two are the first random
    /// one. Never longer than the field and never shorter than the engine
    /// makes (`ServeBackend.shortest`).
    func recipe(forAFieldOf most: Int?) -> PasswordRecipe {
        if kind == .memorable, most == nil { return recipe }
        let random = kind == .random ? self : GeneratorSettings()
        let length = min(random.length, max(most ?? random.length, ServeBackend.shortest))
        return .random(length: length, digits: random.digits, symbols: random.symbols)
    }

    init() {}

    /// As they were left. A number that is out of its slider's reach, as
    /// one written by another version might be, is brought to the nearer
    /// end. Without defaults, which is every test's, nothing is read.
    init(_ defaults: UserDefaults?) {
        guard let kept = defaults?.dictionary(forKey: Self.key) else { return }
        kind = (kept["kind"] as? String).flatMap(Kind.init) ?? kind
        length = Self.within(Self.lengths, kept["length"]) ?? length
        digits = kept["digits"] as? Bool ?? digits
        symbols = kept["symbols"] as? Bool ?? symbols
        words = Self.within(Self.wordCounts, kept["words"]) ?? words
        separator = (kept["separator"] as? String).flatMap(Separator.init) ?? separator
        capitals = kept["capitals"] as? Bool ?? capitals
        number = kept["number"] as? Bool ?? number
        pinDigits = Self.within(Self.pinLengths, kept["pinDigits"]) ?? pinDigits
    }

    private static func within(_ range: ClosedRange<Int>, _ kept: Any?) -> Int? {
        (kept as? Int).map { min(max($0, range.lowerBound), range.upperBound) }
    }

    func write(to defaults: UserDefaults) {
        defaults.set([
            "kind": kind.rawValue, "length": length, "digits": digits, "symbols": symbols,
            "words": words, "separator": separator.rawValue, "capitals": capitals, "number": number,
            "pinDigits": pinDigits,
        ] as [String: Any], forKey: Self.key)
    }
}
