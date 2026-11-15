import XCTest

/// The vault's screens, shot in light and in dark for reading beside the card.
final class VaultUITests: XCTestCase {
    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testTheScreens() throws {
        for dark in [false, true] {
            let look = dark ? "dark" : "light"
            let app = XCUIApplication()
            app.launchArguments = dark ? ["-OPDark"] : []
            app.launch()
            XCTAssertTrue(app.buttons["Lock"].waitForExistence(timeout: 30))
            sleep(2)
            shoot("vault-\(look)")
            app.buttons["Logins"].firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Logins"].waitForExistence(timeout: 5))
            sleep(1)
            shoot("logins-\(look)")
            app.navigationBars.buttons.firstMatch.tap()
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.tap()
            search.typeText("kanarya")
            sleep(1)
            shoot("search-\(look)")
            app.terminate()
        }
    }
}
