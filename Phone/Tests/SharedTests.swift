import XCTest
@testable import OriPass

final class SharedTests: XCTestCase {
    func testTheAppGroupIsReachable() throws {
        XCTAssertNotNil(Shared.container)
        XCTAssertTrue(Shared.keychainGroup.hasSuffix("com.meric.oripass.shared"))
    }
}
