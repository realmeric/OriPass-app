import Foundation

/// The store's side of `Strength`, apart from the levels themselves so that
/// the iPhone app can share `Strength.swift` without the Mac's `Entry`.
extension Strength {
    /// The levels of many, in the order they were given, and nil for an item
    /// with no password. Each password is read where its item holds it; what
    /// comes back is the levels and nothing else. A task that is cancelled
    /// on the way gets nil, whatever had been worked out.
    static func levels(of entries: [Entry]) -> [Strength?]? {
        let guesswork = Guesswork(year: thisYear)
        var levels: [Strength?] = []
        levels.reserveCapacity(entries.count)
        for entry in entries {
            if Task.isCancelled { return nil }
            let password = entry.item.login?.password ?? ""
            levels.append(password.isEmpty ? nil : Strength(guesses: guesswork.guesses(for: password)))
        }
        return levels
    }
}
