import XCTest

/// A sign-up form on the stand-in: the strong password the keyboard offers
/// is OriPass's, made under the page's rules, iOS hands it to OriPass to
/// save, and the app has the new login after.
final class SaveUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testASignUpIsSavedToTheVault() throws {
        OriPass.openAndLock()
        let safari = Safari.open("http://localhost:8099/signup")
        let username = safari.webViews.textFields["Username"].firstMatch
        XCTAssertTrue(username.waitForExistence(timeout: 20))
        username.tap()
        username.typeText("kanarya-signup")
        safari.webViews.secureTextFields.firstMatch.tap()
        let fill = safari.descendants(matching: .any).matching(NSPredicate(format: "label == 'Fill Strong Password'")).firstMatch
        XCTAssertTrue(fill.waitForExistence(timeout: 10))
        shoot("a-offer")
        fill.tap()
        let save = safari.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 15), "iOS asked OriPass to save it")
        sleep(1)
        shoot("b-save")
        save.tap()
        // Save turns into a spinner while it saves; the sheet's title going
        // is the save done.
        let sheet = safari.descendants(matching: .any).matching(NSPredicate(format: "label == 'Save to OriPass'")).firstMatch
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 30), "saved under a face")
        shoot("c-filled")
        let signUp = safari.webViews.descendants(matching: .button).matching(NSPredicate(format: "label == 'Sign up'")).firstMatch
        XCTAssertTrue(signUp.waitForExistence(timeout: 10), "the page's button")
        signUp.tap()
        let done = safari.descendants(matching: .any).matching(NSPredicate(format: "label == 'Signed up'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "the page took the form")

        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Lock"].waitForExistence(timeout: 30))
        sleep(1)
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("kanarya-signup")
        XCTAssertTrue(app.staticTexts["kanarya-signup"].waitForExistence(timeout: 10), "the new login is in the vault")
        shoot("d-in-the-vault")
    }
}
