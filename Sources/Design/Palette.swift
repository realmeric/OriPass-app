import AppKit
import SwiftUI

/// Every colour the app draws, once, in light and in dark.
///
/// The rule the rest of the code obeys: a colour literal in a view is a bug,
/// and `DesignLiteralTests` reads the sources to hold it. A surface that
/// needs a shade that is not here needs a name here first. The values are
/// chosen by eye beside the stills and are this app's own (`docs/look.md`,
/// "Colour and type").
enum Palette {
    // MARK: - Surfaces

    /// The item list and the details. In dark a near-black with no blue in
    /// it, as `opm8-dark-mode.png` has it.
    static let content = dynamic(light: 0xFFFFFF, dark: 0x1D1D1D)

    /// The sidebar, a shade greyer than the rest in light and a blue slate
    /// in dark. Laid over the sidebar material as a veil, so the dark half
    /// is bluer and deeper here than it is drawn: over the material's grey
    /// in a shot it comes out near 22 29 36.
    static let sidebar = dynamic(light: 0xEEF0F3, dark: 0x1C2A42)

    /// How much of that grey is laid over the material. The rest is the
    /// material's own, and with it the desktop's tint.
    static let sidebarVeil: Double = 0.55

    /// The lines between a group's rows, under the toolbar and under the
    /// account.
    static let hairline = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.12)

    /// The line between two columns. In dark it is darker than either side
    /// of it, where every other line is lighter than its ground.
    static let divider = dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.10, darkAlpha: 0.75)

    /// The rounded outline around a details pane's first group of fields.
    static let outline = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.14, darkAlpha: 0.16)

    /// The selected row in the sidebar: a pale blue-grey, and in dark a blue
    /// with far more colour in it than the slate it lies on.
    static let sidebarSelection = dynamic(light: 0xD5DDEA, dark: 0x27416C)

    /// The selected row in the item list: a pale grey.
    static let listSelection = dynamic(light: 0xE6E8EC, dark: 0x323232)

    /// A menu dropped over the window, and what falls under it.
    static let menu = dynamic(light: 0xFFFFFF, dark: 0x292929)
    static let shadow = dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.16, darkAlpha: 0.45)

    /// A shot's stand-in for the fingerprint the system draws on the card
    /// over ssh, near the system's own colour.
    static let fingerStandIn = dynamic(light: 0xC2315F, dark: 0xD84B79)

    /// A field's row under the pointer.
    static let rowHover = dynamic(light: 0xF1F2F4, dark: 0x2A2A2A)

    /// The square at a hovered row's right end, a shade under the row.
    static let rowButton = dynamic(light: 0xDDDFE4, dark: 0x3C3C3C)

    /// Every other cell of Large Type, so the eye keeps its place.
    static let cell = dynamic(light: 0xF1F2F4, dark: 0x323232)

    /// Password Health's page, and a card on it: the card is the lighter of the
    /// two in both appearances.
    static let page = dynamic(light: 0xF4F5F7, dark: 0x1D1D1D)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x292929)
    /// How much of its colour a card's drawing is given, and how much of
    /// the red a card with something on it is washed with from its top.
    static let drawing: Double = 0.45
    static let wash: Double = 0.06

    /// A window with no ground of its own, for AppKit to be told.
    static let none = NSColor.clear

    /// What a template image is drawn in: only its shape counts, and the
    /// menu bar colours it for the bar it is on.
    static let templateInk = NSColor.black

    /// The strip the mark is drawn on in a shot, and the square that lights
    /// behind the mark while its menu is open.
    static let statusBar = dynamic(light: 0xE9EAEE, dark: 0x0C1124)
    static let statusLit = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.14, darkAlpha: 0.18)

    /// The hot key recorder while it is listening: the accent, faintly.
    static let recording = dynamic(light: 0x1A66E0, dark: 0x4C93FF, lightAlpha: 0.18, darkAlpha: 0.18)

    /// A text field's own ground: the lock screen's, the search field's.
    static let field = dynamic(light: 0xF4F5F7, dark: 0x292929)

    /// A ground sunk into a card that is itself `menu` or `card`: the
    /// generator's password, the track under its three kinds, and the
    /// track of Password Health's strength bar. In light it is
    /// `field`. In dark `field` is the card's own colour, so this is the
    /// content's, a shade under the card.
    static let well = dynamic(light: 0xF4F5F7, dark: 0x1D1D1D)

    /// The toolbar's search field, at rest: the content's own ground inside
    /// an outline, and in dark a shade under the content.
    static let searchField = dynamic(light: 0xFFFFFF, dark: 0x161616)

    /// Quick Access: a grey panel with a little of what is behind it let
    /// through, and the field lighter than the panel in both appearances.
    static let quickGround = dynamic(light: 0xDCDDE0, dark: 0x262626)
    static let quickVeil: Double = 0.82
    static let quickField = dynamic(light: 0xF4F4F5, dark: 0x343434)
    /// The square beside the selected result, and a key's cap.
    static let quickMore = dynamic(light: 0xCDCED3, dark: 0x3F3F3F)
    static let quickKeycap = dynamic(light: 0xEDEDEF, dark: 0x3A3A3A)
    /// The strip at the panel's foot, a shade darker than the panel.
    static let quickFooter = dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.05, darkAlpha: 0.22)
    /// The grey line of a result on the selection, where grey would not
    /// read: white, with as much let through as still leaves it 4.5 to 1.
    static let quickOnSelection: Double = 0.9

    /// The lock screen: a pale ground with the field lighter than it, the
    /// other way round from the window behind it (`docs/look.md`, "The lock
    /// screen").
    static let lockGround = dynamic(light: 0xF4F5F7, dark: 0x1D1D1D)
    static let lockField = dynamic(light: 0xFFFFFF, dark: 0x292929)

    /// The ring around a field that has the keys: the accent, let through.
    static let focusRing = dynamic(light: 0x1A66E0, dark: 0x4C93FF, lightAlpha: 0.38, darkAlpha: 0.5)

    /// How much of a control is left when it cannot be used, and when it is
    /// held down.
    static let disabled: Double = 0.5
    static let pressed: Double = 0.8

    /// What a sheet over the lock screen dims the window with.
    static let scrim = dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.35, darkAlpha: 0.5)

    // MARK: - Text

    /// Titles, values, anything being read.
    static let text = dynamic(light: 0x1B1C1F, dark: 0xF2F3F5)

    /// A row's second line, a caption, a heading in small capitals. Dark
    /// enough in light, and light enough in dark, to be read on a selected
    /// row and on Quick Access's grey as well as on the content.
    static let secondText = dynamic(light: 0x565960, dark: 0xAEAEAE)

    /// A field's placeholder and a word that stands where a value is not:
    /// the faintest a word is drawn, which is 4.5 to 1 on a field.
    static let prompt = dynamic(light: 0x6C6F76, dark: 0x9E9E9E)

    /// A glyph at rest and a control that cannot be used. Never a word:
    /// it does not reach 4.5 to 1 on anything (`Palette.readings`).
    static let faintText = dynamic(light: 0x8D9199, dark: 0x7F7F7F)

    /// Words and glyphs on `lit`, on `redLit` and on a tile.
    static let onColour = Color.white

    // MARK: - Meaning

    /// Links, ticks, a glyph that is on, and the focus ring.
    static let accent = dynamic(light: 0x1A66E0, dark: 0x5A9CFF)

    /// The accent with white on it: the New Item button, a menu's lit row,
    /// Quick Access's selected one, a category's tile, the mark's disc. In
    /// dark the accent is too light to carry white, so this is deeper.
    static let lit = dynamic(light: 0x1A66E0, dark: 0x2A66D2)

    /// The band a toast's drawing stands on, in `Extension/style.css`.
    static let toastBand = dynamic(light: 0xE8F0FC, dark: 0x1E2F4E)
    /// How much of `good` that band takes from `menu` once a login is saved.
    static let savedWash: Double = 0.12

    /// A field's label, a more violet blue than the accent.
    static let label = dynamic(light: 0x5552CC, dark: 0xA3A1FF)

    /// Delete, a refusal, and a Password Health card that needs attention. A brick
    /// red.
    static let red = dynamic(light: 0xAC3729, dark: 0xEC7566)

    /// The red with a word in white on it: the button that deletes for
    /// good.
    static let redLit = dynamic(light: 0xAC3729, dark: 0xC0392B)

    /// A word that says something is as it should be: "Allowed".
    static let good = dynamic(light: 0x1F7A3F, dark: 0x4CBF73)

    /// The favourite's star. A warm yellow.
    static let star = dynamic(light: 0xF2B526, dark: 0xF7C548)

    /// Large Type draws digits and symbols apart from letters.
    static let digit = dynamic(light: 0x1A66E0, dark: 0x6BA6FF)
    static let symbol = dynamic(light: 0xB23A2C, dark: 0xF08A7C)

    /// The five levels of a password's strength, weakest first.
    static let strength = [
        dynamic(light: 0xC2402F, dark: 0xE8695A),
        dynamic(light: 0xD9822B, dark: 0xF0A04B),
        dynamic(light: 0xD4B21F, dark: 0xE8CB4A),
        dynamic(light: 0x79B84A, dark: 0x93CF66),
        dynamic(light: 0x2C9A52, dark: 0x4CBF73),
    ]

    /// The ring of a one-time code with time ahead of it, which is the
    /// strongest level's green.
    static let codeRing = dynamic(light: 0x2C9A52, dark: 0x4CBF73)

    // MARK: - Vaults and tiles

    /// What a vault's dot is coloured from, and a tile's ground. Eight, far
    /// enough apart to tell two vaults from each other at the size of a dot.
    static let hues = [
        dynamic(light: 0x2F6FDE, dark: 0x5B93F0), dynamic(light: 0x2C9A8F, dark: 0x4FBFB3),
        dynamic(light: 0x4E9A3A, dark: 0x74BF5E), dynamic(light: 0xC9952B, dark: 0xE0B14E),
        dynamic(light: 0xD4682E, dark: 0xEA8A54), dynamic(light: 0xC2456B, dark: 0xE06C90),
        dynamic(light: 0x8A55C7, dark: 0xA97DE0), dynamic(light: 0x5A6577, dark: 0x8792A6),
    ]

    /// A lettered tile's ground: the same eight, each deep enough for the
    /// white letter on it, and the same in both appearances.
    static let tiles = [
        dynamic(light: 0x2B66D0, dark: 0x2B66D0), dynamic(light: 0x1E7D74, dark: 0x1E7D74),
        dynamic(light: 0x3F7F2F, dark: 0x3F7F2F), dynamic(light: 0x94690F, dark: 0x94690F),
        dynamic(light: 0xB4521C, dark: 0xB4521C), dynamic(light: 0xBA3F64, dark: 0xBA3F64),
        dynamic(light: 0x8A55C7, dark: 0x8A55C7), dynamic(light: 0x5A6577, dark: 0x5A6577),
    ]

    static func tile(for name: String) -> Color {
        tiles[hueIndex(for: name)]
    }

    /// The same colour for the same name on every launch, without storing
    /// anything: FNV-1a over the name's bytes, since Swift's own `Hasher` is
    /// seeded afresh in every process.
    static func hue(for name: String) -> Color {
        hues[hueIndex(for: name)]
    }

    static func hueIndex(for name: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int(hash % UInt64(hues.count))
    }

    // MARK: - As drawn

    /// The sidebar and Quick Access are veils over a material, so neither
    /// is the colour it is given. These are what the two come to in a shot,
    /// where nothing is behind the material, read from `window-empty` and
    /// `quick-access-actions`. They are what a word on either is measured
    /// against (`Palette.readings`); over a desktop the ground moves a
    /// little towards whatever is behind it.
    static let sidebarDrawn = dynamic(light: 0xEFF0F1, dark: 0x222936)
    static let quickDrawn = dynamic(light: 0xDBDBDD, dark: 0x2B2B2B)

    // MARK: -

    private static func dynamic(light: UInt32, dark: UInt32, lightAlpha: Double = 1,
                                darkAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return nsColor(isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    static func nsColor(_ hex: UInt32, alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
