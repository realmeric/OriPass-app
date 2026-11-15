import Foundation

/// What `bw --version` says: Bitwarden's year, month and patch, as in
/// 2026.9.1. Nothing is decided by it. `Fit` only says whether the answers
/// this app was written against are likely to be the ones it gets.
struct BwVersion: Equatable, Comparable, CustomStringConvertible {
    let year: Int
    let month: Int
    let patch: Int

    init(_ year: Int, _ month: Int, _ patch: Int = 0) {
        self.year = year
        self.month = month
        self.patch = patch
    }

    /// The first run of two or three numbers joined by dots, so that a
    /// version with a word or a newline round it is still read. Nil when
    /// there is none.
    init?(_ text: String) {
        let pieces = text.split(whereSeparator: { !$0.isNumber && $0 != "." })
            .compactMap { piece -> [Int]? in
                let numbers = piece.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
                guard (2...3).contains(numbers.count), !numbers.contains(nil) else { return nil }
                return numbers.compactMap { $0 }
            }
        guard let found = pieces.first else { return nil }
        self.init(found[0], found[1], found.count == 3 ? found[2] : 0)
    }

    static func < (left: BwVersion, right: BwVersion) -> Bool {
        (left.year, left.month, left.patch) < (right.year, right.month, right.patch)
    }

    /// 2026.9, which is what a fixture is written for: Bitwarden's patches
    /// within a month change what they fix and not what they answer.
    var release: String { "\(year).\(month)" }

    var description: String { "\(release).\(patch)" }

    /// The months the fixtures under `Tests/Fixtures/` were recorded on,
    /// both ends included.
    static let written: ClosedRange<BwVersion> = BwVersion(2026, 9)...BwVersion(2026, 9, .max)

    enum Fit: Equatable {
        case inside
        case below
        case above
        /// `bw --version` said something with no version in it.
        case unreadable
    }

    /// Where a version stands against `written`. Nil is a version that could
    /// not be read.
    static func fit(of version: BwVersion?) -> Fit {
        guard let version else { return .unreadable }
        if version < written.lowerBound { return .below }
        if version > written.upperBound { return .above }
        return .inside
    }

    /// "2026.9", or "2026.9 to 2026.11" when more than one month is written
    /// for.
    static var writtenWords: String {
        let low = written.lowerBound.release, high = written.upperBound.release
        return low == high ? low : "\(low) to \(high)"
    }
}

extension BwBinary {
    var fit: BwVersion.Fit { BwVersion.fit(of: BwVersion(version)) }

    /// What the Account room adds under the version when it is not one the
    /// app was written for. Nil when it is, and the app is never stopped by
    /// it: a changed answer is met where it is read (`ShapeError`).
    var notice: String? {
        switch fit {
        case .inside:
            return nil
        case .below, .above:
            let found = BwVersion(version)?.release ?? version
            return "Written for \(BwVersion.writtenWords), found \(found). Nothing is blocked. "
                + "After an upgrade, make contract says which answers changed."
        case .unreadable:
            return "Written for \(BwVersion.writtenWords). The version it reported could not be read. Nothing is blocked."
        }
    }
}
