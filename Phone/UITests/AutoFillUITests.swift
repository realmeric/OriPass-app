import XCTest

/// AutoFill on the simulator, against the stand-in; scripts/autofill-ui.sh
/// runs it after a sign-in and sends Face ID's match while it waits.
final class AutoFillUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Settings with OriPass switched off, then the app's button, iOS's
    /// question, and a suggestion in Safari with the app never opened again.
    func testTheAppTurnsItOn() throws {
        AutoFillUITests.setOriPass(on: false)
        let app = XCUIApplication()
        app.launch()
        let button = app.buttons["Turn On AutoFill"]
        XCTAssertTrue(button.waitForExistence(timeout: 30))
        sleep(3)  // the face prompt of the app's own unlock fades over the button
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "autofill-off"
        shot.lifetime = .keepAlways
        add(shot)
        button.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for step in 0..<5 {
            sleep(2)
            let question = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            question.name = "ios-question-\(step)"
            question.lifetime = .keepAlways
            add(question)
        }
        let allow = springboard.buttons.matching(NSPredicate(format: "label IN {'Allow', 'Turn On', 'Use'}")).firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 10), springboard.debugDescription)
        allow.tap()
        XCTAssertFalse(button.waitForExistence(timeout: 2) && button.isHittable, "the button went with the yes")
        app.terminate()

        let safari = Safari.open("http://localhost:8099/login")
        let username = safari.webViews.textFields["Username"].firstMatch
        XCTAssertTrue(username.waitForExistence(timeout: 20))
        username.tap()
        XCTAssertTrue(safari.keyboardSuggestion(containing: "kanarya-user-1").waitForExistence(timeout: 10))
    }

    /// Switched on in Settings with the app shut: the extension's
    /// configuration opens the vault once, and the keyboard has the login.
    func testSettingsTurnsItOnAndTheStoreIsFilled() throws {
        XCUIApplication().terminate()
        AutoFillUITests.setOriPass(on: false)
        AutoFillUITests.setOriPass(on: true)
        let safari = Safari.open("http://localhost:8099/login")
        let username = safari.webViews.textFields["Username"].firstMatch
        XCTAssertTrue(username.waitForExistence(timeout: 20))
        username.tap()
        XCTAssertTrue(safari.keyboardSuggestion(containing: "kanarya-user-1").waitForExistence(timeout: 10))
    }

    static func setOriPass(on: Bool) {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        settings.cells.staticTexts["General"].firstMatch.tap()
        settings.cells.staticTexts.matching(NSPredicate(format: "label CONTAINS 'AutoFill'")).firstMatch.tap()
        let row = settings.switches.matching(NSPredicate(format: "label BEGINSWITH 'OriPass'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        if (row.value as? String == "1") != on { row.switches.firstMatch.tap() }
        sleep(on ? 6 : 1)  // switched on, the extension's configuration asks for a face
        settings.terminate()
    }

    func testTurnOnOriPass() throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        settings.cells.staticTexts["General"].firstMatch.tap()
        settings.cells.staticTexts.matching(NSPredicate(format: "label CONTAINS 'AutoFill'")).firstMatch.tap()
        let row = settings.switches.matching(NSPredicate(format: "label BEGINSWITH 'OriPass'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        if row.value as? String == "0" { row.switches.firstMatch.tap() }
        XCTAssertTrue(NSPredicate(format: "value == '1'").evaluate(with: row) || row.value as? String == "1")
        settings.terminate()
    }

    /// The app opened once with AutoFill on writes the store; the vault is
    /// then locked, and the keyboard still suggests the login.
    func testTheSuggestionIsThereWhileLocked() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Lock"].waitForExistence(timeout: 30))
        sleep(2)
        app.buttons["Lock"].tap()
        app.terminate()

        let safari = Safari.open("http://localhost:8099/login")
        let username = safari.webViews.textFields["Username"].firstMatch
        XCTAssertTrue(username.waitForExistence(timeout: 20))
        username.tap()
        let suggestion = safari.keyboardSuggestion(containing: "kanarya-user-1")
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10), safari.debugDescription)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "suggestion-while-locked"
        shot.lifetime = .keepAlways
        add(shot)
    }
}

