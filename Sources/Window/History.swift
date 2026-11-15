/// Where a window has been, in the order it went there, as a browser keeps
/// it: going somewhere new forgets everything that going forward would have
/// returned to. It holds places and knows nothing of what a place is.
struct History<Place: Equatable> {
    /// How far back it remembers. The oldest place goes first.
    static var limit: Int { 100 }

    private(set) var here: Place
    private(set) var behind: [Place] = []
    private(set) var ahead: [Place] = []

    init(at place: Place) {
        here = place
    }

    var canGoBack: Bool { !behind.isEmpty }
    var canGoForward: Bool { !ahead.isEmpty }

    /// Somewhere new. Staying where it is is not a visit.
    mutating func visit(_ place: Place) {
        guard place != here else { return }
        behind.append(here)
        if behind.count > Self.limit { behind.removeFirst(behind.count - Self.limit) }
        ahead = []
        here = place
    }

    /// The same visit, moved: a step down a list with the arrows is not
    /// somewhere to come back to, but where it ended is.
    mutating func amend(_ place: Place) {
        here = place
    }

    mutating func goBack() -> Place? {
        guard let place = behind.popLast() else { return nil }
        ahead.append(here)
        here = place
        return place
    }

    mutating func goForward() -> Place? {
        guard let place = ahead.popLast() else { return nil }
        behind.append(here)
        here = place
        return place
    }
}
