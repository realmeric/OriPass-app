import Foundation

/// What can be seen from outside about the things that keep this app awake.
///
/// D18 says a locked app has no timer and an unlocked one has one, and that is
/// a claim about every object in the process, which a test can only check if
/// the objects say they exist. Whatever lives for longer than a call and wakes
/// the process or listens for something registers here, and holds the token
/// for as long as it lives. Dropping the token takes the entry out, so nothing
/// has to remember to deregister, and a timer whose owner went away without
/// stopping it is the leak the registry is there to show.
///
/// Ported from OriNotch's registry and cut to the part this app uses.
enum Instruments {
    enum Kind: String {
        /// Fires on its own, whether or not anybody is doing anything.
        case timer
        /// Costs nothing until the thing it listens for happens.
        case observer

        var firesByItself: Bool { self == .timer }
    }

    struct Entry {
        let name: String
        let kind: Kind
        let owner: String
    }

    final class Registration {
        fileprivate let id: UInt64
        fileprivate init(id: UInt64) { self.id = id }
        deinit { Instruments.forget(id) }
    }

    private static let lock = NSLock()
    private static var entries: [UInt64: Entry] = [:]
    private static var nextID: UInt64 = 1

    /// `owner` is the feature that switched the thing on, so that a stray
    /// entry names the place to look.
    static func register(_ name: String, kind: Kind, owner: String) -> Registration {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        entries[id] = Entry(name: name, kind: kind, owner: owner)
        return Registration(id: id)
    }

    fileprivate static func forget(_ id: UInt64) {
        lock.lock()
        entries.removeValue(forKey: id)
        lock.unlock()
    }

    /// Everything alive now, in an order that does not depend on when it was
    /// made, so two reads of the same state read the same.
    static var live: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.sorted { ($0.owner, $0.name) < ($1.owner, $1.name) }
    }
}
