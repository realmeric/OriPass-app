import Foundation

/// How many tries a password would take someone who knows how people choose
/// them. The method is zxcvbn's, written here from its description and not
/// from its code: find every stretch of the password that is something a
/// guesser tries early (a word, a run along the keyboard, a repeat, a
/// sequence, a date), give each stretch the number of tries that kind of
/// thing takes, and take the cheapest way of covering the whole password
/// with such stretches and with plain trying of everything for what is left
/// between them.
///
/// What it has less of than zxcvbn is words (`Words`), and that only ever
/// errs one way: a word this does not know is counted as letters nobody
/// could guess, so the level can come out too high and never too low.
///
/// Nothing is kept. The password is read where it is, the copies made on the
/// way (its characters, lowered, and the stretches looked up) are locals of
/// one call, and what comes back is a number.
struct Guesswork {
    /// The year dates are counted from.
    let year: Int

    /// As much of a password as is read. A longer one is at least as strong
    /// as its first sixty-four characters, and the work grows with the
    /// square of the length.
    static let longestRead = 64

    private struct Match {
        let first: Int
        let last: Int
        var guesses: Double
        var isBrute = false

        var length: Int { last - first + 1 }
    }

    func guesses(for password: String) -> Double {
        let written = Array(password.prefix(Self.longestRead))
        guard !written.isEmpty else { return 1 }
        let lower = written.map(Self.lowered)
        let found = words(written, lower) + runs(written) + sequences(lower) + repeats(lower) + dates(lower)
        return fewest(found.map(floored(in: written.count)), count: written.count)
    }

    /// One character for one character, so the places in the lowered
    /// password are the places in the written one. A capital İ lowers to an
    /// i and a dot that joins it, and is read as the i.
    private static func lowered(_ character: Character) -> Character {
        let lowered = String(character).lowercased()
        if character.unicodeScalars.count == 1, let first = lowered.unicodeScalars.first { return Character(first) }
        return lowered.first ?? character
    }

    /// A stretch that is not the whole password is never cheaper than ten
    /// tries for one character and fifty for more, or a password cut into
    /// many small known pieces would look cheaper than it is.
    private func floored(in count: Int) -> (Match) -> Match {
        { match in
            var match = match
            let least: Double = match.length == count ? 1 : (match.length == 1 ? 10 : 50)
            match.guesses = max(match.guesses, least)
            return match
        }
    }

    // MARK: Words

    /// What people write in a letter's place, read back as the letter. A one
    /// stands for an i as often as for an l, so there are two readings.
    private static let disguises: [[Character: Character]] = {
        let common: [Character: Character] = ["@": "a", "4": "a", "3": "e", "0": "o", "$": "s", "5": "s",
                                              "7": "t", "!": "i"]
        return [common.merging(["1": "i"]) { $1 }, common.merging(["1": "l"]) { $1 }]
    }()

    private func words(_ written: [Character], _ lower: [Character]) -> [Match] {
        let count = lower.count
        var found: [Match] = []

        for hit in Self.known(in: lower) {
            found.append(Match(first: hit.first, last: hit.last,
                               guesses: Double(hit.rank) * Self.capitals(written[hit.first...hit.last])))
        }
        for disguise in Self.disguises {
            let plain = lower.map { disguise[$0] ?? $0 }
            guard plain != lower else { continue }
            for hit in Self.known(in: plain) where plain[hit.first...hit.last] != lower[hit.first...hit.last] {
                found.append(Match(first: hit.first, last: hit.last,
                                   guesses: Double(hit.rank) * Self.capitals(written[hit.first...hit.last]) * 2))
            }
        }
        let backwards = Array(lower.reversed())
        for hit in Self.known(in: backwards) {
            let first = count - 1 - hit.last, last = count - 1 - hit.first
            // A word that reads the same both ways was found the first time.
            guard lower[first...last] != backwards[hit.first...hit.last] else { continue }
            found.append(Match(first: first, last: last,
                               guesses: Double(hit.rank) * Self.capitals(written[first...last]) * 2))
        }
        return found
    }

