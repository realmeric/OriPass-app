import SwiftUI

/// Every size and weight the app sets, named by the thing it is used for, so
/// that a surface asks for a role and a change of mind about a size happens
/// in one line.
///
/// SF through `.system` (`docs/look.md`, "Colour and type").
enum Fonts {
    private static func system(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: Metrics.scaled(size), weight: weight)
    }

    /// Values, sidebar rows, menus: what most of the window is set in.
    static var body: Font { system(13) }

    /// A row's title in the item list, and anything that leads its line.
    static var rowTitle: Font { system(13, .medium) }

    /// A row's second line.
    static var rowSecond: Font { system(12) }

    /// An item's title in the details, at about twice the body.
    static var title: Font { system(24, .bold) }

    /// A field's label, above its value.
    static var label: Font { system(11) }

    /// VAULTS, MARCH 2025, SECURITY: small capitals over a group.
    static var heading: Font { system(10.5, .semibold) }

    /// "Copy" on a hovered row, a button's word.
    static var action: Font { system(12, .semibold) }

    /// The toolbar's chevrons and the magnifier in its field.
    static var toolbarGlyph: Font { system(14, .medium) }

    /// A sidebar row's mark.
    static var sidebarGlyph: Font { system(14) }

    /// The mark before the sentence at the sidebar's foot.
    static var footGlyph: Font { system(11, .medium) }

    /// The chevron beside the account and before VAULTS, and its plus.
    static var disclosure: Font { system(10.5, .semibold) }

    /// The star on an icon's corner, and the same shape a size up in the
    /// row's own ground behind it, which reads as an edge around the star.
    static var star: Font { system(11) }
    static var starEdge: Font { system(14.5) }

    /// The same pair on the details' large icon.
    static var detailStar: Font { system(17) }
    static var detailStarEdge: Font { system(22) }

    /// The dots a hidden value is drawn as: heavier than the text around
    /// them, so they read as covered and not as faint.
    static var dots: Font { system(13, .heavy) }

    /// The same dots in a form, where a secure field draws its own beside
    /// them: these are that field's bullets in size and, with
    /// `Metrics.formDotsTracking`, in step, measured in the shots.
    static var formDots: Font { system(21, .heavy) }

    /// A heading inside a note, the first level the largest and the fourth
    /// and after no larger than the text.
    static func noteHeading(_ level: Int) -> Font {
        switch level {
        case 1: return system(20, .bold)
        case 2: return system(17, .bold)
        case 3: return system(15, .semibold)
        default: return system(13, .semibold)
        }
    }

    /// A caption, a count, a key combination beside a menu row.
    static var caption: Font { system(11) }

    /// What is written on a key's cap in the table of keys.
    static var keycap: Font { system(11.5, .medium) }

    /// Anything that is read character by character: a one-time code, a
    /// revealed password, a fingerprint.
    static var code: Font { .system(size: Metrics.scaled(13), design: .monospaced) }

    /// A one-time code's digits: the body's face a point larger, as the
    /// still has them, with every digit as wide as the next, so the row
    /// does not shift as the code changes.
    static var codeDigits: Font { system(14).monospacedDigit() }

    /// The seconds a code has left, beside its ring.
    static var codeSeconds: Font { system(12).monospacedDigit() }

    /// The lock screen's field.
    static var lockField: Font { system(14) }

    /// The same, for the AppKit field that SwiftUI's font cannot be given to.
    static var lockFieldNative: NSFont { .systemFont(ofSize: Metrics.scaled(14)) }

    /// What the lock screen says when there is no field to show: no CLI,
    /// nobody signed in, an engine that failed.
    static var statement: Font { system(15, .semibold) }

    /// What is typed into the sheet behind ⌘N.
    static var newItemField: Font { system(16) }

    /// The title of the card over ssh, which stands under a large icon.
    static var question: Font { system(17, .bold) }

    /// A fingerprint on that card, on a line of its own that it has to fit.
    static var fingerprint: Font { .system(size: Metrics.scaled(11), design: .monospaced) }

    /// The email under the lock screen's mark, a sentence on an empty state.
    static var sentence: Font { system(13) }

    /// The letter on a tile, sized from the tile.
    static func tile(_ side: CGFloat) -> Font {
        .system(size: side * 0.5, weight: .semibold, design: .rounded)
    }

    /// The mark of a category on its tile, sized from the tile.
    static func tileMark(_ side: CGFloat) -> Font {
        .system(size: side * 0.5, weight: .medium)
    }

    /// Quick Access's field, large, for the AppKit field it is, and the
    /// magnifier before it. Neither follows the zoom (`Metrics.quickWidth`).
    static let quickField = NSFont.systemFont(ofSize: 20)
    static let quickGlyph = Font.system(size: 18, weight: .semibold)
    /// A result's title and the grey line after it, an action and its keys,
    /// an opened item's title, and the strip of hints.
    static let quickTitle = Font.system(size: 14, weight: .semibold)
    static let quickSecond = Font.system(size: 14)
    static let quickHeading = Font.system(size: 11.5, weight: .semibold)
    static let quickAction = Font.system(size: 14)
    static let quickKeys = Font.system(size: 13)
    static let quickHeader = Font.system(size: 15, weight: .bold)
    static let quickHint = Font.system(size: 12)
    static let quickKeycap = Font.system(size: 11.5, weight: .medium)
    static let quickMore = Font.system(size: 13, weight: .bold)

    /// The hot key recorder's words.
    static let recorder = NSFont.systemFont(ofSize: 12)

    /// Large Type's cells.
    static var largeType: Font { .system(size: 56, weight: .medium, design: .monospaced) }
    static var largeTypeIndex: Font { .system(size: 12, design: .monospaced) }

    /// Password Health's counts, the name under one, the name over the strength
    /// bar, and the mark beside the page's own name.
    static var count: Font { system(34, .bold) }
    static var cardTitle: Font { system(14, .bold) }
    static var pageHeading: Font { system(16, .bold) }
    static var pageMark: Font { system(22, .medium) }
}
