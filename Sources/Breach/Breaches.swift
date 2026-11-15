import CryptoKit
import Foundation

/// What a fetcher was told about five characters.
enum BreachAnswer: Equatable {
    /// The server's lines, as they came.
    case body(Data)
    /// The network or the server failed; nothing is known.
    case failed
}

/// Where a range comes from. The one real one is `PwnedRange`; a test and
/// the demo have their own, so nothing under test touches the network.
protocol BreachFetcher: Sendable {
    func fetch(prefix: String) async -> BreachAnswer
    /// The vault is shut: whatever was open towards a server is shut too.
    func end()
}

extension BreachFetcher {
    func end() {}
}

/// Whether a password has been seen in a breach, asked of Have I Been Pwned
/// five characters of a hash at a time (D13). Off until it is switched on,
/// since it is a request he did not make by clicking.
///
/// The store holds one and hands it the logins behind each count. A password
/// is hashed for the length of its question and the hash is dropped; what is
/// kept is the answer, under a mark that is an HMAC with a key made at the
/// unlock, so the same password is not asked about twice and nothing kept
/// here says anything to whoever finds it. All of it is memory, and `end`,
/// at the lock, empties it.
actor Breaches {
    /// What the switch says beside itself: the whole of what leaves the Mac.
    static let sentence = "Asks Have I Been Pwned whether each of your passwords has been seen in a breach. "
        + "What leaves this Mac is the first five characters of a hash of the password, sent to \(PwnedRange.host). "
        + "The rest of the hash is compared here."
    /// The least time between two requests: four a second.
    static let gap: TimeInterval = 0.25

    /// The one the app uses: the real server, and D13's switch in the
    /// settings.
    static func standard(_ preferences: Preferences) -> Breaches {
        Breaches(fetcher: PwnedRange()) { preferences.now.privacy.breachCheck }
    }

    /// What is known of some logins without asking anybody.
    struct Sightings {
        /// The ones whose password has been seen.
        let seen: [Entry]
        /// How many passwords among them nobody has been asked about.
        let unasked: Int
    }

    private let fetcher: BreachFetcher
    private let isOn: @Sendable () -> Bool
    private let gap: TimeInterval
    private var salt = SymmetricKey(size: .bits256)
    /// Whether a password was among what the server sent, by its mark.
    private var verdicts: [Data: Bool] = [:]
    /// Moves at `end`, so an answer that comes back after it is dropped.
    private var unlock = 0
    /// Requests the fetcher was given, for the tests and the tour.
    private(set) var requests = 0

    init(fetcher: BreachFetcher, gap: TimeInterval = Breaches.gap, isOn: @escaping @Sendable () -> Bool) {
        self.fetcher = fetcher
        self.gap = gap
        self.isOn = isOn
    }

    /// Whether the switch is on, read each time it is asked.
    nonisolated var asks: Bool { isOn() }

    func sightings(among entries: [Entry]) -> Sightings {
        var seen: [Entry] = []
        var unasked: Set<Data> = []
        for entry in entries {
            guard let mark = mark(of: entry) else { continue }
            switch verdicts[mark] {
            case true?: seen.append(entry)
            case false?: break
            case nil: unasked.insert(mark)
            }
        }
        return Sightings(seen: seen, unasked: unasked.count)
    }

    /// Asks about every password among `entries` that has no answer yet:
    /// one request for each five characters, however many passwords start
    /// with them, and `gap` between two. A failure ends it, and what was
    /// not answered is asked about behind the next count. False when the
    /// switch is off, or the lock or a newer count came first.
    func ask(about entries: [Entry]) async -> Bool {
        guard isOn() else { return false }
        let unlock = self.unlock
        var waiting: [String: [(mark: Data, hash: BreachMark)]] = [:]
        var queued: Set<Data> = []
        for entry in entries {
            guard let password = entry.item.login?.password, let mark = mark(of: entry),
                  verdicts[mark] == nil, queued.insert(mark).inserted else { continue }
            let hash = BreachMark(password)
            waiting[hash.prefix, default: []].append((mark, hash))
        }
        var isFirst = true
        for (prefix, asked) in waiting.sorted(by: { $0.key < $1.key }) {
            if !isFirst {
                do { try await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000)) } catch { return false }
            }
            isFirst = false
            guard isOn(), unlock == self.unlock, !Task.isCancelled else { return false }
            requests += 1
            let answer = await fetcher.fetch(prefix: prefix)
            guard unlock == self.unlock, !Task.isCancelled else { return false }
            guard case .body(let body) = answer else { break }
            let range = BreachRange(body)
            for (mark, hash) in asked { verdicts[mark] = range.holds(hash) }
        }
        return true
    }

    /// The vault is shut. Every answer goes, the key the marks were made
    /// with is replaced, and the fetcher shuts what it had open.
    func end() {
        unlock += 1
        verdicts = [:]
        salt = SymmetricKey(size: .bits256)
        fetcher.end()
    }

    /// How many answers are held, for the test of the lock.
    var held: Int { verdicts.count }

    private func mark(of entry: Entry) -> Data? {
        guard var password = entry.item.login?.password, !password.isEmpty else { return nil }
        var hmac = HMAC<SHA256>(key: salt)
        password.withUTF8 { hmac.update(data: UnsafeRawBufferPointer($0)) }
        return Data(hmac.finalize())
    }
}