    /// Every stretch of three letters or more that is a word of the lists.
    private static func known(in letters: [Character]) -> [(first: Int, last: Int, rank: Int)] {
        var hits: [(first: Int, last: Int, rank: Int)] = []
        for first in letters.indices {
            var word = ""
            for last in first..<min(letters.count, first + Words.longest) {
                word.append(letters[last])
                if last - first >= 2, let rank = Words.ranks[word] { hits.append((first, last, rank)) }
            }
        }
        return hits
    }

    /// How many ways the capitals could have been placed. None, the first
    /// letter, the last or all of them are the ways people do it, and count
    /// as one more try; anything else is counted out.
    private static func capitals(_ letters: ArraySlice<Character>) -> Double {
        let upper = letters.filter(\.isUppercase).count
        let lower = letters.filter(\.isLowercase).count
        guard upper > 0 else { return 1 }
        let atAnEnd = letters.first?.isUppercase == true || letters.last?.isUppercase == true
        if lower == 0 || (upper == 1 && atAnEnd) { return 2 }
        return (1...min(upper, lower)).reduce(0) { $0 + choose(upper + lower, $1) }
    }

    // MARK: Runs along the keyboard

    /// A layout as rows of keys, each row standing half a key to the right
    /// of the one above it, which is what makes `qaz` and `1qaz` runs.
    private struct Keyboard {
        private var places: [Character: (row: Int, column: Int)] = [:]
        private(set) var shifted: Set<Character> = []

        init(plain: [String], shifted: [String]) {
            for (rows, isShifted) in [(plain, false), (shifted, true)] {
                for (row, keys) in rows.enumerated() {
                    for (column, key) in keys.enumerated() {
                        places[key] = (row, column + (row == 0 ? 0 : 1))
                        if isShifted { self.shifted.insert(key) }
                    }
                }
            }
        }

        /// The way from one key to the next, when they touch.
        func step(from one: Character, to other: Character) -> (rows: Int, columns: Int)? {
            guard let here = places[one], let there = places[other] else { return nil }
            let step = (rows: there.row - here.row, columns: there.column - here.column)
            switch step {
            case (0, 1), (0, -1), (-1, 0), (-1, 1), (1, -1), (1, 0): return step
            default: return nil
            }
        }
    }

    /// The American layout, and the Turkish Q this Mac's owner types on.
    private static let keyboards = [
        Keyboard(plain: ["`1234567890-=", "qwertyuiop[]\\", "asdfghjkl;'", "zxcvbnm,./"],
                 shifted: ["~!@#$%^&*()_+", "QWERTYUIOP{}|", "ASDFGHJKL:\"", "ZXCVBNM<>?"]),
        Keyboard(plain: ["\"1234567890*-", "qwertyuıopğü", "asdfghjklşi,", "zxcvbnmöç."],
                 shifted: ["é!'^+%&/()=?_", "QWERTYUIOPĞÜ", "ASDFGHJKLŞİ;", "ZXCVBNMÖÇ:"]),
    ]

    /// How many keys a run can start on, and how many neighbours a key has
    /// on average: zxcvbn's figures for the American layout.
    private static let keys: Double = 47
    private static let neighbours: Double = 4.6

    private func runs(_ written: [Character]) -> [Match] {
        var found: [Match] = []
        for keyboard in Self.keyboards {
            var first = 0
            while first < written.count - 2 {
                var last = first
                var turns = 0
                var heading: (rows: Int, columns: Int)?
                var shifts = keyboard.shifted.contains(written[first]) ? 1 : 0
                while last + 1 < written.count,
                      let step = keyboard.step(from: written[last], to: written[last + 1]) {
                    if heading.map({ $0 != step }) ?? true {
                        turns += 1
                        heading = step
                    }
                    last += 1
                    if keyboard.shifted.contains(written[last]) { shifts += 1 }
                }
                if last - first >= 2 {
                    found.append(Match(first: first, last: last,
                                       guesses: Self.run(length: last - first + 1, turns: turns, shifts: shifts)))
                }
                first = last + 1
            }
        }
        return found
    }

