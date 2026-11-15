import AppKit
import Combine

/// When the vault shuts without being told to: the Mac goes to sleep, the
/// screen locks, the screen saver starts, another user takes the display, the
/// app quits, or nobody has touched the keyboard or the pointer for a while.
///
/// It listens from the moment a password or a finger starts opening the
/// vault, since a lid shut during the second or two that takes is posted
/// once and has to be heard. A locked app has nothing to shut, so it
/// listens to nothing and owns no timer (D18); the observers and the one
/// timer are made when the store starts to open and are gone in the same
/// turn that it locks or fails to open. `Instruments` shows that from
/// outside.
@MainActor
final class LockPolicy {
    enum Condition: CaseIterable {
        case sleep, screenLocked, screenSaver, userSwitched, quit, idle
    }

    /// Where a notification comes from. The workspace and the distributed
    /// centre are both a `NotificationCenter`, and a test makes its own.
    struct Centres {
        var workspace: NotificationCenter
        var distributed: NotificationCenter

        static var system: Centres {
            Centres(workspace: NSWorkspace.shared.notificationCenter,
                    distributed: DistributedNotificationCenter.default())
        }
    }

    private static let owner = "Lock"
    /// Posted by loginwindow when the screen locks, and by the saver when it
    /// starts. Neither has a constant in any framework.
    private static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    private static let screenSaverStarted = Notification.Name("com.apple.screensaver.didstart")

    private let store: VaultStore
    /// Each condition is a switch and the idle time is a number
    /// (`LockChoices`), as they stand now: a switch thrown while the vault is
    /// open is listened to, or not, from that turn.
    private var choices: LockChoices
    private let centres: Centres
    private let idleSeconds: () -> TimeInterval
    private let idleCheckInterval: TimeInterval

    private var watching: Set<AnyCancellable> = []
    private var observers: [(centre: NotificationCenter, token: NSObjectProtocol)] = []
    private var timer: Timer?
    private var registrations: [Instruments.Registration] = []

    init(store: VaultStore, preferences: Preferences? = nil, centres: Centres = .system,
         idleSeconds: @escaping () -> TimeInterval = LockPolicy.secondsSinceLastInput,
         idleCheckInterval: TimeInterval = 60) {
        self.store = store
        let preferences = preferences ?? Preferences()
        choices = preferences.settings.lock
        self.centres = centres
        self.idleSeconds = idleSeconds
        self.idleCheckInterval = idleCheckInterval
        store.$state.sink { [weak self] state in
            guard let self else { return }
            if state == .unlocked || state == .unlocking { self.start() } else { self.stop() }
        }.store(in: &watching)
        preferences.$settings.map(\.lock).removeDuplicates().dropFirst().sink { [weak self] lock in
            guard let self else { return }
            self.choices = lock
            guard self.store.state == .unlocked || self.store.state == .unlocking else { return }
            self.stop()
            self.start()
        }.store(in: &watching)
    }

    deinit {
        MainActor.assumeIsolated { stop() }
    }

    /// Time since the last key or pointer event anywhere in the session. It
    /// is a number the system keeps, so nothing here watches any event.
    nonisolated static func secondsSinceLastInput() -> TimeInterval {
        // `kCGAnyInputEventType`, which Swift does not import as a case.
        CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                eventType: CGEventType(rawValue: ~0)!)
    }

    var isWatching: Bool { !registrations.isEmpty }

    // MARK: Watching

    private func start() {
        guard !isWatching else { return }
        func watch(_ condition: Condition, _ centre: NotificationCenter, _ name: Notification.Name) {
            guard choices.locks(condition) else { return }
            let token = centre.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fire() }
            }
            observers.append((centre, token))
            registrations.append(Instruments.register("\(condition)", kind: .observer, owner: Self.owner))
        }
        watch(.sleep, centres.workspace, NSWorkspace.willSleepNotification)
        watch(.screenLocked, centres.distributed, Self.screenLocked)
        watch(.screenSaver, centres.distributed, Self.screenSaverStarted)
        watch(.userSwitched, centres.workspace, NSWorkspace.sessionDidResignActiveNotification)

        if choices.locks(.idle) {
            let timer = Timer.scheduledTimer(withTimeInterval: idleCheckInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkIdle() }
            }
            // A check a few seconds late costs nothing, and lets the system
            // fold it into a wake-up it was making anyway.
            timer.tolerance = idleCheckInterval / 10
            self.timer = timer
            registrations.append(Instruments.register("idle", kind: .timer, owner: Self.owner))
        }
    }

    private func stop() {
        for (centre, token) in observers { centre.removeObserver(token) }
        observers = []
        timer?.invalidate()
        timer = nil
        registrations = []
    }

    // MARK: Locking

    /// What the timer asks once a minute. Not private, because a test has no
    /// minute to wait.
    func checkIdle() {
        guard isWatching, choices.locks(.idle),
              idleSeconds() >= Double(choices.idleMinutes) * 60 else { return }
        fire()
    }

    /// Whatever the condition was, the policy stops listening in the same
    /// call, so a second notice on the way in cannot lock twice.
    private func fire() {
        guard isWatching else { return }
        stop()
        Task { await store.lock() }
    }

    /// The app is about to quit. Shutting the child here, and not leaving
    /// it to read the end of its connection after the process is gone and
    /// exit two seconds later, is what the switch is for.
    func willQuit() async {
        guard choices.locks(.quit), store.state == .unlocked else { return }
        stop()
        await store.lock()
    }
}
