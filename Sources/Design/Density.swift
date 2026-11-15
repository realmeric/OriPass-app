import Foundation

/// How close the rows are. Compact is the same type in less room: a row's
/// height and the larger paddings come down, and no face, icon or control
/// changes its size. `Metrics.row` and `Metrics.room` are where it is read.
enum Density: String, Codable, CaseIterable {
    case comfortable, compact

    /// Posted when it has changed, for a window that draws from `Metrics`
    /// and is not the door's.
    static let didChange = Notification.Name("DensityDidChange")

    /// What a row's height is multiplied by. A row of the list keeps its
    /// icon and its two lines at this, with four points over and under.
    var rows: CGFloat { self == .compact ? 0.84 : 1 }

    /// And a padding of twelve points or more. The smaller ones stand
    /// between a mark and its word, and stay.
    var room: CGFloat { self == .compact ? 0.75 : 1 }
}
