import AppKit
import Foundation

/// What a fetcher found for a host.
enum IconAnswer: Equatable {
    case image(Data)
    /// The site has no icon, and asking again tomorrow will not give it one.
    case none
    /// The network or the server failed; nothing is known about the site.
    case failed
}

/// Where an icon comes from when the cache has none. The one real one is
/// `BitwardenIcons`; a test or the demo has its own, so nothing under test
/// touches the network.
protocol IconFetcher {
    func fetch(host: String) async -> IconAnswer
    /// The store that held this fetcher is done with it: whatever it kept
    /// open towards a server is shut, and it answers nothing after.
    func end()
}

extension IconFetcher {
    func end() {}
}

/// The face of a login's site, from memory, then from a file under Caches,
/// then from the network (`docs/notes.md`, "Icons, breaches and the two-factor
/// list"). Hosts are the file names, so the folder says which sites he has
/// logins for, which is D14's cost and is said in the notes. The panes own
/// the store the memory half of it lives in, so a lock drops that half with
/// them; the files stay. A lock also ends it (`end`, which `Door` calls
/// as it drops the panes): the requests in flight are cancelled, and one
/// that was cancelled writes nothing, in memory or under Caches.
///
/// A host is asked about by one request at a time. A row that asks and is
/// gone before `settle` has passed starts no request, which is how a list
/// scrolled through at speed asks about the dozen rows it stops on and not
/// the thousand it flew over.
@MainActor
final class IconStore {
    /// How long a row has to stay in view before the network is asked.
    nonisolated static let settle: TimeInterval = 0.3
    /// A site with no icon is not asked about again for a week.
    nonisolated static let missLifetime: TimeInterval = 7 * 24 * 60 * 60
    /// A failure is tried again after this long, in the same launch.
    nonisolated static let retryAfter: TimeInterval = 60

    /// Draws no icon and asks for none: what a panes model without a source
    /// of icons holds, and what a shot or a test of something else gets.
    static let off = IconStore(fetcher: nil, directory: nil, isOn: { false })

    /// What the switch's row in the Privacy room says: what is sent, and to
    /// whom (D14).
    static let sentence = "Asks \(BitwardenIcons.host), Bitwarden's icon server, for the icon of each site you have a login for, "
        + "which tells that server which sites those are. Off, a lettered tile is drawn and nothing is asked."

    /// The one the app uses: Bitwarden's server, a folder under Caches, and
    /// D14's switch in the settings.
    static func standard(_ preferences: Preferences) -> IconStore {
        IconStore(fetcher: BitwardenIcons(), directory: AppPaths.icons) {
            preferences.settings.privacy.siteIcons
        }
    }

    private let fetcher: IconFetcher?
    private let cache: IconCache?
    private let isOn: () -> Bool
    private let settle: TimeInterval
    private let now: () -> Date
    private var images: [String: NSImage] = [:]
    /// When each host was last found to have nothing, or to be unreachable.
    private var misses: [String: Date] = [:]
    private var failures: [String: Date] = [:]
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    /// Requests the fetcher was given, for the tests and the scroll trace.
    private(set) var requests = 0
    /// Set by `end`. A store that has ended asks nobody and keeps nothing.
    private(set) var hasEnded = false

    init(fetcher: IconFetcher?, directory: URL?, isOn: @escaping () -> Bool = { true },
         settle: TimeInterval = IconStore.settle, now: @escaping () -> Date = Date.init) {
        self.fetcher = fetcher
        cache = directory.map { IconCache(directory: $0, missLifetime: IconStore.missLifetime) }
        self.isOn = isOn
        self.settle = settle
        self.now = now
    }

    /// What is already in memory, so a row that is built again draws its
    /// icon in its first frame and not its second.
    func cached(_ host: String) -> NSImage? {
        isOn() ? images[host] : nil
    }

    /// Puts icons in memory without asking anybody: the shots', whose first
    /// frame is the only one.
    func seed(_ icons: [String: Data]) {
        for (host, data) in icons {
            if let image = Self.decode(data) { images[host] = image }
        }
    }

    /// The icon for `host`, or nil when there is none, the switch is off or
    /// the row asking has been cancelled. Cancelling before the settle has
    /// passed is free.
    func image(for host: String) async -> NSImage? {
        guard SiteHost.isValid(host), isOn(), !hasEnded else { return nil }
        if let answer = known(host) { return answer.image }

        if let cache {
            let found = await cache.read(host, now: now())
            guard !hasEnded else { return nil }
            if let answer = known(host) { return answer.image }
            switch found {
            case .image(let data):
                if let image = Self.decode(data) {
                    images[host] = image
                    return image
                }
            case .miss:
                misses[host] = now()
                return nil
            case .nothing:
                break
            }
        }
        guard fetcher != nil else { return nil }

        do {
            try await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
        } catch {
            return nil
        }
        guard isOn(), !hasEnded else { return nil }
        if let answer = known(host) { return answer.image }
        let job = inFlight[host] ?? start(host)
        return await job.value
    }

