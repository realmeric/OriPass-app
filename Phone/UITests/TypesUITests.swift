import XCTest

/// A card, an identity and an SSH key made on the phone, and the fixture's
/// card given a new code, against a stand-in that keeps them for
/// scripts/bw-reads-types.sh.
final class TypesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private var app: XCUIApplication!

    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// A short drag up, so a row is not scrolled past.
    private func nudge() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
    }

    private func type(_ text: String, into label: String) {
        let field = app.textFields[label]
        for _ in 0..<10 where !(field.exists && field.isHittable) { nudge() }
        field.tap()
        field.typeText(text)
    }

    private func choose(_ option: String, in label: String) {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
        for _ in 0..<10 where !(row.exists && row.isHittable) { nudge() }
        row.tap()
        app.buttons[option].firstMatch.tap()
    }

    private func new(_ kind: String) {
        app.buttons["New Item"].tap()
        app.buttons[kind].tap()
        XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 5))
    }

    private func save() {
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["New Item"].waitForExistence(timeout: 15), "the form closed on a save")
        sleep(1)
    }

    func testACardAnIdentityAndAKey() throws {
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Lock"].waitForExistence(timeout: 30))
        sleep(2)

        new("New Card")
        type("Kanarya Card Two", into: "Title")
        type("Kanarya Two", into: "Cardholder Name")
        choose("Mastercard", in: "Brand")
        type("5555555555554444", into: "Number")
        choose("July", in: "Expiry Month")
        type("2031", into: "Expiry Year")
        type("321", into: "Security Code")
        shoot("a-card")
        save()

        new("New Identity")
        type("Kanarya Person", into: "Title")
        choose("Mx", in: "Title,")
        type("Kanarya", into: "First Name")
        type("Kus", into: "Last Name")
        type("kanarya-person@kanarya.example", into: "Email")
        shoot("b-identity")
        save()

        new("New SSH Key")
        type("Kanarya Key", into: "Title")
        app.buttons["Generate Key"].tap()
        XCTAssertTrue(app.staticTexts["Fingerprint"].waitForExistence(timeout: 5))
        shoot("c-key")
        save()

        app.buttons["Credit Cards"].firstMatch.tap()
        app.staticTexts["Kanarya Card"].firstMatch.tap()
        app.buttons["Edit"].tap()
        let code = app.textFields["Security Code"]
        for _ in 0..<10 where !(code.exists && code.isHittable) { nudge() }
        code.tap()
        code.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        code.typeText(XCUIKeyboardKey.delete.rawValue + "999")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 15))
        shoot("d-card-edited")
    }
}
