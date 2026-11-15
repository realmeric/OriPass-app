import AppKit
import SwiftUI

extension Palette {
    /// A colour under the name it has in `Palette`, and what it is laid
    /// over when it lets some of that through.
    struct Shade {
        let name: String
        let colour: Color
        var under: Color?

        init(_ name: String, _ colour: Color, over under: Color? = nil) {
            self.name = name
            self.colour = colour
            self.under = under
        }
    }

    /// One colour words are drawn in, and every ground they are drawn on.
    struct Reading {
        let ink: Shade
        let grounds: [Shade]

        init(_ ink: Shade, on grounds: [Shade]) {
            self.ink = ink
            self.grounds = grounds
        }
    }

    /// The least a word may stand out from its ground: WCAG's figure for
    /// text of an ordinary size.
    static let leastContrast = 4.5

    /// Every word the app draws, by its colour and its ground. This is the
    /// list `make contrast` and `ContrastTests` hold to `leastContrast`, in
    /// light and in dark. A view that puts a colour's words on a ground
    /// that is not beside it here adds the ground here first.
    ///
    /// Words and not glyphs: a chevron, a tick and a tile's mark are not in
    /// it, and neither is a control at `Palette.disabled`, which is faint
    /// to say that it cannot be used.
    static let readings: [Reading] = {
        let content = Shade("content", Palette.content)
        let sidebar = Shade("sidebarDrawn", Palette.sidebarDrawn)
        let sidebarSelection = Shade("sidebarSelection", Palette.sidebarSelection)
        let listSelection = Shade("listSelection", Palette.listSelection)
        let menu = Shade("menu", Palette.menu)
        let rowHover = Shade("rowHover", Palette.rowHover)
        let rowButton = Shade("rowButton", Palette.rowButton)
        let cell = Shade("cell", Palette.cell)
        let page = Shade("page", Palette.page)
        let card = Shade("card", Palette.card)
        // A Password Health card with something on it, at its top where the wash
        // is whole, and a banner over the details.
        let washedCard = Shade("red at wash over card", Palette.red.opacity(Palette.wash), over: Palette.card)
        let banner = Shade("red at wash over content", Palette.red.opacity(Palette.wash), over: Palette.content)
        let field = Shade("field", Palette.field)
        let well = Shade("well", Palette.well)
        let searchField = Shade("searchField", Palette.searchField)
        let recording = Shade("recording over field", Palette.recording, over: Palette.field)
        let quick = Shade("quickDrawn", Palette.quickDrawn)
        let quickFooter = Shade("quickFooter over quickDrawn", Palette.quickFooter, over: Palette.quickDrawn)
        let quickField = Shade("quickField", Palette.quickField)
        let quickKeycap = Shade("quickKeycap", Palette.quickKeycap)
        let lockGround = Shade("lockGround", Palette.lockGround)
        let lockField = Shade("lockField", Palette.lockField)
        let lit = Shade("lit", Palette.lit)
        let toastBand = Shade("toastBand", Palette.toastBand)
        let savedBand = Shade("good at savedWash over menu", Palette.good.opacity(Palette.savedWash), over: Palette.menu)

        return [
            Reading(Shade("text", Palette.text), on: [
                content, sidebar, sidebarSelection, listSelection, menu, rowHover, rowButton, cell, page, card,
                washedCard, banner, field, well, searchField, recording, quick, quickFooter, quickField,
                quickKeycap, lockGround, lockField, toastBand, savedBand,
            ]),
            Reading(Shade("secondText", Palette.secondText), on: [
                content, sidebar, sidebarSelection, listSelection, menu, rowHover, cell, page, card, washedCard,
                banner, field, well, searchField, quick, quickFooter, quickField, quickKeycap, lockGround,
                lockField,
            ]),
            Reading(Shade("prompt", Palette.prompt), on: [
                content, menu, field, well, searchField, quickField, lockField,
            ]),
            Reading(Shade("accent", Palette.accent), on: [
                content, rowHover, menu, card, washedCard, lockGround, lockField,
            ]),
            Reading(Shade("label", Palette.label), on: [content, rowHover, menu]),
            Reading(Shade("red", Palette.red), on: [content, rowHover, menu, field, well, quick, lockGround]),
            Reading(Shade("good", Palette.good), on: [content]),
            Reading(Shade("digit", Palette.digit), on: [content, rowHover, cell, menu, field, well]),
            Reading(Shade("symbol", Palette.symbol), on: [content, rowHover, cell, menu, field, well]),
            Reading(Shade("onColour", Palette.onColour), on: [lit, Shade("redLit", Palette.redLit)]
                + Palette.tiles.enumerated().map { Shade("tiles[\($0.offset)]", $0.element) }),
            Reading(Shade("onColour at quickOnSelection", Palette.onColour.opacity(Palette.quickOnSelection)),
                    on: [lit]),
        ]
    }()

