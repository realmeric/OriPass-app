import AppKit
import Combine

/// What is done when a choice changes, for the things that do not read it at
/// the moment they need it. A copy reads the clipboard's seconds as it is
/// made and a fill reads "Return after the password" as it types, so those
/// need nothing. The mark, the Dock icon, the hot keys, the appearance, the
/// density, Password Health's two cards and the file that tells Orion where the
/// host is are standing things, and are made to agree here.
///
/// The lock's conditions are `LockPolicy`'s own to follow, and ⌥ is the
/// panes'.
@MainActor
final class Following {
    /// What it does to the app. The delegate fills these in; a test counts.
    struct Hands {
        /// The mark goes into the menu bar, or out of it.
        var showMark: (Bool) -> Void = { _ in }
        /// Whether the Dock icon stays is asked again.
        var updatePresence: () -> Void = {}
        var applyKeys: ([HotKeyAction: HotKey]) -> Void = { _ in }
        /// Nil follows the system.
        var setAppearance: (NSAppearance?) -> Void = { _ in }
        var setDensity: (Density) -> Void = { _ in }
                /// A Password Health switch was turned: its card is in the lists or out
        /// of them only after a count.
        var recount: () -> Void = {}
        /// The file `BrowserHosts` keeps agrees with these.
        var followHost: (BrowserChoices) -> Void = { _ in }
        /// The agent's switch, or how long its yes lasts.
        var followAgent: (SSHChoices) -> Void = { _ in }
    }

    private var watching: Set<AnyCancellable> = []

    /// The mark, the appearance, the density and Orion's file are set as this
    /// is made, so the launch and a change are one path. The keys are not: the launch registers
    /// them itself, to say which were refused.
    init(_ preferences: Preferences, hands: Hands) {
        let settings = preferences.$settings
        settings.map(\.menuBar).removeDuplicates().sink { choices in
            hands.showMark(choices.showsMark)
            // `@Published` sends before the value is in place, and the
            // presence reads it from there.
            DispatchQueue.main.async { hands.updatePresence() }
        }.store(in: &watching)
        settings.map(\.look.theme).removeDuplicates().sink { hands.setAppearance($0.appearance) }
            .store(in: &watching)
        settings.map(\.look.density).removeDuplicates().sink { hands.setDensity($0) }
            .store(in: &watching)
                settings.map(\.shortcuts).removeDuplicates().dropFirst().sink { hands.applyKeys($0.all) }
            .store(in: &watching)
        settings.map(\.privacy).map { [$0.breachCheck, $0.twoFactorCheck] }.removeDuplicates().dropFirst()
            .sink { _ in DispatchQueue.main.async { hands.recount() } }
            .store(in: &watching)
        settings.map(\.browser).removeDuplicates().sink { hands.followHost($0) }
            .store(in: &watching)
        settings.map(\.ssh).removeDuplicates().sink { hands.followAgent($0) }
            .store(in: &watching)
    }
}
