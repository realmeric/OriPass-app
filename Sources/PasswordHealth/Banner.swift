import Foundation

extension WatchCard {
    /// The cards from the one that matters most to the one that matters
    /// least, which is the order an item on two lists is told in. A password
    /// that has been seen is already on the lists a guesser starts from, one
    /// sent in the clear can be read by whoever is on the wire, one used
    /// twice opens a second door once it leaks, a weak one has to be
    /// guessed, a login with no second factor is only as safe as its
    /// password, and a card that has run out only has to be replaced. This
    /// is the one place the order is written.
    static let seriousFirst: [WatchCard] = [.vulnerable, .unsecured, .reused, .weak, .twoFactor, .expiring]
}

/// What the top of an item's details says when the item is on one of
/// Password Health's lists: one line, and a button where there is something to
/// do about it. Made from the lists and the item each time the details are
/// drawn, and holding neither.
struct Banner: Equatable, Identifiable {
    /// What the button does.
    enum Act: Equatable {
        /// Opens the form.
        case edit
        /// Opens the form with every address in the clear already given
        /// its `https` form, to be saved or not.
        case secure

        var name: String {
            switch self {
            case .edit: return "Edit"
            case .secure: return "Use https"
            }
        }
    }

    let card: WatchCard
    let sentence: String
    let act: Act?

    var id: String { card.rawValue }

    /// The same line with no button, for an item that cannot be changed.
    var withoutAct: Banner { Banner(card: card, sentence: sentence, act: nil) }

    static let vulnerable = "This password has been seen in a breach."
    static let reused = "This password is used for more than one login."
    static let weak = "This password would not take long to guess."
    static let unsecured = "This address is sent in the clear."
    static let twoFactor = "This site takes a one-time code, and this login has none."
    static let expired = "This card has run out."
    static let expiring = "This card runs out within two months."

    init(card: WatchCard, sentence: String, act: Act?) {
        self.card = card
        self.sentence = sentence
        self.act = act
    }

    /// `now` tells a card that has run out from one that will.
    init(_ card: WatchCard, for item: Item, now: Date) {
        self.card = card
        switch card {
        case .vulnerable:
            (sentence, act) = (Self.vulnerable, .edit)
        case .reused:
            (sentence, act) = (Self.reused, .edit)
        case .weak:
            (sentence, act) = (Self.weak, .edit)
        case .unsecured:
            (sentence, act) = (Self.unsecured, .secure)
        case .twoFactor:
            (sentence, act) = (Self.twoFactor, .edit)
        case .expiring:
            var lapsed = false
            if case .card(let payload) = item.payload,
               let lapse = Watch.lapse(month: payload.expMonth, year: payload.expYear) {
                lapsed = lapse <= now
            }
            (sentence, act) = (lapsed ? Self.expired : Self.expiring, nil)
        }
    }
}

extension Watch {
    /// The banners for one item, the most serious first, from the cards
    /// that are being drawn.
    func banners(for entry: Entry, among cards: [WatchCard] = WatchCard.counted, now: Date) -> [Banner] {
        WatchCard.seriousFirst
            .filter { card in cards.contains(card) && entries(of: card).contains { $0.id == entry.id } }
            .map { Banner($0, for: entry.item, now: now) }
    }

    /// An address with `http://` in front of it, in the form a browser would
    /// have gone to first. The same text if it was not in the clear.
    static func secured(_ address: String) -> String {
        guard isUnsecured(address) else { return address }
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        return "https://" + trimmed.dropFirst("http://".count)
    }
}

extension Panes {
    /// A banner's button.
    func perform(banner act: Banner.Act) {
        beginEdit(securing: act == .secure)
    }
}
