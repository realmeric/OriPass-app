import Foundation

/// A value cut into the cells Large Type draws (`docs/look.md`, "Large
/// Type"): each character with its place, counted from one, and whether it
/// is a letter, a digit or a symbol, which is what it is coloured by.
struct LargeType: Redacted, Equatable {
    enum Kind: Equatable {
        case letter, digit, symbol
        /// A space or a line's end, drawn as an empty cell that still counts.
        case blank

        init(_ character: Character) {
            if character.isWhitespace {
                self = .blank
            } else if character.isNumber {
                self = .digit
            } else if character.isLetter {
                self = .letter
            } else {
                self = .symbol
            }
        }
    }

    struct Cell: Identifiable, Equatable {
        /// The character's place in the value, the first being 1.
        let id: Int
        let character: Character
        let kind: Kind
    }

    /// The row it was asked for from.
    let row: String
    let cells: [Cell]

    var redactedLabel: String { "LargeType(\(row))" }

    init(_ value: String, row: String = "") {
        self.row = row
        cells = value.enumerated().map { Cell(id: $0 + 1, character: $1, kind: Kind($1)) }
    }

    /// The cells in lines of `count`, the last one as short as it comes.
    func lines(of count: Int) -> [[Cell]] {
        let count = max(count, 1)
        return stride(from: 0, to: cells.count, by: count).map { Array(cells[$0..<min($0 + count, cells.count)]) }
    }

    /// How many cells a line holds in a panel no wider than `width`, and the
    /// size that panel then is, no taller than `height`.
    func fit(width: CGFloat, height: CGFloat) -> (perLine: Int, size: CGSize) {
        let cell = Metrics.largeTypeCell
        let pad = Metrics.largeTypePad * 2
        let perLine = min(max(Int((width - pad) / cell.width), 1), max(cells.count, 1))
        let lines = CGFloat(self.lines(of: perLine).count)
        return (perLine, CGSize(width: CGFloat(perLine) * cell.width + pad,
                                height: min(lines * cell.height + pad, height)))
    }
}
