import XCTest
@testable import OriPass

final class UsernamesTests: XCTestCase {
    private let ranked = Usernames.ranked([
        "zeynep@example.test", "abc@mail.example.test", "abc@example.test", "abc@example.test", "abc@example.test",
        "abc@mail.example.test", nil, "", " ",
    ])

    func testMostUsedFirstThenByName() {
        XCTAssertEqual(ranked, ["abc@example.test", "abc@mail.example.test", "zeynep@example.test"])
    }

    func testTheRowNarrowsAsItIsTyped() {
        XCTAssertEqual(Usernames.matching("", in: ranked), ranked)
        XCTAssertEqual(Usernames.matching("abc", in: ranked), ["abc@example.test", "abc@mail.example.test"])
        XCTAssertEqual(Usernames.matching("ABC@e", in: ranked), ["abc@example.test"])
        XCTAssertEqual(Usernames.matching("abc@example.test", in: ranked), [], "the one typed in full")
        XCTAssertEqual(Usernames.matching("x", in: ranked), [])
    }
}