enum OriPass {
    /// The app opened once, by a face or by the password, so that a key is
    /// kept for Face ID and the store is written, and then shut.
    static func openAndLock() {
        let app = XCUIApplication()
        app.launch()
        let items = app.buttons["Lock"]
        let field = app.secureTextFields["Master Password"]
        if !items.waitForExistence(timeout: 12), field.exists {
            field.tap()
            field.typeText("demo\n")
        }
        XCTAssertTrue(items.waitForExistence(timeout: 30))
        sleep(1)
        app.buttons["Lock"].tap()
        app.terminate()
    }
}

enum Safari {
    static func open(_ address: String) -> XCUIApplication {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCUIDevice.shared.system.open(URL(string: address)!)
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15))
        return safari
    }
}

extension XCUIElement {
    func waitForValue(_ wanted: String, timeout: TimeInterval) -> Bool {
        let end = Date(timeIntervalSinceNow: timeout)
        while Date() < end {
            if exists, value as? String == wanted { return true }
            usleep(200_000)
        }
        return false
    }
}

extension XCUIApplication {
    func keyboardSuggestion(containing text: String) -> XCUIElement {
        descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }
}

final class FillUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The vault locked; a tap on iOS's offer, a face, and both fields hold
    /// the login's values with no other tap.
    func testOneTapFillsBothFields() throws {
        OriPass.openAndLock()
        let safari = Safari.open("http://localhost:8099/login")
        let username = safari.webViews.textFields["Username"].firstMatch
        XCTAssertTrue(username.waitForExistence(timeout: 20))
        username.tap()
        let offer = safari.keyboardSuggestion(containing: "kanarya-user-1")
        XCTAssertTrue(offer.waitForExistence(timeout: 10))
        let fill = safari.descendants(matching: .any).matching(NSPredicate(format: "label == 'Fill Password'")).firstMatch
        XCTAssertTrue(fill.waitForExistence(timeout: 5), safari.debugDescription)
        fill.tap()
        for step in 0..<6 {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "after-the-tap-\(step)"
            shot.lifetime = .keepAlways
            add(shot)
            usleep(450_000)
        }
        // iOS 26's sheet signs in: it fills both fields and submits the
        // form, and the stand-in answers whether the two were the login's.
        let matched = safari.staticTexts["Matched"]
        if !matched.waitForExistence(timeout: 20) {
            XCTAssertTrue(username.waitForValue("kanarya-user-1", timeout: 1), "the username was filled")
            let password = safari.webViews.secureTextFields["Password"].firstMatch
            XCTAssertNotEqual(password.value as? String ?? "", "", "the password field was filled too")
        }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "filled"
        shot.lifetime = .keepAlways
        add(shot)
    }
}

final class CodeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// A code field on the stand-in's site: the keyboard offers the code
    /// of the login there, and a tap and a face put its six digits in.
    func testTheCodeIsOfferedAndFilled() throws {
        OriPass.openAndLock()
        let safari = Safari.open("http://localhost:8099/code")
        let field = safari.webViews.textFields["Code"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        sleep(2)
        let offered = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        offered.name = "code-offered"
        offered.lifetime = .keepAlways
        add(offered)
        let offer = safari.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'OriPass'")).firstMatch
        XCTAssertTrue(offer.waitForExistence(timeout: 10), safari.debugDescription)
        offer.tap()
        // iOS fills the code and submits the form; the stand-in says whether
        // the code was the login's at this moment.
        XCTAssertTrue(safari.staticTexts["Code matched"].waitForExistence(timeout: 20), "the code was the login's")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "code-filled"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
