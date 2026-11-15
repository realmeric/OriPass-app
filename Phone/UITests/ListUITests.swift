import XCTest

/// The list behind the keyboard's key, in an app and in Safari.
final class ListUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The keyboard's key, then OriPass among the providers it offers.
    private func openList(from app: XCUIApplication) {
        let key = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Passwords' OR label == 'Password Auto-fill'")).firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 10))
        key.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let choice = app.buttons["OriPass"].exists ? app.buttons["OriPass"] : springboard.buttons["OriPass"]
        if choice.waitForExistence(timeout: 5) { choice.tap() }
    }

    func testOneTapInTheListFillsAnApp() throws {
        OriPass.openAndLock()
        let forms = XCUIApplication(bundleIdentifier: "com.meric.oripass.forms")
        forms.launch()
        forms.textFields["Username"].tap()
        openList(from: forms)
        let row = forms.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Stand-in second account'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the list opened")
        shoot("list-in-an-app")
        row.tap()
        let counts = forms.staticTexts["counts"]
        XCTAssertTrue(NSPredicate(format: "label == 'username 14 password 18'").evaluate(with: counts) ||
                      counts.waitForLabel("username 14 password 18", timeout: 10), counts.label)
        shoot("filled-in-an-app")
    }

    func testTheSitesLoginsComeFirstInSafari() throws {
        OriPass.openAndLock()
        let safari = Safari.open("http://localhost:8099/login")
        let username = safari.webViews.textFields["Username"].firstMatch
        XCTAssertTrue(username.waitForExistence(timeout: 20))
        username.tap()
        let close = safari.descendants(matching: .any).matching(NSPredicate(format: "label == 'Close'")).firstMatch
        if close.waitForExistence(timeout: 4) { close.tap() }
        if !username.hasFocus { username.tap() }
        openList(from: safari)
        let suggested = safari.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] 'Suggested'")).firstMatch
        XCTAssertTrue(suggested.waitForExistence(timeout: 30), "the site's logins are on top")
        shoot("list-in-safari")
        safari.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Stand-in second account'")).firstMatch.tap()
        XCTAssertTrue(username.waitForValue("kanarya-user-7", timeout: 15))
        shoot("filled-in-safari")
    }

    /// The list's plus: a login made in the extension with the page's
    /// address in it, saved to the vault, and in both fields at once.
    func testANewLoginFromTheListFillsThePage() throws {
        OriPass.openAndLock()
        let safari = Safari.open("http://localhost:8099/login")
        let username = safari.webViews.textFields["Username"].firstMatch
        XCTAssertTrue(username.waitForExistence(timeout: 20))
        username.tap()
        let close = safari.descendants(matching: .any).matching(NSPredicate(format: "label == 'Close'")).firstMatch
        if close.waitForExistence(timeout: 4) { close.tap() }
        if !username.hasFocus { username.tap() }
        openList(from: safari)
        let plus = safari.buttons["New Login"]
        XCTAssertTrue(plus.waitForExistence(timeout: 30), "the list opened")
        shoot("a-list-with-plus")
        plus.tap()
        // The page's fields are in the same tree as the form over them; the
        // form's are the last of each.
        let titles = safari.textFields.matching(NSPredicate(format: "placeholderValue == 'Title'"))
        XCTAssertTrue(titles.firstMatch.waitForExistence(timeout: 5))
        let names = safari.textFields.matching(NSPredicate(format: "placeholderValue == 'Username' OR label == 'Username'"))
        let name = names.element(boundBy: names.count - 1)
        name.tap()
        name.typeText("kanarya-fresh")
        let secrets = safari.secureTextFields.matching(NSPredicate(format: "placeholderValue == 'Password' OR label == 'Password'"))
        let password = secrets.element(boundBy: secrets.count - 1)
        password.tap()
        password.typeText("kanarya-pass-fresh-1")
        shoot("b-new-login")
        safari.buttons["Save"].tap()
        XCTAssertTrue(username.waitForValue("kanarya-fresh", timeout: 30), "the page holds the new login")
        let secret = safari.webViews.secureTextFields["Password"].firstMatch
        XCTAssertNotEqual(secret.value as? String ?? "", "")
        shoot("c-filled")
    }

    /// With the face skipped (scripts/autofill-ui.sh leaves debug-no-face in
    /// the App Group), the master password opens the list in the extension.
    func testThePasswordOpensTheList() throws {
        let forms = XCUIApplication(bundleIdentifier: "com.meric.oripass.forms")
        forms.launch()
        forms.textFields["Username"].tap()
        openList(from: forms)
        let field = forms.secureTextFields["Master Password"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("demo\n")
        let row = forms.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Stand-in login page'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the password opened the list")
        row.tap()
        XCTAssertTrue(forms.staticTexts["counts"].waitForLabel("username 14 password 18", timeout: 10))
    }
}

extension XCUIElement {
    func waitForLabel(_ wanted: String, timeout: TimeInterval) -> Bool {
        let end = Date(timeIntervalSinceNow: timeout)
        while Date() < end {
            if exists, label == wanted { return true }
            usleep(200_000)
        }
        return false
    }
}
