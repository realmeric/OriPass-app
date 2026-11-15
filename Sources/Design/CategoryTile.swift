import SwiftUI

extension Glyph {
    static func category(_ type: ItemType) -> Glyph {
        switch type {
        case .login: return .login
        case .secureNote: return .secureNote
        case .card: return .card
        case .identity: return .identity
        case .sshKey: return .sshKey
        case .unknown: return .unknownType
        }
    }
}

/// A rounded square with a category's mark on it, for an item that is not a
/// login and has nothing of a site to show.
struct CategoryTile: View {
    let type: ItemType
    let side: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: side * Metrics.iconCorner, style: .continuous)
            .fill(Palette.lit)
            .frame(width: side, height: side)
            .overlay(
                Glyph.category(type).image
                    .font(Fonts.tileMark(side))
                    .foregroundStyle(Palette.onColour)
            )
            .accessibilityHidden(true)
    }
}
