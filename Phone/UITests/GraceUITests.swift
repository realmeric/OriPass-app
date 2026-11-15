import XCTest

/// A minute chosen, then a fill in it. When the extension answers with no
/// interface, iOS's own sheet asks for a face of its own (with no match sent
/// the fill hangs there), so the match is sent throughout, and what shows
/// that the extension asked for none is its trace: "answered without a
/// face, in grace", which scripts/autofill-ui.sh prints.
final class GraceUITests: XCTestCase {
    func testChooseAMinute() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 30))
        sleep(2)
        app.buttons["Settings"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Fill Without Face ID'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        app.buttons["For 1 Minute"].tap()
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "grace-chosen"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["Done"].tap()
        app.terminate()
    }

    func testFillsWithoutAFace() throws {
        let safari = Safari.open("http://localhost:8099/login")
        let username = safari.webViews.textFields["Username"].firstMatch
        XCTAssertTrue(username.waitForExistence(timeout: 20))
        username.tap()
        // iOS offers it as its own sheet or above the keyboard; either.
        let sheet = safari.descendants(matching: .any).matching(NSPredicate(format: "label == 'Fill Password'")).firstMatch
        if sheet.waitForExistence(timeout: 15) {
            sheet.tap()
        } else {
            let offer = safari.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS 'kanarya-user-1' AND label CONTAINS 'OriPass' AND NOT label BEGINSWITH 'Sign in to'")).firstMatch
            XCTAssertTrue(offer.waitForExistence(timeout: 6), safari.debugDescription)
            offer.tap()
        }
        // The sheet fills and submits; the keyboard's offer fills alone.
        let matched = safari.descendants(matching: .any).matching(NSPredicate(format: "label == 'Matched'")).firstMatch
        XCTAssertTrue(matched.waitForExistence(timeout: 8) || username.waitForValue("kanarya-user-1", timeout: 8),
                      "filled with no face")
    }
}
