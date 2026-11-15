#!/usr/bin/env swift
//
// Draws the app icon into the asset catalogue. Run it when the mark changes:
//
//     make icon
//
// The mark is `AppMark`, the pass with one corner folded and three dots where
// a password would be, in the app's own blue on a tile of pale paper. A
// script cannot import the app, so the shape is written here a second time,
// in the same words as `Sources/Design/Glyphs.swift`, and `AppIconTests`
// reads the files back and holds them to the app's own path and colour.
//
// The colours are the other way round from the lock screen's white pass on a
// blue disc, and on purpose. Bitwarden's icon is a white shield on a blue
// tile, and on a black one where macOS draws icons dark; 1Password's is a
// blue ring round a keyhole. A white mark on blue or on black is the first
// of those at sixteen points, whatever the mark is. A solid blue block on
// paper is neither.
//
// Nothing here is traced from anybody, and nothing reads a file but the two
// it writes over.

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let catalogue = root.appendingPathComponent("Sources/Assets.xcassets")
let appIcon = catalogue.appendingPathComponent("AppIcon.appiconset")
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func colour(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [CGFloat((hex >> 16) & 0xFF) / 255,
                                           CGFloat((hex >> 8) & 0xFF) / 255,
                                           CGFloat(hex & 0xFF) / 255, alpha])!
}

/// The paper, lighter at the top, and the pass, which is `Palette.lit` as it
/// is in light: an icon has one appearance.
let paperTop = colour(0xFDFDFE)
let paperBottom = colour(0xE3E8F1)
let pass = colour(0x1A66E0)

/// The macOS grid: the tile is 824 of 1024 with the rest left clear, or the
/// icon stands larger than every one of its neighbours in the Dock.
let tileShare: CGFloat = 824.0 / 1024.0
let tileCorner: CGFloat = 0.2237
/// How much of the tile the mark's square takes. The pass is 0.92 of that
/// wide, so about seven tenths of the tile: a mark that is polite about the
/// margin is a speck at sixteen points, where most of the Dock lives.
let markShare: CGFloat = 0.78

/// The pass and its dots in a context whose y runs down, as SwiftUI's does.
struct Mark {
    var card: CGRect
    var radius: CGFloat
    var fold: CGFloat
    var dot: CGFloat
    /// From one dot's centre to the next.
    var pitch: CGFloat
    /// The dots' centre line.
    var line: CGFloat
    /// At sixteen pixels a dot is two by two of them, and a circle that
    /// size leaves a fifth of the blue showing in each.
    var hasSquareDots = false

    /// `AppMark.path(in:)`, share for share.
    init(in rect: CGRect) {
        let side = min(rect.width, rect.height)
        card = CGRect(x: rect.midX - side * 0.46, y: rect.midY - side * 0.33,
                      width: side * 0.92, height: side * 0.66)
        radius = side * 0.13
        fold = side * 0.2
        dot = side * 0.13
        pitch = side * 0.22
        line = card.midY + side * 0.04
    }

    /// The two smallest files, set on whole pixels by hand. Scaled down from
    /// the formula the dots are a pixel and a quarter across, and three of
    /// them are one grey band. Here each is two pixels with one between, and
    /// the pass is a little wider than its share to hold them.
    init?(pixels: Int) {
        switch pixels {
        case 16:
            card = CGRect(x: 3, y: 5, width: 10, height: 6)
            (radius, fold, dot, pitch, line) = (1.5, 2, 2, 3, 8)
            hasSquareDots = true
        case 32:
            card = CGRect(x: 6, y: 9, width: 20, height: 14)
            (radius, fold, dot, pitch, line) = (3, 4, 4, 6, 16.5)
        default:
            return nil
        }
    }

    var path: CGPath {
        let path = CGMutablePath()
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
        for step in [-1.0, 0.0, 1.0] {
            let hole = CGRect(x: card.midX + CGFloat(step) * pitch - dot / 2,
                              y: line - dot / 2, width: dot, height: dot)
            if hasSquareDots { path.addRect(hole) } else { path.addEllipse(in: hole) }
        }
        return path
    }
}

