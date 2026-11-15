import XCTest

/// Two writes to the stand-in, which keeps what they made for
/// scripts/bw-reads-edits.sh to hand to Bitwarden's own CLI.
final class EditUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testAPasswordForTheLoginWithAPasskeyAndANewLogin() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Lock"].waitForExistence(timeout: 30))
        sleep(2)
        app.buttons["Logins"].firstMatch.tap()
        app.staticTexts["Kanarya Passkey Site"].firstMatch.tap()
        app.buttons["Edit"].tap()
        let password = app.secureTextFields["Password"]
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        password.tap()
        password.typeText("kanarya-pass-5-Edited")
        shoot("edit")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 15), "the form closed on a save")
        XCTAssertTrue(app.staticTexts["Password"].waitForExistence(timeout: 10), "the item has a password now")

        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["New Item"].tap()
        app.buttons["New Login"].tap()
        let title = app.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Kanarya New")
        app.textFields["Username"].tap()
        app.textFields["Username"].typeText("kanarya-user-9")
        app.secureTextFields["Password"].tap()
        app.secureTextFields["Password"].typeText("kanarya-pass-9-New")
        shoot("new")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Logins"].firstMatch.waitForExistence(timeout: 15), "the form closed on a save")
        sleep(1)
        app.buttons["Logins"].firstMatch.tap()
        let made = app.staticTexts["Kanarya New"]
        for _ in 0..<4 where !made.exists { app.swipeUp() }
        XCTAssertTrue(made.waitForExistence(timeout: 15), "the new login is in the vault after the sync")
    }
}
