import AppKit
import Combine

/// When the server is asked what changed without anybody pressing Sync Now.
/// `bw` hears nothing from it unless asked, so a login saved on the phone is
/// not here until somebody asks.
///
/// Three times. After an unlock, which is the store's own (`VaultStore.load`).
/// When one of the vault's windows comes to the front and the server was last
/// asked more than five minutes ago. And thirty minutes after it was last
/// asked, for as long as one of those windows is on screen. All three are
/// measured from the last time it was asked, answered or not, so ten
/// activations in a minute are one sync and a Mac with no network asks no
/// more often than one with it.
///
/// It exists only while the store is unlocked, as `LockPolicy` does: the
/// observers are made when the store opens and gone in the turn it locks.
/// The timer is one shot, set for the next time a sync falls due and only
/// while a window is on screen, so a closed or hidden window leaves nothing
/// that fires (D18). `Instruments` shows both from outside.
@MainActor
final class SyncPolicy {
    /// How long a list may stand in a window that is on screen.
    static let whileShown: TimeInterval = 30 * 60

    private static let owner = "Sync"

    private let store: VaultStore
    private let centre: NotificationCenter
    private let every: TimeInterval
    private let isOnScreen: (NSWindow?) -> Bool

    private var watching: AnyCancellable?
    private var attempts: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var registrations: [Instruments.Registration] = []
    private var timer: Timer?
    private var ticking: Instruments.Registration?

    /// When the timer will ask, or nil when there is none.
    private(set) var nextCheck: Date?
    /// The sync this policy started last, kept so a test can wait for it.
    private(set) var asking: Task<Void, Never>?
    private var isAsking = false

    /// `isOnScreen` is asked whether a window of the vault's can be seen,
    /// leaving out the one it is handed, which is closing.
    init(store: VaultStore, centre: NotificationCenter = .default,
         every: TimeInterval = SyncPolicy.whileShown,
         isOnScreen: @escaping (NSWindow?) -> Bool = SyncPolicy.aWindowIsOnScreen) {
        self.store = store
        self.centre = centre
        self.every = every
        self.isOnScreen = isOnScreen
        watching = store.$state.sink { [weak self] state in
            guard let self else { return }
            if state == .unlocked { self.start() } else { self.stop() }
        }
    }

    deinit {
        MainActor.assumeIsolated { stop() }
    }

    var isWatching: Bool { !registrations.isEmpty }

    /// A window with a title bar that is not a panel: the main one and a
    /// window of one item. Quick Access, Large Type and the mark's own
    /// window in the menu bar are none of them.
    nonisolated static func isTheVaults(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && !(window is NSPanel)
    }

    /// Whether any of it can be seen: not closed, not in the Dock, not on
    /// another desktop, not wholly under other windows and not behind a
    /// locked screen.
    static func aWindowIsOnScreen(besides closing: NSWindow?) -> Bool {
        NSApp.windows.contains { window in
            window !== closing && isTheVaults(window) && window.isVisible
                && window.occlusionState.contains(.visible)
        }
    }

    // MARK: Watching

    private func start() {
        guard !isWatching else { return }
        func watch(_ name: String, _ notice: Notification.Name, _ act: @escaping (SyncPolicy, NSWindow) -> Void) {
            let token = centre.addObserver(forName: notice, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let window = note.object as? NSWindow, Self.isTheVaults(window) else { return }
                    act(self, window)
                }
            }
            observers.append(token)
            registrations.append(Instruments.register(name, kind: .observer, owner: Self.owner))
        }
        watch("key", NSWindow.didBecomeKeyNotification) { policy, _ in policy.cameToFront() }
        watch("shown", NSWindow.didChangeOcclusionStateNotification) { policy, _ in policy.arrange() }
        // A window that is closing still says it is visible.
        watch("closing", NSWindow.willCloseNotification) { policy, window in policy.arrange(besides: window) }
        // Published before it is set, so the day is the one handed over.
        attempts = store.$lastAttempt.sink { [weak self] attempt in self?.arrange(since: attempt) }
    }

    private func stop() {
        observers.forEach(centre.removeObserver)
        observers = []
        registrations = []
        attempts = nil
        // A question already out is the store's to end: it comes back to a
        // locked store and changes nothing there.
        isAsking = false
        disarm()
    }

    private func disarm() {
        timer?.invalidate()
        timer = nil
        ticking = nil
        nextCheck = nil
    }

    // MARK: Asking

    private func due(after interval: TimeInterval) -> Bool {
        store.sinceLastAttempt.map { $0 >= interval } ?? true
    }

    /// One of the vault's windows has the keys. The foot's age is read again
    /// either way, since this is when it is looked at.
    private func cameToFront() {
        guard isWatching else { return }
        if due(after: VaultStore.freshFor) { ask() } else { store.restate() }
    }

    /// What the timer asks. Not private, because a test has no half hour to
    /// wait.
    func check() {
        guard isWatching, isOnScreen(nil) else { return disarm() }
        if due(after: every) { ask() } else { arrange() }
    }

    /// The store marks the attempt as it begins, which sets the timer for
    /// the one after it.
    private func ask() {
        // Two notices in one turn are one question.
        guard !isAsking else { return }
        isAsking = true
        asking = Task { [weak self, store] in
            await store.sync()
            self?.isAsking = false
        }
    }

    /// Sets the one timer for when the next sync falls due, or takes it away
    /// when no window is on screen.
    private func arrange(besides closing: NSWindow? = nil) {
        arrange(since: store.lastAttempt, besides: closing)
    }

    private func arrange(since attempt: Date?, besides closing: NSWindow? = nil) {
        disarm()
        guard isWatching, isOnScreen(closing) else { return }
        let wait = attempt.map { every - store.now().timeIntervalSince($0) } ?? 0
        guard wait > 0 else {
            // Already due: a window came back on screen after the half hour.
            // Asking marks the attempt, which comes back here for the timer.
            ask()
            return
        }
        let timer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        // A few minutes late costs nothing, and lets the system fold it into
        // a wake-up it was making anyway.
        timer.tolerance = every / 10
        self.timer = timer
        ticking = Instruments.register("next", kind: .timer, owner: Self.owner)
        nextCheck = store.now().addingTimeInterval(wait)
    }
}
