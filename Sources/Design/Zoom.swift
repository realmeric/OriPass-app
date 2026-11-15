import Foundation

/// The three sizes ⌘-, ⌘0 and ⌘+ move between. Every distance read through
/// `Metrics.scaled` and every size in `Fonts` follows; the columns' widths
/// and the toolbar's height do not, so a larger size is larger type in the
/// same window and not a larger window.
enum Zoom: Int, CaseIterable, Codable {
    case small = -1, actual, large

    /// Posted when the size has changed, for a window that draws from
    /// `Metrics` and is not the door's.
    static let didChange = Notification.Name("ZoomDidChange")

    var factor: CGFloat {
        switch self {
        case .small: return 0.9
        case .actual: return 1
        case .large: return 1.15
        }
    }

    var larger: Zoom? { Zoom(rawValue: rawValue + 1) }
    var smaller: Zoom? { Zoom(rawValue: rawValue - 1) }
}
