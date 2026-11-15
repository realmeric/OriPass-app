import Foundation

/// The breach check for the demo vault, which asks nobody: a fetcher that
/// answers from memory in the server's own shape, padding and all, and says
/// the demo's three weak passwords have been seen. So the demo, the shots
/// and the tour hash every password and read a range as the app does, and
/// no five characters leave the Mac.
enum DemoBreaches {
    static let seen = DemoVault.weak

    /// `isOn` is the switch, which a shot turns for the surfaces that are
    /// of it.
    static func checker(gap: TimeInterval = 0, isOn: @escaping @Sendable () -> Bool = { true }) -> Breaches {
        Breaches(fetcher: Fetcher(), gap: gap, isOn: isOn)
    }

    struct Fetcher: BreachFetcher {
        func fetch(prefix: String) async -> BreachAnswer {
            var lines = ["0018A45C4D1DEF81644B54AB7F969B88D65:3"]
            lines += seen.map(BreachMark.init).filter { $0.prefix == prefix }.map { "\($0.suffix):1200" }
            lines += ["7975BAB577D7C839EC2E3E1BDD1E9EA3602:0", "3CA0B013A9310A0EA6DD4B934358C9CFBEF:0"]
            return .body(Data(lines.joined(separator: "\r\n").utf8))
        }
    }
}
