import AppKit
import SwiftUI
import XCTest
@testable import OriPass

/// Compact: what it tightens, what it leaves, and how the choice in the
/// Appearance room reaches `Metrics`.
@MainActor
final class DensityTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() async throws {
        Metrics.density = .comfortable
        Metrics.zoom = Zoom.actual.factor
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
    }

    private func door() -> Door {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oripass-density-\(UUID().uuidString)")
        directories.append(directory)
        return Door(store: VaultStore(backend: DemoVault.backend()),
                    seal: PasswordSeal(directory: directory, enclave: FakeEnclave()))
    }

    private func turn() async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    private var rows: [CGFloat] {
        [Metrics.sidebarRow, Metrics.listRow, Metrics.listHeading, Metrics.listHeader, Metrics.menuRow,
         Metrics.itemMenuRow, Metrics.fieldRow, Metrics.historyRow, Metrics.keyRow, Metrics.generatorRow,
         Metrics.settingsRow, Metrics.cardFooter]
    }

    private var rooms: [CGFloat] { [Metrics.gap, Metrics.wide, Metrics.loose, Metrics.apart] }

    /// What is in a row and is not the row: the small paddings, the icons,
    /// the controls and the corners.
    private var kept: [CGFloat] {
        [Metrics.hair, Metrics.tight, Metrics.close, Metrics.listIcon, Metrics.detailIcon, Metrics.sidebarMark,
         Metrics.buttonHeight, Metrics.searchHeight, Metrics.switchSize.height, Metrics.recorder.height,
         Metrics.keycap, Metrics.rowRadius, Metrics.groupRadius, Metrics.toolbarHeight, Metrics.sidebarWidth,
         Metrics.quickRow]
    }

    func testCompactTightensEveryRowAndEveryPaddingThatGivesWayAndNothingElse() {
        let comfortable = (rows: rows, rooms: rooms, kept: kept)
        XCTAssertEqual(comfortable.rows, [34, 50, 38, 44, 30, 32, 48, 56, 30, 34, 34, 40])
        XCTAssertEqual(comfortable.rooms, [12, 16, 24, 32])

        Metrics.density = .compact
        XCTAssertEqual(rows, [29, 42, 32, 37, 25, 27, 40, 47, 25, 29, 29, 34])
        XCTAssertEqual(rooms, [9, 12, 18, 24])
        XCTAssertEqual(kept, comfortable.kept)
        for (tight, loose) in zip(rows, comfortable.rows) { XCTAssertLessThan(tight, loose) }
    }

    /// What has to stay inside a row still does: the list's icon and its two
    /// lines, a field's label over its value, a control in a row of the
    /// settings and a key's cap in a row of the table.
    func testWhatIsDrawnInARowStillFitsInItAtEverySize() {
        Metrics.density = .compact
        for size in Zoom.allCases {
            Metrics.zoom = size.factor
            // `Fonts.body` and `Fonts.label`, which are thirteen and eleven.
            let line = { (font: NSFont) in NSLayoutManager().defaultLineHeight(for: font) }
            let body = line(.systemFont(ofSize: Metrics.scaled(13)))
            let small = line(.systemFont(ofSize: Metrics.scaled(11)))
            XCTAssertGreaterThanOrEqual(Metrics.listRow, Metrics.listIcon + 2 * Metrics.tight, "\(size)")
            XCTAssertGreaterThanOrEqual(Metrics.listRow, 2 * body, "\(size)")
            XCTAssertGreaterThanOrEqual(Metrics.fieldRow, body + small + Metrics.tight, "\(size)")
            XCTAssertGreaterThanOrEqual(Metrics.settingsRow, Metrics.recorder.height, "\(size)")
            XCTAssertGreaterThanOrEqual(Metrics.settingsRow, Metrics.buttonHeight, "\(size)")
            XCTAssertGreaterThanOrEqual(Metrics.generatorRow, Metrics.switchSize.height, "\(size)")
            XCTAssertGreaterThanOrEqual(Metrics.keyRow, Metrics.keycap, "\(size)")
            XCTAssertGreaterThanOrEqual(Metrics.menuRow, body, "\(size)")
        }
    }

    func testTheDoorTakesADensityOnceAndSaysSoToAWindowThatIsNotItsOwn() {
        let door = door()
        var posted = 0
        let watching = NotificationCenter.default.addObserver(forName: Density.didChange, object: nil,
                                                              queue: nil) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(watching) }

        door.density(to: .compact)
        XCTAssertEqual(door.density, .compact)
        XCTAssertEqual(Metrics.density, .compact)
        XCTAssertEqual(posted, 1)
        door.density(to: .compact)
        XCTAssertEqual(posted, 1, "the same density is no change")

        door.density(to: .comfortable)
        XCTAssertEqual(Metrics.density, .comfortable)
        XCTAssertEqual(posted, 2)
    }

    /// The row in the Appearance room writes `look.density` and nothing
    /// else. `Following` is what carries it to the door, at the start as
    /// well as at a change.
    func testTheChoiceInTheSettingsReachesTheDoorAtTheStartAndWhenItMoves() async {
        let door = door()
        door.preferences.settings.look.density = .compact
        let following = Following(door.preferences, hands: .init(setDensity: { door.density(to: $0) }))
        await turn()
        XCTAssertEqual(door.density, .compact, "as the app starts")
        XCTAssertEqual(Metrics.listRow, 42)

        door.preferences.settings.look.density = .comfortable
        await turn()
        XCTAssertEqual(door.density, .comfortable)
        XCTAssertEqual(Metrics.listRow, 50)

        // Another choice moving leaves it where it is.
        door.density(to: .compact)
        door.preferences.settings.look.theme = .dark
        await turn()
        XCTAssertEqual(door.density, .compact)
        _ = following
    }
}
