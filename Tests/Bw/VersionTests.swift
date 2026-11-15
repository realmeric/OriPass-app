import XCTest
@testable import OriPass

final class VersionTests: XCTestCase {
    func testTheMonthsTheFixturesWereRecordedOnAreInside() {
        for said in ["2026.9.0", "2026.9.1", "2026.9.14", "2026.9"] {
            XCTAssertEqual(BwVersion.fit(of: BwVersion(said)), .inside, said)
        }
    }

    func testAnEarlierMonthIsBelow() {
        for said in ["2026.8.3", "2025.12.1", "2026.1.0"] {
            XCTAssertEqual(BwVersion.fit(of: BwVersion(said)), .below, said)
        }
    }

    func testALaterMonthIsAbove() {
        for said in ["2026.10.0", "2026.12.2", "2027.1.0", "2030.3.1"] {
            XCTAssertEqual(BwVersion.fit(of: BwVersion(said)), .above, said)
        }
    }

    func testTenIsAfterNineAndNotBeforeIt() throws {
        XCTAssertLessThan(try XCTUnwrap(BwVersion("2026.9.1")), try XCTUnwrap(BwVersion("2026.10.0")))
        XCTAssertLessThan(try XCTUnwrap(BwVersion("2026.9.2")), try XCTUnwrap(BwVersion("2026.9.10")))
    }

    func testAVersionIsReadFromWhateverBwSaysAroundIt() {
        XCTAssertEqual(BwVersion("2026.9.1"), BwVersion(2026, 9, 1))
        XCTAssertEqual(BwVersion("v2026.9.1\n"), BwVersion(2026, 9, 1))
        XCTAssertEqual(BwVersion("bw 2027.1.0 (node 26)"), BwVersion(2027, 1, 0))
        XCTAssertNil(BwVersion(""))
        XCTAssertNil(BwVersion("unknown"))
        XCTAssertNil(BwVersion("2026"))
        XCTAssertNil(BwVersion("."))
        XCTAssertEqual(BwVersion.fit(of: BwVersion("unknown")), .unreadable)
    }

    func testTheRoomSaysWhatItWasWrittenForAndWhatItFoundAndBlocksNothing() {
        let url = URL(fileURLWithPath: "/opt/homebrew/bin/bw")
        XCTAssertNil(BwBinary(url: url, version: "2026.9.1").notice)

        let above = BwBinary(url: url, version: "2027.1.0").notice ?? ""
        XCTAssertTrue(above.hasPrefix("Written for 2026.9, found 2027.1."), above)
        let below = BwBinary(url: url, version: "2026.5.2").notice ?? ""
        XCTAssertTrue(below.hasPrefix("Written for 2026.9, found 2026.5."), below)
        XCTAssertTrue(above.contains("Nothing is blocked"))

        let unreadable = BwBinary(url: url, version: "a build").notice ?? ""
        XCTAssertTrue(unreadable.hasPrefix("Written for 2026.9."), unreadable)
        XCTAssertTrue(unreadable.contains("could not be read"))
    }

    /// The version comes from the binary and is not guessed: a stand-in that
    /// says 2027.1.0 is above.
    func testTheVersionABinarySaysIsTheOneThatIsJudged() async throws {
        let standIn = try StandIn(["version": "2027.1.0"])
        let found = try await BwBinary.locate(preferred: standIn.binary.path, dataDirectory: standIn.data)
        XCTAssertEqual(found.fit, .above)
        XCTAssertEqual(found.notice?.hasPrefix("Written for 2026.9, found 2027.1."), true)
    }
}
