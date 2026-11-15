import XCTest
@testable import OriPass

/// D18: a keystroke to its results inside one frame at two thousand items.
@MainActor
final class SearchBenchTests: XCTestCase {
    private func median(_ runs: Int = 100, of query: String, in index: SearchIndex) -> (ms: Double, found: Int) {
        var took: [Double] = []
        var found = 0
        for _ in 0..<runs {
            let started = DispatchTime.now().uptimeNanoseconds
            found = index.search(query).count
            took.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }
        return (took.sorted()[runs / 2], found)
    }

    func testAThreeLetterQueryOverTwoThousandItemsTakesUnderFiveMilliseconds() throws {
        let entries = try ScrollTrace.items(2000).map { Entry(try Item(json: $0)) }
        let started = Date()
        let index = SearchIndex(entries)
        let made = Date().timeIntervalSince(started) * 1000
        XCTAssertEqual(index.count, 2000)

        // The start of some titles, the inside of others, a word that is in
        // every username and every host, which is the most there is to
        // find, one that is nowhere, and two words.
        var lines: [String] = []
        for (query, expected) in [("ilg", 72), ("man", 142), ("inv", 2000), ("qqq", 0), ("ilg scr", 72)] {
            let (ms, found) = median(of: query, in: index)
            XCTAssertEqual(found, expected, query)
            XCTAssertLessThan(ms, 5, "\"\(query)\" took \(ms) ms")
            lines.append("\"\(query)\" \(String(format: "%.3f", ms)) ms for \(found)")
        }
        print("SearchBenchTests: 2000 items indexed in \(String(format: "%.1f", made)) ms; median of 100:",
              lines.joined(separator: ", "))
    }
}
