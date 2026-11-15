import XCTest

/// Run by scripts/face-ui.sh, which enrols a face on the simulator and sends
/// the match while the tests wait. Each starts from the account SignInUITests left signed in.
final class FaceUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testAFaceOpensTheVault() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Lock"].waitForExistence(timeout: 30), "a face opened the vault")
        XCTAssertFalse(app.secureTextFields["Master Password"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "opened-by-face"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testThePasswordOpensItToo() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Lock"].waitForExistence(timeout: 30))
        app.buttons["Lock"].tap()
        let field = app.secureTextFields["Master Password"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Unlock with Face ID"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "locked"
        shot.lifetime = .keepAlways
        add(shot)
        field.tap()
        field.typeText("not demo\n")
        XCTAssertTrue(app.staticTexts["That's not the master password."].waitForExistence(timeout: 20))
        field.tap()
        field.typeText("demo\n")
        XCTAssertTrue(app.buttons["Lock"].waitForExistence(timeout: 30), "the password opened it")
    }
}
