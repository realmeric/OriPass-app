import XCTest

final class GeneratorUITests: XCTestCase {
    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// From the Home Screen icon's menu, the generator over the locked app.
    func testTheQuickActionOpensTheGenerator() throws {
        XCUIApplication().terminate()
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let icon = springboard.icons["OriPass"]
        for _ in 0..<3 where !(icon.exists && icon.isHittable) {
            springboard.swipeLeft()
            sleep(1)
        }
        XCTAssertTrue(icon.isHittable)
        icon.press(forDuration: 1.5)
        let action = springboard.buttons["Generate Password"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        shoot("a-quick-actions")
        action.tap()
        let app = XCUIApplication()
        let made = app.staticTexts["generated"]
        XCTAssertTrue(made.waitForExistence(timeout: 15))
        app.buttons["Password"].tap()
        sleep(1)
        XCTAssertGreaterThanOrEqual(made.label.count, 8)
        XCTAssertFalse(made.label.contains(" "))
        sleep(1)
        shoot("b-password")
        app.buttons["Passphrase"].tap()
        sleep(1)
        XCTAssertTrue(made.label.contains("-"))
        shoot("c-passphrase")
    }
}
