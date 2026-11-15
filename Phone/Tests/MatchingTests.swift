import AuthenticationServices
import XCTest
@testable import OriPass

final class MatchingTests: XCTestCase {
    private func login(_ uri: String, match: Int? = nil) -> Summary {
        Summary(id: "a", kind: .login, name: "a", username: nil, uris: [Item.Uri(uri: uri, match: match)],
                hasPassword: true, hasTotp: false, passkeys: [], favorite: false, asksAgain: false)
    }

    private func page(_ written: String, _ type: ASCredentialServiceIdentifier.IdentifierType = .URL) -> Matching {
        Matching([ASCredentialServiceIdentifier(identifier: written, type: type)])
    }

    func testTheSameSiteIsTheDefault() {
        let page = page("https://www.kanarya.co.uk/login")
        XCTAssertTrue(page.matches(login("https://accounts.kanarya.co.uk")))
        XCTAssertFalse(page.matches(login("https://other.co.uk")))
        XCTAssertTrue(self.page("mail.kanarya.example", .domain).matches(login("kanarya.example")))
    }

    func testAHostWithNoSiteIsItself() {
        XCTAssertTrue(page("localhost", .domain).matches(login("http://localhost:8099/login")))
        XCTAssertFalse(page("127.0.0.2", .domain).matches(login("http://127.0.0.1")))
    }

    func testTheOtherRules() {
        let page = page("https://shop.kanarya.example:8443/cart/1")
        XCTAssertTrue(page.matches(login("https://shop.kanarya.example:8443", match: 1)))
        XCTAssertFalse(page.matches(login("https://shop.kanarya.example", match: 1)))
        XCTAssertTrue(page.matches(login("https://shop.kanarya.example:8443/cart", match: 2)))
        XCTAssertFalse(page.matches(login("https://shop.kanarya.example:8443/account", match: 2)))
        XCTAssertTrue(page.matches(login("https://shop.kanarya.example:8443/cart/1", match: 3)))
        XCTAssertTrue(page.matches(login("^https://shop\\.kanarya\\.example.*/cart/", match: 4)))
        XCTAssertFalse(page.matches(login("https://shop.kanarya.example", match: 5)))
    }

    func testAnAndroidAppMatchesNoPage() {
        XCTAssertFalse(page("kanarya.example", .domain).matches(login("androidapp://example.kanarya")))
    }
}
