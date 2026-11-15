import AppKit
import SwiftUI
import XCTest
@testable import OriPass

@MainActor
final class GlyphTests: XCTestCase {
    private let sizes: [CGFloat] = [16, 32, 64]

    /// The rows of a rendered view that have anything on them.
    private func ink<V: View>(_ view: V, side: CGFloat) -> (bounds: CGRect, pixels: Int) {
        let renderer = ImageRenderer(content: view.frame(width: side, height: side))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return (.null, 0)
        }
        var bounds = CGRect.null
        var pixels = 0
        let alphaOffset = image.alphaInfo == .premultipliedFirst || image.alphaInfo == .first ? 0 : 3
        for y in 0..<image.height {
            for x in 0..<image.width where bytes[y * image.bytesPerRow + x * 4 + alphaOffset] > 8 {
                pixels += 1
                bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return (bounds, pixels)
    }

    func testEverySymbolExistsAndDrawsInsideItsRect() {
        for glyph in Glyph.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: glyph.symbol, accessibilityDescription: nil),
                            "\(glyph.rawValue) names no symbol: \(glyph.symbol)")
            for side in sizes {
                let drawn = ink(glyph.image.resizable().scaledToFit().foregroundStyle(.black), side: side)
                XCTAssertGreaterThan(drawn.pixels, 0, "\(glyph.rawValue) is empty at \(side)")
                XCTAssertTrue(CGRect(x: 0, y: 0, width: side * 2, height: side * 2).contains(drawn.bounds),
                              "\(glyph.rawValue) leaves its rect at \(side)")
            }
        }
    }

    func testTheMarkDrawsInsideItsRectAndItsDotsAreHoles() {
        for side in sizes {
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            let path = AppMark().path(in: rect)
            XCTAssertFalse(path.isEmpty)
            XCTAssertTrue(rect.contains(path.boundingRect), "the mark leaves its rect at \(side)")

            let drawn = ink(AppMark().fill(.black, style: AppMark.fill), side: side)
            XCTAssertGreaterThan(drawn.pixels, 0)
            // Even-odd: the middle dot is not ink.
            XCTAssertFalse(path.contains(CGPoint(x: rect.midX, y: rect.midY + side * 0.04), eoFill: true))
            XCTAssertTrue(path.contains(CGPoint(x: rect.midX, y: rect.midY - side * 0.2), eoFill: true))
        }
    }

    func testATileAndADotDraw() {
        for side in sizes {
            XCTAssertGreaterThan(ink(LetterTile(title: "İş Bankası", side: side), side: side).pixels, 0)
        }
        XCTAssertGreaterThan(ink(VaultDot(name: "Work"), side: 16).pixels, 0)
        XCTAssertEqual(LetterTile.letter(for: "iş bankası"), "İ")
        XCTAssertEqual(LetterTile.letter(for: "  spotify"), "S")
        XCTAssertEqual(LetterTile.letter(for: ""), "?")
    }

    func testEveryTypeHasAMark() {
        for type in [ItemType.login, .secureNote, .card, .identity, .sshKey, .unknown(9)] {
            XCTAssertNotNil(NSImage(systemSymbolName: Glyph.category(type).symbol,
                                    accessibilityDescription: nil))
        }
    }
}
