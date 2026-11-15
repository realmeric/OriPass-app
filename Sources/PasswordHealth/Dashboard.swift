import Foundation

/// A card of Password Health's page, and so one of `Watch`'s lists. The names are
/// `docs/look.md`'s and the sentences are this app's own.
enum WatchCard: String, CaseIterable {
    /// In the order the page draws them, which is the still's. `vulnerable`
    /// is the breach check's and `twoFactor` the list of sites that take a
    /// code; each is drawn only while its switch is on (`VaultStore.cards`).
    case vulnerable, reused, weak, unsecured, twoFactor, expiring

    /// The cards this app counts by itself, which are always drawn.
    static let counted: [WatchCard] = [.reused, .weak, .unsecured, .expiring]

    var title: String {
        switch self {
        case .vulnerable: return "Vulnerable Passwords"
        case .reused: return "Reused Passwords"
        case .weak: return "Weak Passwords"
        case .unsecured: return "Unsecured Websites"
        case .twoFactor: return "Inactive two-factor authentication"
        case .expiring: return "Expiring"
        }
    }

    /// Whether the card is counted by something that has to be asked, so
    /// that it has no number until the answer is in.
    var isAnswered: Bool { self == .vulnerable || self == .twoFactor }

    /// What the count is of, and what to do about it.
    var sentence: String {
        switch self {
        case .vulnerable:
            return "These passwords have been seen in a breach, by Have I Been Pwned's count. Change each of them."
        case .reused:
            return "One password opens more than one of these logins. Give each a password of its own."
        case .weak:
            return "These passwords would not take long to guess. Make longer ones with the generator."
        case .unsecured:
            return "These logins are sent to an http address. Change it to https where the site answers there."
        case .twoFactor:
            return "These sites take a one-time code, and these logins have none. Turn it on and add its key."
        case .expiring:
            return "These cards have run out, or will within two months."
        }
    }
}

extension Watch {
    func entries(of card: WatchCard) -> [Entry] {
        switch card {
        case .vulnerable: return vulnerable ?? []
        case .reused: return reused
        case .weak: return weak
        case .unsecured: return unsecured
        case .twoFactor: return twoFactor ?? []
        case .expiring: return expiring
        }
    }

    /// A card's number, nil for one that has not been answered yet.
    func count(of card: WatchCard) -> Int? {
        switch card {
        case .vulnerable: return vulnerable?.count
        case .twoFactor: return twoFactor?.count
        default: return entries(of: card).count
        }
    }
}

/// Password Health's page as values (`docs/look.md`, "Password Health"): the strength
/// bar's segments and the cards with their counts. Made from the store's
/// `Watch` when the page is drawn, which is a count for each card and five more, and
/// holding no item.
struct Dashboard: Equatable {
    /// One level's share of the bar.
    struct Segment: Equatable, Identifiable {
        let level: Strength
        let count: Int

        var id: Int { level.rawValue }
    }

    struct Card: Equatable, Identifiable {
        let kind: WatchCard
        /// Nil until the vault has been counted, which is a moment after it
        /// opens. A card is not at nought before anyone has looked.
        let count: Int?

        var id: String { kind.rawValue }
    }

    /// The strongest first, as the still has its bar, and no level that no
    /// password is at.
    let segments: [Segment]
    let cards: [Card]

    /// How many passwords the bar is of.
    var passwords: Int { segments.reduce(0) { $0 + $1.count } }

    /// `cards` is the ones to draw, which is the store's to say
    /// (`VaultStore.cards`).
    init(_ watch: Watch?, cards: [WatchCard] = WatchCard.counted) {
        self.init(levels: watch?.levels ?? [], counts: watch.map { watch in
            Dictionary(uniqueKeysWithValues: WatchCard.allCases.compactMap { card in
                watch.count(of: card).map { (card, $0) }
            })
        }, cards: cards)
    }

    /// `levels` is weakest first, as `Watch` counts them. A card that
    /// counts by itself and is not in `counts` is at nought; the two that
    /// are asked for are still waiting for their answer.
    init(levels: [Int], counts: [WatchCard: Int]?, cards: [WatchCard] = WatchCard.counted) {
        segments = zip(Strength.allCases, levels).reversed().compactMap { level, count in
            count > 0 ? Segment(level: level, count: count) : nil
        }
        self.cards = cards.map { kind in
            Card(kind: kind, count: counts.flatMap { $0[kind] ?? (kind.isAnswered ? nil : 0) })
        }
    }

    /// What VoiceOver hears for the bar.
    var spoken: String {
        segments.isEmpty ? "no passwords" : segments.map { "\($0.count) \($0.level.word)" }.joined(separator: ", ")
    }
}