    /// Every run of that length or shorter with that many turns or fewer,
    /// from any key, and then every way of holding shift for some of it.
    private static func run(length: Int, turns: Int, shifts: Int) -> Double {
        var guesses = 0.0
        for reach in 2...length {
            for bends in 1...min(turns, reach - 1) {
                guesses += choose(reach - 1, bends - 1) * keys * pow(neighbours, Double(bends))
            }
        }
        guard shifts > 0 else { return guesses }
        let plain = length - shifts
        return guesses * (plain == 0 ? 2 : (1...min(shifts, plain)).reduce(0) { $0 + choose(length, $1) })
    }

    // MARK: Sequences

    /// `abc`, `9876`, `2468`: each character the same few steps from the one
    /// before it.
    private func sequences(_ lower: [Character]) -> [Match] {
        let codes = lower.map { $0.unicodeScalars.count == 1 ? $0.unicodeScalars.first.map { Int($0.value) } : nil }
        var found: [Match] = []
        var first = 0
        while first < lower.count - 2 {
            guard let one = codes[first], let two = codes[first + 1], two != one, abs(two - one) <= 5 else {
                first += 1
                continue
            }
            var last = first + 1
            while last + 1 < lower.count, let here = codes[last], let next = codes[last + 1],
                  next - here == two - one {
                last += 1
            }
            if last - first >= 2 {
                // The places people start from are tried first, then the
                // digits, then everything else.
                let lead = lower[first]
                var start: Double = "az019".contains(lead) ? 4 : (lead.isNumber ? 10 : 26)
                if two < one { start *= 2 }
                found.append(Match(first: first, last: last, guesses: start * Double(last - first + 1)))
            }
            // The next one may begin on this one's last character.
            first = last
        }
        return found
    }

    // MARK: Repeats

    /// `aaa`, `abcabc`: one piece written twice or more. It costs what the
    /// piece costs, once for each time it might have been written.
    private func repeats(_ lower: [Character]) -> [Match] {
        var found: [Match] = []
        var first = 0
        while first < lower.count - 1 {
            var best: (piece: Int, times: Int)?
            for piece in 1...(lower.count - first) / 2 {
                var times = 1
                while first + (times + 1) * piece <= lower.count,
                      lower[(first + times * piece)..<(first + (times + 1) * piece)] == lower[first..<(first + piece)] {
                    times += 1
                }
                if times > 1, piece * times > best.map({ $0.piece * $0.times }) ?? 0 { best = (piece, times) }
            }
            guard let best else {
                first += 1
                continue
            }
            let piece = guesses(for: String(lower[first..<(first + best.piece)]))
            found.append(Match(first: first, last: first + best.piece * best.times - 1,
                               guesses: piece * Double(best.times)))
            first += best.piece * best.times
        }
        return found
    }

    // MARK: Dates

    private static let years = 1900...2050
    private static let separators: Set<Character> = [" ", "/", "\\", "_", ".", "-"]

    /// A year by itself, and a day, a month and a year in any of the three
    /// orders people write them in, run together or with something between.
    private func dates(_ lower: [Character]) -> [Match] {
        let digits = lower.map { $0.isASCII ? $0.wholeNumberValue : nil }
        let count = lower.count
        var found: [Match] = []

        func number(_ first: Int, _ length: Int) -> Int? {
            guard length > 0, first + length <= count else { return nil }
            var number = 0
            for place in first..<(first + length) {
                guard let digit = digits[place] else { return nil }
                number = number * 10 + digit
            }
            return number
        }

        func far(_ year: Int) -> Double { Double(max(abs(year - self.year), 20)) }

        func whole(_ year: Int, wide: Bool) -> Int { wide ? year : (year > 50 ? 1900 + year : 2000 + year) }

        /// The nearest year among the ways the three numbers can be read.
        func nearest(_ readings: [(day: Int?, month: Int?, year: Int?)]) -> Double? {
            readings.compactMap { reading -> Double? in
                guard let day = reading.day, let month = reading.month, let year = reading.year,
                      (1...31).contains(day), (1...12).contains(month), Self.years.contains(year)
                else { return nil }
                return far(year)
            }.min()
        }

        for first in 0..<count {
            if let year = number(first, 4), Self.years.contains(year) {
                found.append(Match(first: first, last: first + 3, guesses: far(year)))
            }
            for (length, wide) in [(6, false), (8, true)] where number(first, length) != nil {
                let long = wide ? 4 : 2
                let year = { (place: Int) in number(place, long).map { whole($0, wide: wide) } }
                let readings = [
                    (number(first, 2), number(first + 2, 2), year(first + 4)),
                    (number(first + 2, 2), number(first, 2), year(first + 4)),
                    (number(first + long + 2, 2), number(first + long, 2), year(first)),
                ]
                if let years = nearest(readings) {
                    found.append(Match(first: first, last: first + length - 1, guesses: 365 * years))
                }
            }
            // 1 to 4 digits, something, 1 or 2, the same thing, 1 to 4.
            for one in 1...4 where number(first, one) != nil && first + one < count
                && Self.separators.contains(lower[first + one]) {
                for two in 1...2 where number(first + one + 1, two) != nil && first + one + two + 1 < count
                    && lower[first + one + two + 1] == lower[first + one] {
                    for three in [1, 2, 4] where number(first + one + two + 2, three) != nil {
                        let (a, b, c) = (number(first, one), number(first + one + 1, two),
                                         number(first + one + two + 2, three))
                        var readings: [(day: Int?, month: Int?, year: Int?)] = []
                        if one <= 2, three != 1 {
                            let year = c.map { whole($0, wide: three == 4) }
                            readings += [(a, b, year), (b, a, year)]
                        }
                        if one != 1, one != 3, three <= 2 {
                            readings.append((c, b, a.map { whole($0, wide: one == 4) }))
                        }
                        if let years = nearest(readings) {
                            // Four ways of writing what stands between.
                            found.append(Match(first: first, last: first + one + two + three + 1,
                                               guesses: 365 * years * 4))
                        }
                    }
                }
            }
        }
        return found
    }

