import XCTest

/// A passkey made on the stand-in's page in Safari: iOS's sheet, a face, the
/// login chosen, and the stand-in reading what the extension made as a site
/// would. It then signs in, is refused a passkey the site has, and makes one
/// on a new login; scripts/bw-reads-edits.sh has Bitwarden's own CLI read both.
final class PasskeyUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testAPasskeyIsMadeAndSignsIn() throws {
        OriPass.openAndLock()
        let safari = Safari.open("http://localhost:8099/passkey")
        let sheet = XCUIApplication(bundleIdentifier: "com.apple.AuthenticationServicesUI")
        let make = safari.webViews.buttons["Make a passkey"].firstMatch
        XCTAssertTrue(make.waitForExistence(timeout: 20))
        make.tap()
        let add = sheet.staticTexts["Add Passkey"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 15), "iOS's own sheet")
        sleep(1)
        shoot("a-ios-sheet")
        add.tap()

        let home = sheet.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Stand-in second account'")).firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 20), "the site's logins, under a face")
        sleep(1)
        shoot("b-where-it-goes")
        home.tap()
        let done = safari.webViews.staticTexts["Passkey made"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 30), "the page has the passkey and the stand-in read it")
        shoot("c-made")

        // iOS offers it from the identity store, so the store has it already.
        safari.webViews.buttons["Sign in with it"].firstMatch.tap()
        let use = sheet.staticTexts["Use Passkey"].firstMatch
        XCTAssertTrue(use.waitForExistence(timeout: 15), "the new passkey is offered at once")
        sleep(1)
        shoot("d-offered")
        use.tap()
        let signedIn = safari.webViews.staticTexts["Signed in with the passkey"].firstMatch
        XCTAssertTrue(signedIn.waitForExistence(timeout: 30), "openssl found the signature good under the key the page was handed")
        shoot("e-signed-in")

        // The site names the passkey it has, and the vault holds it.
        sleep(3)  // the sheet is still going, and a tap now would land on it
        safari.webViews.buttons["Make it again"].firstMatch.tap()
        sleep(5)
        shoot("f-again")
        if sheet.state == .runningForeground { sheet.staticTexts["Add Passkey"].firstMatch.tap() }
        let refused = safari.webViews.staticTexts["Refused: InvalidStateError"].firstMatch
        let answered = refused.waitForExistence(timeout: 20)
        shoot("g-refused")
        XCTAssertTrue(answered, "the same passkey is not made twice")

        // Asked again with nothing excluded, it goes on a new login.
        sleep(3)
        make.tap()
        sleep(5)
        sheet.staticTexts["Add Passkey"].firstMatch.tap()
        let new = sheet.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'New Login'")).firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 20), "a face, and the list again")
        sleep(1)
        shoot("h-new-login")
        new.tap()
        XCTAssertTrue(done.waitForExistence(timeout: 30), "the page has the second passkey")
        shoot("i-made-again")
    }
}
