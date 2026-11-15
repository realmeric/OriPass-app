import Combine
import Foundation
import os

/// What has been chosen. A view binds to a field and never sees the storage;
/// whatever has to follow a change subscribes to `$settings` and reads the
/// field out of what is sent, because `@Published` sends in `willSet` and
/// the model still holds the old value then.
///
/// One for the app, made by the delegate. A door, a set of panes or a lock
/// policy made without one gets its own, which keeps nothing.
@MainActor
final class Preferences: ObservableObject {
    @Published var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            let chosen = settings
            latest.withLock { $0 = chosen }
            store.save(chosen)
        }
    }

    private let store: SettingsStore
    private let latest: OSAllocatedUnfairLock<Settings>

    init(defaults: UserDefaults? = nil) {
        let store = SettingsStore(defaults: defaults)
        let settings = store.load()
        self.store = store
        self.settings = settings
        latest = OSAllocatedUnfairLock(initialState: settings)
    }

    /// The same value for whoever is not on the main thread: the breach
    /// check and the list of two-factor sites read their switches from an
    /// actor of their own.
    nonisolated var now: Settings { latest.withLock { $0 } }

    /// `bw` at the path that was chosen, and then wherever `BwBinary` looks.
    /// Asked each time the engine has no binary yet, so a path set while the
    /// window says there is no CLI is found by its next look.
    nonisolated var bwFinder: BwBinary.Finder {
        { [self] preferred in BwBinary.find(preferred: preferred ?? now.engine.bwPath) }
    }
}
