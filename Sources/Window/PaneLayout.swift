import CoreGraphics

/// How a width is shared between the three columns. Each has the width it
/// would like and one it will not go under. A window too narrow for what they
/// would like takes from the details first, then from the list, then from the
/// sidebar, and when all three stand at their minimums the sidebar folds away
/// and the other two have the window to themselves.
///
/// The hairlines are drawn inside the columns' own widths, so the three add
/// up to the window's.
struct PaneLayout: Equatable {
    /// Nought when the sidebar is folded away.
    let sidebar: CGFloat
    let list: CGFloat
    let detail: CGFloat

    var showsSidebar: Bool { sidebar > 0 }

    /// The narrowest the window can be with all three columns in it.
    static let narrowestWithSidebar = Metrics.sidebarMinimum + Metrics.listMinimum + Metrics.detailMinimum

    init(width: CGFloat, wantsSidebar: Bool) {
        let shows = wantsSidebar && width >= Self.narrowestWithSidebar
        var sidebar = shows ? Metrics.sidebarWidth : 0
        var list = Metrics.listWidth
        var short = Metrics.detailMinimum - (width - sidebar - list)
        if short > 0 {
            let fromList = min(short, list - Metrics.listMinimum)
            list -= fromList
            short -= fromList
        }
        if short > 0, shows {
            sidebar -= min(short, sidebar - Metrics.sidebarMinimum)
        }
        self.sidebar = sidebar
        self.list = list
        // Under its minimum only in a window narrower than `windowMinimum`,
        // which the window itself does not allow.
        detail = max(0, width - sidebar - list)
    }
}
