import XCTest
@testable import OriPass

final class GraceKeyTests: XCTestCase {
    private let grace = GraceKey(keychain: Keychain(service: "com.meric.oripass.tests"))

    override func tearDown() {
        grace.forget()
    }

    func testTheKeyLastsItsMinutesAndIsDeletedAfter() throws {
        let key = VaultKey.random()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        grace.keep(key, minutes: 1, now: now)
        XCTAssertEqual(grace.take(now: now.addingTimeInterval(59))?.bytes, key.bytes)
        XCTAssertNil(grace.take(now: now.addingTimeInterval(61)))
        XCTAssertNil(grace.take(now: now), "deleted when it was found past its minutes")
    }

    func testNoMinutesKeepsNothingAndALockForgetsIt() {
        let now = Date.now
        grace.keep(VaultKey.random(), minutes: 0, now: now)
        XCTAssertNil(grace.take(now: now))
        grace.keep(VaultKey.random(), minutes: 5, now: now)
        grace.forget()
        XCTAssertNil(grace.take(now: now))
    }
}
