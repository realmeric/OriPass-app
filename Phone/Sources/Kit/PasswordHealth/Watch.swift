import Foundation

/// Password Health's three counts, worked out from the open vault and asking
/// nobody: logins that share a password, logins whose password is in the
/// bottom two of the Mac's five levels, and logins with an http:// address.
/// The trash and the archive are on no list.
struct Watch: Equatable, Sendable {
    var reused: [String] = []
    var weak: [String] = []
    var unsecured: [String] = []

    var isEmpty: Bool { reused.isEmpty && weak.isEmpty && unsecured.isEmpty }

    static func count(_ items: [Item], year: Int = Strength.thisYear) -> Watch {
        let logins = items.filter { $0.kind == .login && !$0.deleted && !$0.archived }
        var watch = Watch()
        var byPassword: [String: [String]] = [:]
        let guesswork = Guesswork(year: year)
        for item in logins {
            guard let password = item.login?.password, !password.isEmpty else { continue }
            byPassword[password, default: []].append(item.id)
            if Strength(guesses: guesswork.guesses(for: password)) <= .weak { watch.weak.append(item.id) }
        }
        watch.reused = byPassword.values.filter { $0.count > 1 }.flatMap { $0 }
        watch.unsecured = logins.filter { item in
            item.login?.uris.contains { $0.uri.lowercased().hasPrefix("http://") } == true
        }.map(\.id)
        return watch
    }
}
