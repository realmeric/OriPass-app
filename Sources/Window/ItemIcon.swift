import AppKit
import SwiftUI

/// What a row wears at its left. A login wears its site's icon once there is
/// one, and until then, and for good when there is none or the switch is off,
/// a tile with its title's first letter. The other four types wear their
/// category's mark (OP-22), and so does a login that has no title yet.
struct ItemIcon: View {
    let item: Item
    let icons: IconStore
    let side: CGFloat
    private let host: String?
    @State private var image: NSImage?

    init(item: Item, icons: IconStore, side: CGFloat) {
        self.item = item
        self.icons = icons
        self.side = side
        let host = item.type == .login ? item.iconHost : nil
        self.host = host
        _image = State(initialValue: host.flatMap(icons.cached))
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: side * Metrics.iconCorner, style: .continuous))
                    .accessibilityHidden(true)
            } else if item.type == .login, !item.isNew {
                LetterTile(title: item.name, side: side)
            } else {
                CategoryTile(type: item.type, side: side)
            }
        }
        // Cancelled when the row leaves the screen, which is what keeps a
        // fast scroll from asking about every row it passes.
        .task(id: host) {
            guard let host else {
                image = nil
                return
            }
            if let known = icons.cached(host) {
                image = known
            } else {
                image = await icons.image(for: host)
            }
        }
    }
}
