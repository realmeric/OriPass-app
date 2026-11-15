import Foundation

/// How the list on screen stands against the server, which is what the foot
/// of the sidebar says. `VaultStore.standing` works it out when something is
/// drawn; nothing ticks to keep the age it states.
enum SyncStanding: Equatable {
    /// `bw` has no day for its last sync and has not been asked for one.
    case never
    /// The server is being asked now.
    case syncing
    /// It answered, this many seconds ago.
    case synced(TimeInterval)
    /// The last time it was asked it did not answer. What is listed is what
    /// `bw` had before.
    case offline

    static let offlineSentence = "Offline, showing what this Mac last saw"

    var isOffline: Bool { self == .offline }

    /// The whole of what the foot says. An age is cut down, never rounded
    /// up: ninety seconds is a minute.
    var sentence: String {
        switch self {
        case .never: return "Not synced yet"
        case .syncing: return "Syncing…"
        case .offline: return Self.offlineSentence
        case .synced(let age):
            // A clock put back since the answer makes it a moment ago.
            let minutes = Int(max(age, 0) / 60)
            switch minutes {
            case 0: return "Synced just now"
            case ..<60: return "Synced \(minutes) min ago"
            case ..<(24 * 60): return "Synced \(minutes / 60) hr ago"
            case ..<(48 * 60): return "Synced 1 day ago"
            default: return "Synced \(minutes / (24 * 60)) days ago"
            }
        }
    }
}
