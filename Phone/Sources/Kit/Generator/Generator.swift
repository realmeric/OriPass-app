import Foundation
import Security

/// A password or a passphrase made on the phone from the system's
/// randomness, by the recipe the generator's controls make. Every class of
/// character asked for is in every password, and every pick is uniform.
struct Recipe: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case password, passphrase }

    var kind = Kind.password
    var length = 20
    var uppercase = true
    var lowercase = true
    var digits = true
    var symbols = true
    /// Leaves out the characters that read as one another: l, 1, I, O, 0.
    var avoidAmbiguous = false
    var words = 5
    var separator = "-"
    var capitalize = true
    var includeNumber = true

    static let lengths = 8...64
    static let wordCounts = 3...12

    private static var defaults: UserDefaults? { UserDefaults(suiteName: Shared.appGroup) }

    static func stored() -> Recipe {
        guard let data = defaults?.data(forKey: "recipe"), var recipe = try? JSONDecoder().decode(Recipe.self, from: data)
        else { return Recipe() }
        recipe.length = min(max(recipe.length, lengths.lowerBound), lengths.upperBound)
        recipe.words = min(max(recipe.words, wordCounts.lowerBound), wordCounts.upperBound)
        return recipe
    }

    func store() {
        Recipe.defaults?.set(try? JSONEncoder().encode(self), forKey: "recipe")
    }
}

enum Generator {
    static let upper = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let lower = Array("abcdefghijklmnopqrstuvwxyz")
    static let numerals = Array("0123456789")
    static let marks = Array("!@#$%^&*-_=+?")
    static let ambiguous = Set("lI1O0")

    /// EFF's long list (Vendor/eff), read once.
    static let words: [String] = {
        guard let file = Bundle.main.url(forResource: "eff_large_wordlist", withExtension: "txt"),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { $0.split(separator: "\t").last.map(String.init) }
    }()

    static func make(_ recipe: Recipe) -> String {
        switch recipe.kind {
        case .password: password(recipe)
        case .passphrase: passphrase(recipe)
        }
    }

    static func password(_ recipe: Recipe) -> String {
        var classes: [[Character]] = []
        if recipe.uppercase { classes.append(upper) }
        if recipe.lowercase { classes.append(lower) }
        if recipe.digits { classes.append(numerals) }
        if recipe.symbols { classes.append(marks) }
        if classes.isEmpty { classes = [lower] }
        if recipe.avoidAmbiguous { classes = classes.map { $0.filter { !ambiguous.contains($0) } } }
        let length = max(recipe.length, classes.count)
        let all = classes.flatMap { $0 }
        var characters = classes.map { $0[uniform(below: $0.count)] }
        while characters.count < length { characters.append(all[uniform(below: all.count)]) }
        // Fisher and Yates, so the one of each class is anywhere.
        for index in stride(from: characters.count - 1, to: 0, by: -1) {
            characters.swapAt(index, uniform(below: index + 1))
        }
        return String(characters)
    }

    static func passphrase(_ recipe: Recipe) -> String {
        guard !words.isEmpty else { return "" }
        var picked = (0..<max(recipe.words, 1)).map { _ in words[uniform(below: words.count)] }
        if recipe.capitalize { picked = picked.map { $0.prefix(1).uppercased() + $0.dropFirst() } }
        if recipe.includeNumber {
            let place = uniform(below: picked.count)
            picked[place] += String(uniform(below: 10))
        }
        return picked.joined(separator: recipe.separator)
    }

    /// A number from 0 to `bound`, uniform: the system's random bytes, and
    /// the tail of the range that would favour the small numbers refused.
    static func uniform(below bound: Int) -> Int {
        precondition(bound > 0)
        let limit = UInt64.max - UInt64.max % UInt64(bound)
        while true {
            var value: UInt64 = 0
            let status = withUnsafeMutableBytes(of: &value) { SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }
            precondition(status == errSecSuccess, "the system has no randomness to give")
            if value < limit { return Int(value % UInt64(bound)) }
        }
    }
}
