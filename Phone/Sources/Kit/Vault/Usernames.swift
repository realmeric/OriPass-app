import Foundation

/// The usernames the vault's logins already use, for a new login's field:
/// most used first, then by name, narrowed to those that begin with what
/// is typed. The trash does not count.
enum Usernames {
    static func ranked(_ usernames: [String?]) -> [String] {
        var counts: [String: Int] = [:]
        for name in usernames {
            guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            counts[name, default: 0] += 1
        }
        return counts.sorted { a, b in
            a.value != b.value ? a.value > b.value : a.key.localizedStandardCompare(b.key) == .orderedAscending
        }.map(\.key)
    }

    static func ranked(_ items: [Item]) -> [String] {
        ranked(items.filter { $0.kind == .login && !$0.deleted }.map { $0.login?.username })
    }

    /// Those that begin with `typed`, in any case; the one typed in full
    /// is not offered again.
    static func matching(_ typed: String, in ranked: [String]) -> [String] {
        let typed = typed.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return ranked }
        return ranked.filter { $0.range(of: typed, options: [.anchored, .caseInsensitive]) != nil && $0 != typed }
    }
}