    // MARK: The cheapest way through

    /// What a stretch costs when nothing is known about it: ten to the
    /// power of its length, zxcvbn's figure, which is low for a character
    /// drawn from the whole keyboard and is what keeps the estimate from
    /// flattering.
    private static func brute(_ first: Int, _ last: Int) -> Match {
        let length = last - first + 1
        return Match(first: first, last: last, guesses: length == 1 ? 11 : pow(10, Double(length)),
                     isBrute: true)
    }

    /// The fewest guesses over every way of covering the password with the
    /// stretches found and with plain trying between them. A way made of
    /// more pieces pays for it twice: the pieces could have come in any
    /// order, and a guesser tries the shorter recipes first.
    private func fewest(_ found: [Match], count: Int) -> Double {
        var ending = [[Match]](repeating: [], count: count)
        for match in found { ending[match.last].append(match) }
        // For each place a way can end at and each number of pieces it can
        // have: the pieces' guesses multiplied, and what the way costs.
        var best = [[Int: (product: Double, guesses: Double, isBrute: Bool)]](repeating: [:], count: count)

        func consider(_ match: Match, pieces: Int) {
            var product = match.guesses
            if pieces > 1 {
                guard let before = best[match.first - 1][pieces - 1] else { return }
                product *= before.product
            }
            let guesses = Self.factorial(pieces) * product + pow(10_000, Double(pieces - 1))
            for (fewer, other) in best[match.last] where fewer <= pieces && other.guesses <= guesses { return }
            best[match.last][pieces] = (product, guesses, match.isBrute)
        }

        for last in 0..<count {
            for match in ending[last] {
                if match.first == 0 {
                    consider(match, pieces: 1)
                } else {
                    for pieces in Array(best[match.first - 1].keys) { consider(match, pieces: pieces + 1) }
                }
            }
            consider(Self.brute(0, last), pieces: 1)
            for first in stride(from: 1, through: last, by: 1) {
                // Two stretches of plain trying side by side are never
                // cheaper than one.
                for (pieces, before) in best[first - 1] where !before.isBrute {
                    consider(Self.brute(first, last), pieces: pieces + 1)
                }
            }
        }
        return best[count - 1].values.map(\.guesses).min() ?? 1
    }

    private static func factorial(_ n: Int) -> Double {
        n < 2 ? 1 : (2...n).reduce(1.0) { $0 * Double($1) }
    }

    private static func choose(_ n: Int, _ k: Int) -> Double {
        guard k >= 0, k <= n else { return 0 }
        return (0..<min(k, n - k)).reduce(1.0) { $0 * Double(n - $1) / Double($1 + 1) }
    }
}