/// One file's worth, drawn at its own size and not scaled down from the
/// largest: an edge that falls where this size's pixels are.
func draw(pixels: Int) -> CGImage {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                            bytesPerRow: 0, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let side = CGFloat(pixels)
    // y down from here on.
    context.translateBy(x: 0, y: side)
    context.scaleBy(x: 1, y: -1)

    let inset = side * (1 - tileShare) / 2
    let tile = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let shape = CGPath(roundedRect: tile, cornerWidth: tile.width * tileCorner,
                       cornerHeight: tile.width * tileCorner, transform: nil)

    // The shadow every tile in the Dock stands on. Paper on a pale Dock has
    // no edge without it.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -side * 0.01), blur: side * 0.02,
                      color: colour(0x000000, alpha: 0.3))
    context.addPath(shape)
    context.setFillColor(paperBottom)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let paper = CGGradient(colorsSpace: sRGB, colors: [paperTop, paperBottom] as CFArray,
                           locations: [0, 1])!
    context.drawLinearGradient(paper, start: CGPoint(x: 0, y: tile.minY),
                               end: CGPoint(x: 0, y: tile.maxY), options: [])
    context.restoreGState()

    let room = tile.width * (1 - markShare) / 2
    let mark = Mark(pixels: pixels) ?? Mark(in: tile.insetBy(dx: room, dy: room))
    // Even-odd, as `AppMark.fill` is: the dots are holes and the paper shows
    // through them.
    context.addPath(mark.path)
    context.setFillColor(pass)
    context.fillPath(using: .evenOdd)
    return context.makeImage()!
}

func writeJSON(_ object: [String: Any], to url: URL) throws {
    try JSONSerialization
        .data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        .write(to: url)
}

// The ten sizes macOS asks for, as points and scales.
let sizes: [(point: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]

try FileManager.default.createDirectory(at: appIcon, withIntermediateDirectories: true)

var entries: [[String: String]] = []
for (point, scale) in sizes {
    let name = "icon_\(point)x\(point)\(scale == 2 ? "@2x" : "").png"
    let rep = NSBitmapImageRep(cgImage: draw(pixels: point * scale))
    // A point is `scale` pixels, which is what the file says of itself.
    rep.size = NSSize(width: point, height: point)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("make-icon: no PNG for \(name)\n".utf8))
        exit(1)
    }
    try png.write(to: appIcon.appendingPathComponent(name))
    entries.append(["size": "\(point)x\(point)", "idiom": "mac",
                    "filename": name, "scale": "\(scale)x"])
}
try writeJSON(["images": entries, "info": ["version": 1, "author": "xcode"]],
              to: appIcon.appendingPathComponent("Contents.json"))
try writeJSON(["info": ["version": 1, "author": "xcode"]],
              to: catalogue.appendingPathComponent("Contents.json"))

print("wrote \(sizes.count) app icon sizes")

// The iPhone's icon: one 1024 square, full bleed,
// since iOS cuts the corners itself, in the three looks iOS asks for: light,
// dark, and tinted, which iOS colours from the grey it is given.
let phoneIcon = root.appendingPathComponent("Phone/Sources/App/Assets.xcassets/AppIcon.appiconset")

func drawPhone(_ look: String) -> CGImage {
    let pixels = 1024
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                            bytesPerRow: 0, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let side = CGFloat(pixels)
    context.translateBy(x: 0, y: side)
    context.scaleBy(x: 1, y: -1)
    let square = CGRect(x: 0, y: 0, width: side, height: side)
    let (top, bottom, ink): (CGColor, CGColor, CGColor) = switch look {
    case "dark": (colour(0x2C2C2E), colour(0x111113), colour(0x4D8DF5))
    case "tinted": (colour(0x000000), colour(0x000000), colour(0xFFFFFF))
    default: (paperTop, paperBottom, pass)
    }
    let ground = CGGradient(colorsSpace: sRGB, colors: [top, bottom] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(ground, start: .zero, end: CGPoint(x: 0, y: side), options: [])
    let room = side * (1 - 0.62) / 2
    context.addPath(Mark(in: square.insetBy(dx: room, dy: room)).path)
    context.setFillColor(ink)
    context.fillPath(using: .evenOdd)
    return context.makeImage()!
}

try FileManager.default.createDirectory(at: phoneIcon, withIntermediateDirectories: true)
var phoneEntries: [[String: Any]] = []
for look in ["light", "dark", "tinted"] {
    let name = "phone-\(look).png"
    let rep = NSBitmapImageRep(cgImage: drawPhone(look))
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try png.write(to: phoneIcon.appendingPathComponent(name))
    var entry: [String: Any] = ["filename": name, "idiom": "universal", "platform": "ios", "size": "1024x1024"]
    if look != "light" { entry["appearances"] = [["appearance": "luminosity", "value": look]] }
    phoneEntries.append(entry)
}
try writeJSON(["images": phoneEntries, "info": ["version": 1, "author": "xcode"]],
              to: phoneIcon.appendingPathComponent("Contents.json"))
try writeJSON(["info": ["version": 1, "author": "xcode"]],
              to: phoneIcon.deletingLastPathComponent().appendingPathComponent("Contents.json"))
print("wrote the iPhone's icon in three looks")
