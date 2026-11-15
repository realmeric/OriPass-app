import XCTest

final class LockUITests: XCTestCase {
    /// The app switcher's card for an open vault shows the cover.
    func testTheAppSwitcherSeesNothing() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Lock"].waitForExistence(timeout: 30))
        sleep(2)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let bottom = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.998))
        let middle = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        bottom.press(forDuration: 0.05, thenDragTo: middle, withVelocity: .slow, thenHoldForDuration: 1.2)
        sleep(1)
        // The app just left sits at the right edge; the cards slide left to
        // bring it to the middle.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(2)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "app-switcher"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertFalse(app.staticTexts["Stand-in login page"].isHittable)
    }
}
