import SwiftUI
import XCTest
@testable import OriPass

final class ContrastTests: XCTestCase {
    func testNoWordIsUnderFourAndAHalfToOneOnWhatItIsDrawnOn() {
        XCTAssertEqual(Palette.leastContrast, 4.5)
        XCTAssertEqual(Contrast.failures().map(\.said), [])
        // Both appearances of every reading were asked.
        let asked = Palette.readings.reduce(0) { $0 + $1.grounds.count }
        XCTAssertEqual(Contrast.lines().count, asked * 2)
        XCTAssertGreaterThan(asked, 80)
    }

    /// Black on white is 21 and a colour on itself is 1, which is WCAG's
    /// own two ends, and #767676 on white is the grey its documents give as
    /// the lightest that passes.
    func testTheRatioIsTheOneTheStandardWorksOut() {
        let white: Contrast.Parts = (1, 1, 1, 1)
        let black: Contrast.Parts = (0, 0, 0, 1)
        let grey: Contrast.Parts = (118.0 / 255, 118.0 / 255, 118.0 / 255, 1)
        XCTAssertEqual(Contrast.ratio(black, white), 21, accuracy: 0.001)
        XCTAssertEqual(Contrast.ratio(white, black), 21, accuracy: 0.001)
        XCTAssertEqual(Contrast.ratio(grey, grey), 1, accuracy: 0.001)
        XCTAssertEqual(Contrast.ratio(grey, white), 4.54, accuracy: 0.01)
    }

    func testAColourIsReadInTheAppearanceAskedForAndAVeilIsLaidOverItsGround() {
        let light = Contrast.parts(of: Palette.content, in: .aqua)
        let dark = Contrast.parts(of: Palette.content, in: .darkAqua)
        XCTAssertEqual(light.red, 1, accuracy: 0.002)
        XCTAssertEqual(dark.red, Double(0x1D) / 255, accuracy: 0.002)
        XCTAssertEqual(dark.blue, Double(0x1D) / 255, accuracy: 0.002)

        // A tenth of black over white is nine tenths of white.
        let veil: Contrast.Parts = (0, 0, 0, 0.1)
        let laid = Contrast.laid(veil, over: (1, 1, 1, 1))
        XCTAssertEqual(laid.green, 0.9, accuracy: 0.001)
        XCTAssertEqual(laid.alpha, 1)
    }

    /// The faint grey is in no reading because it would fail every one of
    /// them, which is what makes the list worth holding: the check is not
    /// one that passes whatever it is handed.
    func testTheFaintGreyWouldFailAsAWord() {
        for (name, appearance) in Contrast.appearances {
            let ink = Contrast.parts(of: Palette.faintText, in: appearance)
            let ground = Contrast.parts(of: Palette.field, in: appearance)
            XCTAssertLessThan(Contrast.ratio(ink, ground), Palette.leastContrast, name)
        }
    }

    /// Every colour in `Palette.swift` is in a reading or is named as one no
    /// word is drawn in or on, so a new colour cannot go unlooked at.
    func testEveryColourOfThePaletteIsInAReadingOrIsNamedAsUnread() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Design/Palette.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let declared = source.matches(of: /static let (\w+) = (?:dynamic\(|\[\s*dynamic\(|Color\.)/).map { String($0.1) }
        XCTAssertGreaterThan(declared.count, 45)
        XCTAssertTrue(declared.contains("onColour"))
        XCTAssertTrue(declared.contains("tiles"))

        let read = Set(Palette.readings.flatMap { [$0.ink.name] + $0.grounds.map(\.name) })
        for name in declared where !Palette.unread.contains(name) {
            XCTAssertTrue(read.contains { $0 == name || $0.hasPrefix(name + " ") || $0.hasPrefix(name + "[")
                    || $0.contains(" \(name) ") || $0.hasSuffix(" " + name) },
                          "\(name) is in no reading and is not in Palette.unread")
        }
        for name in Palette.unread {
            XCTAssertTrue(declared.contains(name), "\(name) is in Palette.unread and is no colour of the palette")
            XCTAssertFalse(read.contains(name), "\(name) is in a reading and in Palette.unread")
        }
    }
}
