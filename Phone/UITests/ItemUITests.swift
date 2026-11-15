import XCTest

final class ItemUITests: XCTestCase {
    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testALoginWithACodeAndACard() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Lock"].waitForExistence(timeout: 30))
        sleep(2)
        app.buttons["Logins"].firstMatch.tap()
        app.staticTexts["Kanarya Mail"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["One-Time Code"].waitForExistence(timeout: 5))
        shoot("login")
        app.staticTexts["Password"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Password copied"].waitForExistence(timeout: 3))
        shoot("copied")
        app.buttons["Reveal"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["kanarya-pass-2-Lq4"].waitForExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Credit Cards"].firstMatch.tap()
        app.staticTexts["Kanarya Card"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Cardholder Name"].waitForExistence(timeout: 5))
        shoot("card")
    }
}
