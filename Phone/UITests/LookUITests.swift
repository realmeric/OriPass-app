import XCTest

/// Every screen at the largest text size, and the icon on the Home Screen.
/// Starts signed out, as SettingsUITests leaves the simulator.
final class LookUITests: XCTestCase {
    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testEveryScreenAtTheLargestText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-OPReset", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.textFields["Email"].waitForExistence(timeout: 15))
        shoot("a-sign-in")
        app.signIn()
        XCTAssertTrue(app.buttons["Lock"].waitForExistence(timeout: 30))
        sleep(2)
        shoot("b-vault")
        let logins = app.buttons["Logins"].firstMatch
        for _ in 0..<6 where !(logins.exists && logins.isHittable) { app.swipeUp() }
        logins.tap()
        sleep(1)
        shoot("c-logins")
        let mail = app.staticTexts["Kanarya Mail"].firstMatch
        for _ in 0..<6 where !(mail.exists && mail.isHittable) { app.swipeUp() }
        mail.tap()
        sleep(1)
        shoot("d-item")
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Settings"].tap()
        sleep(1)
        shoot("e-settings")
        app.buttons["Done"].tap()
        app.buttons["Lock"].tap()
        sleep(1)
        shoot("f-lock")
        XCUIDevice.shared.press(.home)
        sleep(2)
        shoot("g-home-screen")
    }
}
