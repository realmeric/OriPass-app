import XCTest

final class UsernamesUITests: XCTestCase {
    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testTheRowNarrowsAsANameIsTyped() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Lock"].waitForExistence(timeout: 30))
        sleep(2)
        app.buttons["New Item"].tap()
        app.buttons["New Login"].tap()
        let field = app.textFields["Username"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(app.buttons["kanarya-user-1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["kanarya-user-2@kanarya.example"].exists)
        shoot("a-every-name")
        field.typeText("kanarya-user-2")
        XCTAssertTrue(app.buttons["kanarya-user-2@kanarya.example"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["kanarya-user-1"].exists, "narrowed by what was typed")
        shoot("b-narrowed")
        app.buttons["kanarya-user-2@kanarya.example"].tap()
        XCTAssertEqual(field.value as? String, "kanarya-user-2@kanarya.example")
    }
}