    /// The colours no word is drawn in or on: lines, rings, shadows, marks,
    /// and the two veils, whose drawn values stand in for them above.
    /// `ContrastTests` reads `Palette.swift` and fails on a colour that is
    /// neither here nor in `readings`, so a new one is put in one of them.
    static let unread: Set<String> = [
        "sidebar", "fingerStandIn", "quickGround", "hairline", "divider", "outline", "shadow", "scrim", "focusRing", "statusBar",
        "statusLit", "quickMore", "faintText", "star", "strength", "codeRing", "hues",
    ]
}

/// How far each word stands out from what it is drawn on, worked out from
/// `Palette.readings` the way WCAG 2 does it. `OP_DEMO=contrast`, behind
/// `make contrast`, prints every line and fails on one under
/// `Palette.leastContrast`; a test holds the same.
enum Contrast {
    struct Line: Equatable {
        let ink: String
        let ground: String
        let appearance: String
        let ratio: Double

        var said: String {
            "\(String(format: "%.2f", ratio)) \(appearance) \(ink) on \(ground)"
        }
    }

    /// Red, green and blue in sRGB, and how much of them there is.
    typealias Parts = (red: Double, green: Double, blue: Double, alpha: Double)

    static let appearances: [(name: String, appearance: NSAppearance.Name)] = [
        ("light", .aqua), ("dark", .darkAqua),
    ]

    /// Every reading in both appearances, the least first.
    static func lines() -> [Line] {
        var lines: [Line] = []
        for (name, appearance) in appearances {
            for reading in Palette.readings {
                for ground in reading.grounds {
                    let under = ground.under.map { parts(of: $0, in: appearance) }
                    let behind = laid(parts(of: ground.colour, in: appearance), over: under)
                    let ink = laid(parts(of: reading.ink.colour, in: appearance), over: behind)
                    lines.append(Line(ink: reading.ink.name, ground: ground.name, appearance: name,
                                      ratio: ratio(ink, behind)))
                }
            }
        }
        return lines.sorted { $0.ratio < $1.ratio }
    }

    static func failures() -> [Line] {
        lines().filter { $0.ratio < Palette.leastContrast }
    }

    /// A dynamic colour as one appearance has it.
    static func parts(of colour: Color, in appearance: NSAppearance.Name) -> Parts {
        var found: Parts = (0, 0, 0, 1)
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            guard let colour = NSColor(colour).usingColorSpace(.sRGB) else { return }
            found = (colour.redComponent, colour.greenComponent, colour.blueComponent, colour.alphaComponent)
        }
        return found
    }

    /// `top` with what shows through it, as one opaque colour.
    static func laid(_ top: Parts, over under: Parts?) -> Parts {
        guard let under, top.alpha < 1 else { return (top.red, top.green, top.blue, 1) }
        func mixed(_ over: Double, _ below: Double) -> Double { over * top.alpha + below * (1 - top.alpha) }
        return (mixed(top.red, under.red), mixed(top.green, under.green), mixed(top.blue, under.blue), 1)
    }

    /// WCAG 2's relative luminance.
    static func luminance(_ colour: Parts) -> Double {
        func linear(_ part: Double) -> Double {
            part <= 0.04045 ? part / 12.92 : pow((part + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(colour.red) + 0.7152 * linear(colour.green) + 0.0722 * linear(colour.blue)
    }

    static func ratio(_ one: Parts, _ other: Parts) -> Double {
        let lighter = max(luminance(one), luminance(other))
        let darker = min(luminance(one), luminance(other))
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// `OP_DEMO=contrast`: every line, then out, with a status `make
    /// contrast` can fail on.
    static func run() -> Never {
        let lines = lines()
        for line in lines {
            Demo.say("contrast: \(line.ratio < Palette.leastContrast ? "UNDER " : "")\(line.said)")
        }
        let under = lines.filter { $0.ratio < Palette.leastContrast }.count
        Demo.say("contrast: \(lines.count) readings, \(under) under \(Palette.leastContrast) to 1")
        exit(under == 0 ? 0 : 1)
    }
}
