import Foundation

/// What a field with no login for the site can be offered. `usernames` is the
/// words the vault already uses and nothing else of any item, so that a page's
/// mark can offer an address on a site the vault has never seen. `generate` is
/// the engine's, as every password here is (D4). Both are a page's caller's
/// alone, and neither holds anything to the page but that it is one, since
/// neither hands over anything of a login's.
@MainActor
final class OfferDoor {
    /// As many as a menu shows at once and a few more to scroll to, so that no
    /// message lists the vault.
    static let mostUsernames = 8

    private let store: VaultStore
    private let settings: () -> GeneratorSettings

    init(store: VaultStore, settings: @escaping () -> GeneratorSettings) {
        self.store = store
        self.settings = settings
    }

    func usernames(on url: String, addressesOnly: Bool) async -> BridgeAnswer {
        guard Address.page(url) != nil else { return .refused(.page) }
        let shelves = store.shelves
        let used = (shelves.byType[.login] ?? []).compactMap(\.item.login?.username)
        let emails = (shelves.byType[.identity] ?? []).compactMap { entry -> String? in
            guard case .identity(let identity) = entry.item.payload else { return nil }
            return identity[.email]
        }
        let ranked = Self.ranked(used, then: emails)
        let wanted = addressesOnly ? ranked.filter { $0.contains("@") } : ranked
        return .usernames(Array(wanted.prefix(Self.mostUsernames)))
    }

    /// Most used first, then by name, one row for each however it was spelled,
    /// with `also` behind them in the order of their names.
    static func ranked(_ usernames: [String], then also: [String] = []) -> [String] {
        var counts: [String: (word: String, count: Int)] = [:]
        for word in usernames.map(trimmed) where !word.isEmpty {
            counts[word.lowercased(), default: (word, 0)].count += 1
        }
        let used = counts.values.sorted { one, other in
            one.count != other.count ? one.count > other.count
                : one.word.localizedStandardCompare(other.word) == .orderedAscending
        }.map(\.word)
        let extra = also.map(trimmed).filter { !$0.isEmpty && counts[$0.lowercased()] == nil }
        return used + Set(extra).sorted()
    }

    private static func trimmed(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func generate(for url: String, most: Int?) async -> BridgeAnswer {
        guard Address.page(url) != nil else { return .refused(.page) }
        do {
            return .generated(try await store.generate(settings().recipe(forAFieldOf: most)))
        } catch VaultError.locked {
            return .locked
        } catch {
            return .refused(.unmade)
        }
    }
}
