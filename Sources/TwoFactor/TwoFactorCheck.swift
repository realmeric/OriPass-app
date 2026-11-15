import Foundation

/// Which sites take a one-time code, asked of 2fa.directory once a week and
/// otherwise of a file under Caches (D13). Off until it is switched on,
/// since it is a request he did not make by clicking.
///
/// The store holds one. It is asked behind each count while the switch is on
/// and hands back the list, which the store compares with the logins; the
/// list is held in memory for the unlock and `end`, at the lock, drops it
/// and shuts the connection.
actor TwoFactorCheck {
    /// What the switch says beside itself: the whole of what leaves the Mac,
    /// and the attribution the list's licence asks for.
    static let sentence = "Fetches a public list of the sites that take a one-time code from \(TwoFactorDirectory.host) "
        + "once a week, and compares it here with the addresses of your logins. Nothing of your vault is sent. "
        + "Data sourced from 2FA Directory by 2factorauth."
    /// How long the file under Caches is good for.
    static let week: TimeInterval = 7 * 24 * 60 * 60
    /// How long a failure is remembered, so that a Mac with no network
    /// makes one request a minute and not one for each count.
    static let pause: TimeInterval = 60

    /// The one the app uses: 2fa.directory, a folder under Caches, and
    /// D13's switch in the settings.
    static func standard(_ preferences: Preferences) -> TwoFactorCheck {
        TwoFactorCheck(source: TwoFactorDirectory(), cache: TwoFactorCache(directory: AppPaths.twoFactor)) {
            preferences.now.privacy.twoFactorCheck
        }
    }

    private let source: TwoFactorSource
    private let cache: TwoFactorCache?
    private let now: @Sendable () -> Date
    private let isOn: @Sendable () -> Bool
    private var list: TwoFactorList?
    /// The one request, while it is out.
    private var loading: Task<Void, Never>?
    /// Whoever is waiting for it, each to be answered once.
    private var waiting: [Int: CheckedContinuation<TwoFactorList?, Never>] = [:]
    private var waited = 0
    private var failedAt: Date?
    /// Moves at `end`, so an answer that comes back after it is dropped.
    private var unlock = 0
    /// Requests the source was given, for the tests and the tour.
    private(set) var requests = 0

    init(source: TwoFactorSource, cache: TwoFactorCache? = nil, now: @escaping @Sendable () -> Date = Date.init,
         isOn: @escaping @Sendable () -> Bool) {
        self.source = source
        self.cache = cache
        self.now = now
        self.isOn = isOn
    }

    /// Whether the switch is on, read each time it is asked.
    nonisolated var asks: Bool { isOn() }

    /// The list if this unlock has one, without asking anybody.
    var held: TwoFactorList? { list }

    /// The list: held, or from the file if it is a week old or less, or
    /// from the server. A file older than that is used when the server does
    /// not answer. Nil when there is none to be had, or the switch is off,
    /// or the lock came first, or whoever asked was cancelled.
    ///
    /// The request is nobody's who asks. One who is cancelled stops waiting
    /// and the request goes on for the next, since a count gives way to the
    /// one behind it on every change and that one wants the same list. Only
    /// `end` cancels it.
    func load() async -> TwoFactorList? {
        guard isOn() else { return nil }
        if let list { return list }
        if loading == nil {
            if let failedAt, now().timeIntervalSince(failedAt) < Self.pause { return nil }
            let unlock = self.unlock
            loading = Task { await self.settle(await self.obtain(), of: unlock) }
        }
        let place = waited
        waited += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiter in
                if Task.isCancelled { waiter.resume(returning: nil) } else { waiting[place] = waiter }
            }
        } onCancel: {
            Task { await self.release(place) }
        }
    }

    /// The vault is shut. The list goes, a request in the air is cancelled,
    /// whoever waited for it is told there is none, and the source shuts
    /// what it had open.
    func end() {
        unlock += 1
        list = nil
        loading?.cancel()
        loading = nil
        failedAt = nil
        answer(nil)
        source.end()
    }

    /// The request is over. Its answer is kept, or its failure is, unless
    /// the lock came while it was out.
    private func settle(_ got: TwoFactorList?, of unlock: Int) {
        guard unlock == self.unlock else { return }
        loading = nil
        if let got { list = got } else { failedAt = now() }
        answer(got)
    }

    private func answer(_ got: TwoFactorList?) {
        let told = waiting.values
        waiting = [:]
        for waiter in told { waiter.resume(returning: got) }
    }

    /// One who was waiting was cancelled, and waits no longer.
    private func release(_ place: Int) {
        waiting.removeValue(forKey: place)?.resume(returning: nil)
    }

    private func obtain() async -> TwoFactorList? {
        let kept = cache?.read()
        let fresh = kept.flatMap { now().timeIntervalSince($0.written) <= Self.week ? $0 : nil }
        if let fresh, let list = TwoFactorList(fresh.data) { return list }
        guard !Task.isCancelled else { return nil }
        requests += 1
        if let body = await source.fetch(), !Task.isCancelled, let list = TwoFactorList(body) {
            cache?.write(body, at: now())
            return list
        }
        return kept.flatMap { TwoFactorList($0.data) }
    }
}