    /// An answer that needs no request: an icon in memory, or a host that was
    /// lately found to have none.
    private func known(_ host: String) -> Known? {
        if let image = images[host] { return .image(image) }
        if let missed = misses[host], now().timeIntervalSince(missed) < Self.missLifetime { return .nothing }
        if let failed = failures[host], now().timeIntervalSince(failed) < Self.retryAfter { return .nothing }
        return nil
    }

    private enum Known {
        case image(NSImage)
        case nothing

        var image: NSImage? {
            if case .image(let image) = self { return image }
            return nil
        }
    }

    private func start(_ host: String) -> Task<NSImage?, Never> {
        // Not a child of any row's task: a row that leaves after the request
        // is made does not cancel what the others are waiting for. `end`
        // cancels it.
        let job = Task { await self.ask(host) }
        inFlight[host] = job
        return job
    }

    private func ask(_ host: String) async -> NSImage? {
        defer { inFlight[host] = nil }
        guard let fetcher, !hasEnded else { return nil }
        requests += 1
        let answer = await fetcher.fetch(host: host)
        // The vault was locked while the server was thinking. Whatever came
        // back, the host of one of his logins is not written down now.
        guard !hasEnded, !Task.isCancelled else { return nil }
        switch answer {
        case .image(let data):
            guard let image = Self.decode(data) else {
                failures[host] = now()
                return nil
            }
            images[host] = image
            await cache?.write(image: data, for: host)
            return image
        case .none:
            misses[host] = now()
            await cache?.writeMiss(for: host, at: now())
            return nil
        case .failed:
            failures[host] = now()
            return nil
        }
    }

    /// The vault is shut. Every request in flight is cancelled, the fetcher
    /// shuts what it had open, and the memory half is emptied. The store is
    /// not used again: the next unlock makes its own.
    func end() {
        guard !hasEnded else { return }
        hasEnded = true
        inFlight.values.forEach { $0.cancel() }
        inFlight = [:]
        images = [:]
        fetcher?.end()
    }

    private static func decode(_ data: Data) -> NSImage? {
        guard let image = NSImage(data: data), image.isValid, image.size.width > 0, image.size.height > 0
        else { return nil }
        return image
    }
}

/// The files: `<host>.png` for an icon, and `<host>.miss` holding the moment
/// the server said there was none. Read and written off the main thread.
struct IconCache: Sendable {
    enum Found {
        case image(Data)
        case miss
        case nothing
    }

    let directory: URL
    let missLifetime: TimeInterval

    func read(_ host: String, now: Date) async -> Found {
        await Task.detached { readNow(host, now: now) }.value
    }

    /// What the door hands a toast: an icon the app already has, and a
    /// request to nobody, with D14's switch on.
    @MainActor
    static func standard(_ preferences: Preferences) -> (String) async -> Data? {
        let cache = IconCache(directory: AppPaths.icons, missLifetime: IconStore.missLifetime)
        return { [weak preferences] host in
            guard preferences?.settings.privacy.siteIcons == true,
                  case .image(let data) = await cache.read(host, now: Date()) else { return nil }
            return data
        }
    }

    func write(image: Data, for host: String) async {
        await Task.detached {
            guard makeDirectory() else { return }
            try? image.write(to: file(host, "png"), options: .atomic)
            try? FileManager.default.removeItem(at: file(host, "miss"))
        }.value
    }

    func writeMiss(for host: String, at moment: Date) async {
        await Task.detached {
            guard makeDirectory() else { return }
            try? Data(String(moment.timeIntervalSince1970).utf8).write(to: file(host, "miss"), options: .atomic)
        }.value
    }

    private func readNow(_ host: String, now: Date) -> Found {
        if let data = try? Data(contentsOf: file(host, "png")), !data.isEmpty { return .image(data) }
        if let text = try? String(contentsOf: file(host, "miss"), encoding: .utf8),
           let seconds = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           now.timeIntervalSince(Date(timeIntervalSince1970: seconds)) < missLifetime {
            return .miss
        }
        return .nothing
    }

    private func file(_ host: String, _ kind: String) -> URL {
        directory.appendingPathComponent("\(host).\(kind)")
    }

    private func makeDirectory() -> Bool {
        (try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil
    }
}
