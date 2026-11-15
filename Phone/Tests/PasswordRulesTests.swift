import XCTest
@testable import OriPass

final class PasswordRulesTests: XCTestCase {
    func testTheRulesAreRead() {
        let rules = PasswordRules("minlength: 24; maxlength: 30; required: lower; required: upper; required: digit; required: [-]; allowed: [_]")
        XCTAssertEqual(rules.minLength, 24)
        XCTAssertEqual(rules.maxLength, 30)
        XCTAssertEqual(rules.required.count, 4)
        XCTAssertEqual(rules.required[3], ["-"])
        XCTAssertEqual(rules.allowed, ["_"])
    }

    func testAGeneratedPasswordKeepsTheRules() {
        let rules = PasswordRules("minlength: 24; maxlength: 30; required: lower; required: upper; required: digit; required: [-]; allowed: [_]")
        let allowed = PasswordRules.lower.union(PasswordRules.upper).union(PasswordRules.digit).union(["-", "_"])
        for _ in 0..<1_000 {
            let password = rules.password()
            XCTAssertEqual(password.count, 24)
            XCTAssertTrue(password.contains(where: PasswordRules.lower.contains))
            XCTAssertTrue(password.contains(where: PasswordRules.upper.contains))
            XCTAssertTrue(password.contains(where: PasswordRules.digit.contains))
            XCTAssertTrue(password.contains("-"))
            XCTAssertTrue(password.allSatisfy(allowed.contains), password)
        }
    }

    func testAShortMaximumAndNoRulesAtAll() {
        XCTAssertEqual(PasswordRules("maxlength: 12; required: digit").password().count, 12)
        XCTAssertEqual(PasswordRules(nil).password().count, 20)
    }
}
