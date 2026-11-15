import AppKit
import SwiftUI
import XCTest
@testable import OriPass

@MainActor
final class LargeTypeTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

    func testEveryCharacterHasItsPlaceAndItsKind() {
        let cells = LargeType("CANARY-1").cells
        XCTAssertEqual(cells.map(\.id), Array(1...8))
        XCTAssertEqual(String(cells.map(\.character)), "CANARY-1")
        XCTAssertEqual(cells.map(\.kind), [.letter, .letter, .letter, .letter, .letter, .letter, .symbol, .digit])
        XCTAssertEqual(LargeType("ş 7_").cells.map(\.kind), [.letter, .blank, .digit, .symbol])
    }

    func testALongValueTakesAsManyLinesAsItNeeds() {
        let long = LargeType(String(repeating: "ab1!", count: 10))
        let lines = long.lines(of: 16)
        XCTAssertEqual(lines.map(\.count), [16, 16, 8])
        XCTAssertEqual(lines.last?.last?.id, 40, "the count runs on from line to line")

        let fit = long.fit(width: Metrics.largeTypeCell.width * 16 + Metrics.largeTypePad * 2, height: 2_000)
        XCTAssertEqual(fit.perLine, 16)
        XCTAssertEqual(fit.size.height, Metrics.largeTypeCell.height * 3 + Metrics.largeTypePad * 2)
        XCTAssertEqual(LargeType("abc").fit(width: 2_000, height: 2_000).perLine, 3, "no wider than the value")
        XCTAssertEqual(long.fit(width: 2_000, height: 120).size.height, 120, "and no taller than it is let")
    }

    func testItSaysNothingOfWhatItHolds() {
        let large = LargeType("CANARY-1", row: "password")
        XCTAssertEqual("\(large)", "LargeType(password)")
        XCTAssertFalse(String(reflecting: large).contains("CANARY"))
        var dumped = ""
        dump(large, to: &dumped)
        XCTAssertFalse(dumped.contains("CANARY"), dumped)
    }

    // MARK: The panel, made and never ordered in

    private func key(_ code: UInt16, in panel: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: panel.windowNumber, context: nil, characters: "",
                                       charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }

    func testThePanelSpellsTheValueOutInTheMiddleOfTheScreen() throws {
        let panel = LargeTypePanel.make(LargeType("CANARY-1"), within: screen) {}
        panel.layoutIfNeeded()

        XCTAssertEqual(panel.frame.midX, screen.midX, accuracy: 1)
        XCTAssertEqual(panel.frame.midY, screen.midY, accuracy: 1)
        XCTAssertEqual(panel.frame.width, Metrics.largeTypeCell.width * 8 + Metrics.largeTypePad * 2)
        XCTAssertTrue(panel.canBecomeKey, "or Esc would never reach it")
        XCTAssertFalse(panel.isRestorable)
        XCTAssertTrue(said(in: panel.contentView).contains("CANARY-1"), "\(said(in: panel.contentView))")
    }

    func testEscAndAClickEachPutItAway() throws {
        var dismissals = 0
        let panel = LargeTypePanel.make(LargeType("CANARY-1"), within: screen) { dismissals += 1 }

        panel.sendEvent(try key(0, in: panel))
        XCTAssertEqual(dismissals, 0, "any other key is not Esc")
        panel.sendEvent(try key(53, in: panel))
        XCTAssertEqual(dismissals, 1)

        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 30, y: 30),
                                                     modifierFlags: [], timestamp: 0,
                                                     windowNumber: panel.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1))
        panel.sendEvent(click)
        XCTAssertEqual(dismissals, 2)

        panel.cancelOperation(nil)
        panel.resignKey()
        XCTAssertEqual(dismissals, 4, "and so do the system's own cancel and losing the keys")
    }
}
