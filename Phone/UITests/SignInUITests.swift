import XCTest

/// Against scripts/standin.py on localhost:8099, which `make phone-ui` runs.
final class SignInUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testSigningInToTheStandIn() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-OPReset"]
        app.launch()
        app.signIn()
        XCTAssertTrue(app.buttons["Lock"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Stand-in login page"].waitForExistence(timeout: 20), "the sync opened the vault")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "signed-in"
        shot.lifetime = .keepAlways
        add(shot)
    }
}

extension XCUIApplication {
    func signIn(password: String = "demo") {
        let server = buttons.matching(NSPredicate(format: "label BEGINSWITH 'Server'")).firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 10), debugDescription)
        server.tap()
        buttons["Self-hosted"].firstMatch.tap()
        let url = textFields["Server URL"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.tap()
        url.typeText("http://localhost:8099")
        let email = textFields["Email"]
        email.tap()
        email.typeText("kanarya@example.invalid")
        let field = secureTextFields["Master Password"]
        field.tap()
        field.typeText(password)
        let shot = XCTAttachment(screenshot: screenshot())
        shot.name = "sign-in"
        shot.lifetime = .keepAlways
        XCTContext.runActivity(named: "the form") { $0.add(shot) }
        buttons["Sign In"].tap()
    }
}

final class AboutUITests: XCTestCase {
    func testTheVaultInCounts() throws {
        OriPass.openAndLock()
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 30))
        sleep(2)
        app.buttons["Settings"].tap()
        app.buttons["About This Vault"].tap()
        XCTAssertTrue(app.staticTexts["Type 2"].waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "about"
        shot.lifetime = .keepAlways
        add(shot)
    }
}

final class SettingsUITests: XCTestCase {
    /// Settings shot, then Sign Out and its question: the sign-in form
    /// comes back. It leaves the simulator signed out.
    func testSettingsAndSigningOut() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 30))
        sleep(2)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "settings"
        shot.lifetime = .keepAlways
        add(shot)
        app.swipeUp()
        app.buttons["Sign Out"].firstMatch.tap()
        let both = app.buttons.matching(NSPredicate(format: "label == 'Sign Out'"))
        let deadline = Date(timeIntervalSinceNow: 5)
        while both.count < 2 && Date() < deadline { usleep(200_000) }
        XCTAssertEqual(both.count, 2, "the question's own Sign Out")
        let confirm = both.allElementsBoundByIndex.first { $0.isHittable } ?? both.element(boundBy: 0)
        let question = XCTAttachment(screenshot: app.screenshot())
        question.name = "sign-out-question"
        question.lifetime = .keepAlways
        add(question)
        confirm.tap()
        XCTAssertTrue(app.textFields["Email"].waitForExistence(timeout: 10), "the sign-in form")
        app.terminate()
        let safari = Safari.open("http://localhost:8099/login")
        let username = safari.webViews.textFields["Username"].firstMatch
        XCTAssertTrue(username.waitForExistence(timeout: 20))
        username.tap()
        sleep(3)
        XCTAssertFalse(safari.keyboardSuggestion(containing: "kanarya-user-1").exists, "no suggestion once signed out")
    }
}
