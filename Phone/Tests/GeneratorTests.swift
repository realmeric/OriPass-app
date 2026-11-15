import XCTest
@testable import OriPass

final class GeneratorTests: XCTestCase {
    func testEveryClassAskedForIsInEveryPasswordAtItsLength() {
        for _ in 0..<2_000 {
            var recipe = Recipe()
            recipe.length = Int.random(in: Recipe.lengths)
            recipe.uppercase = Bool.random()
            recipe.lowercase = Bool.random()
            recipe.digits = Bool.random()
            recipe.symbols = Bool.random()
            recipe.avoidAmbiguous = Bool.random()
            let password = Generator.password(recipe)
            XCTAssertEqual(password.count, recipe.length)
            if recipe.uppercase { XCTAssertTrue(password.contains { Generator.upper.contains($0) }) }
            if recipe.digits { XCTAssertTrue(password.contains { Generator.numerals.contains($0) }) }
            if recipe.symbols { XCTAssertTrue(password.contains { Generator.marks.contains($0) }) }
            if !recipe.uppercase { XCTAssertFalse(password.contains { Generator.upper.contains($0) && recipe.lowercase }) }
            if recipe.avoidAmbiguous { XCTAssertFalse(password.contains { Generator.ambiguous.contains($0) }) }
        }
    }

    func testAPassphraseDrawsOnlyListedWords() {
        XCTAssertEqual(Generator.words.count, 7_776)
        let listed = Set(Generator.words)
        for _ in 0..<500 {
            var recipe = Recipe()
            recipe.kind = .passphrase
            recipe.words = Int.random(in: Recipe.wordCounts)
            recipe.capitalize = false
            recipe.includeNumber = false
            recipe.separator = " "
            let words = Generator.passphrase(recipe).split(separator: " ").map(String.init)
            XCTAssertEqual(words.count, recipe.words)
            XCTAssertTrue(words.allSatisfy(listed.contains))
        }
        var numbered = Recipe()
        numbered.kind = .passphrase
        XCTAssertEqual(Generator.passphrase(numbered).filter(\.isNumber).count, 1)
    }

    func testAUniformPickStaysInItsRange() {
        var seen = Set<Int>()
        for _ in 0..<1_000 { seen.insert(Generator.uniform(below: 7)) }
        XCTAssertEqual(seen, Set(0..<7))
    }

    func testTheMacsStrengthReadsTheResult() {
        XCTAssertEqual(Strength.of(Generator.password(Recipe())), .strong)
        XCTAssertLessThan(Strength.of("password1"), .fair)
    }
}
