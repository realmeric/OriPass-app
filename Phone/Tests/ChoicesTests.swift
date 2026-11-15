import XCTest
@testable import OriPass

final class ChoicesTests: XCTestCase {
    private let defaults = UserDefaults(suiteName: "com.meric.oripass.tests.choices")!

    override func tearDown() {
        defaults.removePersistentDomain(forName: "com.meric.oripass.tests.choices")
    }

    func testTheLockRule() {
        let left = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(LockRule.locks(leftAt: nil, now: left, after: 0), "never left")
        XCTAssertTrue(LockRule.locks(leftAt: left, now: left, after: 0), "at once")
        XCTAssertFalse(LockRule.locks(leftAt: left, now: left + 299, after: 300))
        XCTAssertTrue(LockRule.locks(leftAt: left, now: left + 300, after: 300))
    }

    func testChoicesRoundTripAndABadFieldCostsOnlyItself() throws {
        var choices = Choices()
        choices.lockAfter = 60
        choices.siteIcons = false
        choices.write(to: defaults)
        XCTAssertEqual(Choices.read(from: defaults), choices)
        defaults.set(try JSONSerialization.data(withJSONObject: ["lockAfter": 7, "faceID": false]), forKey: "choices")
        let read = Choices.read(from: defaults)
        XCTAssertEqual(read.lockAfter, 300, "a time not on offer is the default")
        XCTAssertFalse(read.faceID)
        XCTAssertTrue(read.siteIcons)
    }
}
