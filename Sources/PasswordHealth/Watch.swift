import CryptoKit
import Foundation

/// What Password Health counts, and asks nobody for (D13): the logins that share
/// a password with another, the ones whose password is in the bottom two
/// levels, the ones with an address that is not `https`, and the cards that
/// have run out or will within two months. Each list is in the order it was
/// handed the items in.
///
/// The store makes one behind each revision, off the main thread, from the
/// items on no shelf: nothing in the archive or the trash is counted. It
/// holds the store's own `Entry` objects and no value of theirs, and goes at
/// the lock (D6).
struct Watch: Redacted {
    /// The levels a password is called weak at.
    static let weakLevels: ClosedRange<Strength> = .guessable ... .weak
    /// How far ahead a card that has not run out yet is listed.
    static let monthsAhead = 2

    let reused: [Entry]
    let weak: [Entry]
    let unsecured: [Entry]
    let expiring: [Entry]
    /// The logins whose password Have I Been Pwned has seen in a breach
    /// (`Breaches`), which is not counted here and comes in behind the
    /// rest. Nil while nobody has been asked: the switch is off, or the
    /// first answer is not in.
    private(set) var vulnerable: [Entry]?
    /// The logins whose site takes a one-time code and which have none
    /// (`TwoFactorCheck`). Nil while the list of sites is not in: the switch
    /// is off, or it has not come yet.
    private(set) var twoFactor: [Entry]?
    /// How many logins' passwords are at each level, weakest first: what
    /// the dashboard's bar is cut from.
    let levels: [Int]
    /// For the test that holds the making of one to another thread.
    let wasMadeOnMain = Thread.isMainThread

    var redactedLabel: String {
        "Watch(\(reused.count) reused, \(weak.count) weak, \(unsecured.count) unsecured, \(expiring.count) expiring"
            + (vulnerable.map { ", \($0.count) vulnerable" } ?? "")
            + (twoFactor.map { ", \($0.count) without a code)" } ?? ")")
    }

    /// The same lists with what a breach check found beside them.
    func seen(_ vulnerable: [Entry]?) -> Watch {
        var watch = self
        watch.vulnerable = vulnerable
        return watch
    }

    /// The same lists with the logins that lack a code the site would take.
    func inactive(among entries: [Entry], by list: TwoFactorList) -> Watch {
        var watch = self
        watch.twoFactor = entries.filter { list.wants($0.item) }
        return watch
    }

    /// `listed` is each item with the level its password was given, which
    /// is read on the main thread, where the store writes it.
    init(_ listed: [(entry: Entry, strength: Strength?)], now: Date) {
        // Two passwords are the same when their marks are: an HMAC under a
        // key made here and gone when this returns, so no password is held
        // a second time to be compared, and a mark says nothing to anyone
        // who finds it.
        let salt = SymmetricKey(size: .bits256)
        var marks: [Data?] = []
        marks.reserveCapacity(listed.count)
        var holders: [Data: Int] = [:]
        for (entry, _) in listed {
            guard var password = entry.item.login?.password, !password.isEmpty else {
                marks.append(nil)
                continue
            }
            var hmac = HMAC<SHA256>(key: salt)
            password.withUTF8 { hmac.update(data: UnsafeRawBufferPointer($0)) }
            let mark = Data(hmac.finalize())
            marks.append(mark)
            holders[mark, default: 0] += 1
        }
        reused = zip(listed, marks).compactMap { one, mark in
            mark.flatMap { holders[$0] }.map { $0 > 1 } == true ? one.entry : nil
        }
        weak = listed.compactMap { entry, strength in
            guard entry.item.login != nil, let strength else { return nil }
            return Self.weakLevels.contains(strength) ? entry : nil
        }
        unsecured = listed.map(\.entry).filter { entry in
            entry.item.login?.uris.contains { Self.isUnsecured($0.uri) } == true
        }
        var levels = Array(repeating: 0, count: Strength.allCases.count)
        for (entry, strength) in listed where entry.item.login != nil {
            if let strength { levels[strength.rawValue] += 1 }
        }
        self.levels = levels
        let horizon = Self.calendar.date(byAdding: .month, value: Self.monthsAhead, to: now) ?? now
        expiring = listed.map(\.entry).filter { entry in
            guard case .card(let card) = entry.item.payload,
                  let lapse = Self.lapse(month: card.expMonth, year: card.expYear) else { return false }
            return lapse <= horizon
        }
    }

    /// Whether an address is asked for in the clear. One with no scheme is
    /// not: a browser tries `https` first.
    static func isUnsecured(_ address: String) -> Bool {
        address.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://")
    }

    private static let calendar = Calendar(identifier: .gregorian)

    /// The first moment a card is no longer good: the start of the month
    /// after the one on it, on this Mac's clock. A year of two digits is
    /// this century's, and a card with a year and no month is good to the
    /// end of that year. One with no year says nothing.
    static func lapse(month: String?, year: String?) -> Date? {
        guard var year = year.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), year >= 0 else { return nil }
        if year < 100 { year += 2000 }
        let read = month.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let month = read.flatMap { (1...12).contains($0) ? $0 : nil } ?? 12
        return calendar.date(from: DateComponents(year: year, month: month + 1, day: 1))
    }
}
