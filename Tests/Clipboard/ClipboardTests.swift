import AppKit
import XCTest
@testable import OriPass

/// On a pasteboard of the test's own, made under a name nobody else has and
/// released when the test is over. The general one is never touched.
@MainActor
final class ClipboardTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("oripass-test-\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
    }

    private var timers: [String] {
        Instruments.live.filter { $0.owner == "Clipboard" }.map(\.name)
    }

    func testACopyCarriesTheValueAndTheMarker() {
        let clipboard = Clipboard(pasteboard: pasteboard)
        clipboard.copy("CANARY-1")

        XCTAssertEqual(pasteboard.string(forType: .string), "CANARY-1")
        XCTAssertEqual(Clipboard.concealed.rawValue, "org.nspasteboard.ConcealedType")
        XCTAssertTrue(pasteboard.types?.contains(Clipboard.concealed) == true, "\(pasteboard.types ?? [])")
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1, "the string and the marker are one item")
        XCTAssertTrue(clipboard.isHolding)
        XCTAssertEqual(timers, ["clear"])
    }

    func testTheValueIsGoneAfterTheDelay() async {
        let clipboard = Clipboard(pasteboard: pasteboard, delay: 0.1)
        clipboard.copy("CANARY-1")
        XCTAssertEqual(pasteboard.string(forType: .string), "CANARY-1")

        await clipboard.clearing?.value

        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertEqual(pasteboard.types ?? [], [])
        XCTAssertFalse(clipboard.isHolding)
        XCTAssertEqual(timers, [], "the wait is over and nothing is left ticking")
    }

    func testItIsNotGoneWhenSomethingElseWasCopiedInBetween() async {
        let clipboard = Clipboard(pasteboard: pasteboard, delay: 0.1)
        clipboard.copy("CANARY-1")
        let waiting = clipboard.clearing

        // Another app's copy, which is not this app's to remove.
        pasteboard.clearContents()
        pasteboard.setString("a shopping list", forType: .string)
        XCTAssertFalse(clipboard.isHolding)
        await waiting?.value

        XCTAssertEqual(pasteboard.string(forType: .string), "a shopping list")
        XCTAssertEqual(timers, [])
    }

    func testASecondCopyStartsTheWaitAgain() async throws {
        let clipboard = Clipboard(pasteboard: pasteboard, delay: 0.3)
        clipboard.copy("CANARY-1")
        try await Task.sleep(nanoseconds: 200_000_000)
        clipboard.copy("CANARY-2")
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(pasteboard.string(forType: .string), "CANARY-2", "the first copy's wait cleared the second")
        await clipboard.clearing?.value
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testClearingByHandTakesOnlyWhatIsItsOwn() {
        let clipboard = Clipboard(pasteboard: pasteboard)
        clipboard.copy("CANARY-1")
        XCTAssertTrue(clipboard.clear())
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertEqual(timers, [])
        XCTAssertFalse(clipboard.clear(), "there is nothing of its own left to clear")

        clipboard.copy("CANARY-1")
        pasteboard.clearContents()
        pasteboard.setString("a shopping list", forType: .string)
        XCTAssertFalse(clipboard.clear())
        XCTAssertEqual(pasteboard.string(forType: .string), "a shopping list")
    }

    func testDroppingItStopsTheWait() {
        var clipboard: Clipboard? = Clipboard(pasteboard: pasteboard)
        clipboard?.copy("CANARY-1")
        XCTAssertEqual(timers, ["clear"])

        clipboard = nil

        XCTAssertEqual(timers, [])
    }

    func testWithoutAPasteboardItWritesNowhere() {
        let clipboard = Clipboard(pasteboard: nil)
        clipboard.copy("CANARY-1")
        XCTAssertFalse(clipboard.isHolding)
        XCTAssertEqual(timers, [])
    }
}
