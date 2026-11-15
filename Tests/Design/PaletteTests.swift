import XCTest
@testable import OriPass

final class PaletteTests: XCTestCase {
    /// FNV-1a of "Work" is 11161871519290268064, worked out outside this app,
    /// and that modulo eight is 0. The index being a constant is the point:
    /// Swift's own `Hasher` is seeded afresh in every process.
    func testAVaultsColourIsTheSameInEveryProcess() {
        XCTAssertEqual(Palette.hueIndex(for: "Work"), 0)
        XCTAssertEqual(Palette.hueIndex(for: "Work"), Palette.hueIndex(for: "Work"))
        XCTAssertEqual(Palette.hue(for: "Work"), Palette.hues[0])
        // Turkish names hash by their bytes like any other.
        XCTAssertNotEqual(Palette.hueIndex(for: "İş"), Palette.hueIndex(for: "Is"))
    }

    func testEveryListIsAsLongAsWhatReadsIt() {
        XCTAssertEqual(Palette.strength.count, Strength.allCases.count)
        XCTAssertEqual(Palette.hues.count, 8)
        // A tile takes its vault's place in the list, in a deeper shade.
        XCTAssertEqual(Palette.tiles.count, Palette.hues.count)
        XCTAssertEqual(Palette.tile(for: "Work"), Palette.tiles[0])
    }
}
