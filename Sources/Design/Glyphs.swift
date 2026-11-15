import SwiftUI

/// The app's marks. The ones that mean what they mean everywhere on a Mac are
/// SF Symbols, chosen here and nowhere else; the app's own mark is drawn. No
/// artwork of anybody else's, and no keyhole in a ring (D8).
enum Glyph: String, CaseIterable {
    // The five categories, and the one for a type this app does not know.
    case login, secureNote, card, identity, sshKey, unknownType
    // The sidebar.
    case allItems, favorites, passwordHealth, archive, trash
    // What a toolbar, a menu or a row needs.
    case search, add, back, forward, chevronDown, chevronRight, edit, more, copy
    case reveal, conceal, star, fingerprint, lock, settings, sync, sort, filter, categories
    case link, newWindow, move, duplicate, largeType, history, generate, close, warning, tick
    case passkey, attachment, refresh, unticked, info, clear, unfavourite, restore
    // The editor's form.
    case remove, chevronUp
    // The foot of the sidebar, when the server did not answer.
    case offline
    // The notice that a login was copied and not typed.
    case keyboard
    // "Show Items" on one of Password Health's cards.
    case onward
    // The rooms of the settings window that have no mark already.
    case appearance, privacy

    var symbol: String {
        switch self {
        case .login: return "person.crop.circle"
        case .secureNote: return "note.text"
        case .card: return "creditcard"
        case .identity: return "person.text.rectangle"
        case .sshKey: return "terminal"
        case .unknownType: return "questionmark.square.dashed"
        case .allItems: return "tray.full"
        case .favorites: return "star"
        case .passwordHealth: return "binoculars"
        case .archive: return "archivebox"
        case .trash: return "trash"
        case .search: return "magnifyingglass"
        case .add: return "plus"
        case .back: return "chevron.left"
        case .forward: return "chevron.right"
        case .chevronDown: return "chevron.down"
        case .chevronRight: return "chevron.right"
        case .edit: return "pencil"
        case .more: return "ellipsis"
        case .copy: return "doc.on.doc"
        case .reveal: return "eye"
        case .conceal: return "eye.slash"
        case .star: return "star.fill"
        case .fingerprint: return "touchid"
        case .lock: return "lock"
        case .settings: return "gearshape"
        case .sync: return "arrow.triangle.2.circlepath"
        case .sort: return "arrow.up.arrow.down"
        case .filter: return "text.magnifyingglass"
        case .categories: return "square.grid.2x2.fill"
        case .link: return "arrow.up.right"
        case .newWindow: return "macwindow.badge.plus"
        case .move: return "folder"
        case .duplicate: return "plus.square.on.square"
        case .largeType: return "textformat.size"
        case .history: return "clock.arrow.circlepath"
        case .generate: return "wand.and.stars"
        case .close: return "xmark"
        case .warning: return "exclamationmark.triangle"
        case .tick: return "checkmark"
        case .passkey: return "person.badge.key"
        case .attachment: return "paperclip"
        case .refresh: return "arrow.clockwise"
        case .unticked: return "minus"
        case .info: return "info.circle"
        case .clear: return "xmark.circle.fill"
        case .unfavourite: return "star.slash"
        case .restore: return "arrow.uturn.backward"
        case .remove: return "minus.circle"
        case .chevronUp: return "chevron.up"
        case .offline: return "wifi.slash"
        case .keyboard: return "keyboard"
        case .onward: return "arrow.right"
        case .appearance: return "paintbrush"
        case .privacy: return "hand.raised"
        }
    }

    var image: Image { Image(systemName: symbol) }
}

/// The app's own mark, for the lock screen, the menu bar and the icon: a pass
/// with one corner folded and three dots where a password would be.
///
/// Drawn in a unit square and filled with the even-odd rule, so the dots are
/// holes and the mark works as a template image in the menu bar.
struct AppMark: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let card = CGRect(x: rect.midX - side * 0.46, y: rect.midY - side * 0.33,
                          width: side * 0.92, height: side * 0.66)
        let radius = side * 0.13
        let fold = side * 0.2

        var path = Path()
        // The pass, clockwise from the top left, with the top right corner
        // cut off where it folds.
        path.move(to: CGPoint(x: card.minX + radius, y: card.minY))
        path.addLine(to: CGPoint(x: card.maxX - fold, y: card.minY))
        path.addLine(to: CGPoint(x: card.maxX, y: card.minY + fold))
        path.addLine(to: CGPoint(x: card.maxX, y: card.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: card.maxX - radius, y: card.maxY),
                          control: CGPoint(x: card.maxX, y: card.maxY))
        path.addLine(to: CGPoint(x: card.minX + radius, y: card.maxY))
        path.addQuadCurve(to: CGPoint(x: card.minX, y: card.maxY - radius),
                          control: CGPoint(x: card.minX, y: card.maxY))
        path.addLine(to: CGPoint(x: card.minX, y: card.minY + radius))
        path.addQuadCurve(to: CGPoint(x: card.minX + radius, y: card.minY),
                          control: CGPoint(x: card.minX, y: card.minY))
        path.closeSubpath()

        let dot = side * 0.13
        for step in [-1.0, 0.0, 1.0] {
            path.addEllipse(in: CGRect(x: card.midX + CGFloat(step) * side * 0.22 - dot / 2,
                                       y: card.midY + side * 0.04 - dot / 2,
                                       width: dot, height: dot))
        }
        return path
    }

    static let fill = FillStyle(eoFill: true)
}

/// A rounded square with a letter on it, for an item that has no icon of its
/// own, coloured from its title so it is the same tile on every launch.
struct LetterTile: View {
    let title: String
    let side: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: side * Metrics.iconCorner, style: .continuous)
            .fill(Palette.tile(for: title))
            .frame(width: side, height: side)
            .overlay(
                Text(LetterTile.letter(for: title))
                    .font(Fonts.tile(side))
                    .foregroundStyle(Palette.onColour)
            )
            .accessibilityHidden(true)
    }

    /// The first letter, capitalised the Turkish way: "iş" leads with İ.
    static func letter(for title: String) -> String {
        guard let first = title.trimmingCharacters(in: .whitespaces).first else { return "?" }
        return String(first).uppercased(with: Locale(identifier: "tr_TR"))
    }
}

/// A vault's small round mark, in the vault's own colour.
struct VaultDot: View {
    let name: String

    var body: some View {
        Circle()
            .fill(Palette.hue(for: name))
            .frame(width: Metrics.vaultDot, height: Metrics.vaultDot)
            .accessibilityHidden(true)
    }
}
