import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import OriPass

@MainActor
final class ExtensionTests: XCTestCase {
    private var stage: ExtensionStage!
    private let settle: UInt64 = 300_000_000
    private let page = WKContentWorld.page

    override func setUp() async throws {
        stage = ExtensionStage()
        try await stage.open()
    }

    override func tearDown() async throws {
        stage.close()
        stage = nil
    }

    // MARK: Reaching the menu

    /// Where a row of the menu under `field` is, counted from the top left
    /// of what `field`'s box is counted from: the card's gap and padding, and
    /// the rows above it.
    private func row(_ place: Int, under field: CGRect) -> CGPoint {
        CGPoint(x: field.minX + 60, y: field.maxY + 4 + 6 + 16 + CGFloat(place) * 32)
    }

    private func mark(of field: CGRect) -> CGPoint {
        CGPoint(x: field.maxX - 14, y: field.midY)
    }

    private func marks(_ count: Int, in frame: WKFrameInfo? = nil) async throws {
        try await stage.until("live('.mark').length === \(count)", in: frame)
    }

    /// Opens the menu with a click on the field's own mark and waits out
    /// the moment a row cannot be chosen in.
    private func openMenu(_ id: String) async throws -> CGRect {
        let field = try await stage.box(of: id)
        try stage.click(mark(of: field))
        try await stage.until("live('.row').length === 3")
        try await Task.sleep(nanoseconds: settle)
        return field
    }

    private var fills: [[String: Any]] { stage.heard.filter { $0["type"] as? String == "fill" } }

    /// What the app heard besides the one question a top frame asks at load.
    private var heardOfTheFrame: [String] {
        stage.heard.compactMap { $0["type"] as? String }.filter { $0 != "passkeys" }
    }

    private func value(_ id: String, in frame: WKFrameInfo? = nil) async throws -> String? {
        try await stage.js("return document.getElementById('\(id)').value", world: page, in: frame) as? String
    }

    // MARK: The six pages

    func testAPlainFormTakesARow() async throws {
        try await stage.load("plain")
        try await marks(2)
        try await stage.js("""
        window.said = [];
        for (const name of ["input", "change"]) {
            document.addEventListener(name, (event) => window.said.push(`${event.target.id} ${name}`));
        }
        """, world: page)
        let field = try await openMenu("username")
        XCTAssertEqual(stage.heard.compactMap { $0["type"] as? String }, ["passkeys", "hello", "logins"],
                       "a mark asks once whether a passkey is near, and a menu asks for its list")
        XCTAssertEqual(stage.heard[2]["url"] as? String, "https://www.example.test/plain.html")
        XCTAssertTrue(stage.heard.allSatisfy { $0["v"] as? Int == 1 })

        try stage.click(row(0, under: field))
        try await stage.until("document.getElementById('password').value !== ''", world: page)
        let username = try await value("username")
        let password = try await value("password")
        XCTAssertEqual(username, ExtensionStage.username)
        XCTAssertEqual(password, ExtensionStage.password)
        let fill = try XCTUnwrap(fills.first)
        XCTAssertEqual(fills.count, 1)
        XCTAssertEqual(fill["id"] as? String, "one")
        XCTAssertEqual(fill["url"] as? String, "https://www.example.test/plain.html")
        let said = try await stage.js("return window.said", world: page) as? [String]
        XCTAssertEqual(said, ["username input", "username change", "password input", "password change"])
        try await stage.until("live('.card').length === 0")
    }

    func testAFormInTwoStepsTakesAUsernameAndThenAPassword() async throws {
        try await stage.load("two-steps")
        try await marks(1)
        var field = try await openMenu("username")
        try stage.click(row(0, under: field))
        try await stage.until("document.getElementById('username').value !== ''", world: page)
        let spoken = stage.asked.last { $0["kind"] as? String == "fill" }
        XCTAssertEqual(spoken?["wants"] as? [String], ["username"], "the password stays out of the page's script")

        try await stage.js("document.getElementById('form').requestSubmit()", world: page)
        try await stage.until("document.getElementById('password')", world: page)
        try await Task.sleep(nanoseconds: settle)
        try await marks(1)
        field = try await openMenu("password")
        try stage.click(row(0, under: field))
        try await stage.until("document.getElementById('password').value !== ''", world: page)
        let password = try await value("password")
        XCTAssertEqual(password, ExtensionStage.password)
    }

    func testAFieldThatReadsItsValueFromInputHearsIt() async throws {
        try await stage.load("react")
        try await marks(2)
        let field = try await openMenu("username")
        try stage.click(row(1, under: field))
        try await stage.until("window.state.password !== ''", world: page)
        let state = try await stage.js("return window.state", world: page) as? [String: String]
        XCTAssertEqual(state, ["username": ExtensionStage.username, "password": ExtensionStage.password])
    }

    func testAFormInAFrameOfTheSameSiteTakesARow() async throws {
        try await stage.load("framed", query: "?frame=login.example.test")
        try await stage.until("document.getElementById('frame')", world: page)
        for _ in 0..<500 where stage.frames["login.example.test"] == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let frame = try XCTUnwrap(stage.frames["login.example.test"])
        try await marks(2, in: frame)
        let around = try await stage.box(of: "frame")
        let inside = try await stage.box(of: "username", in: frame)
        let field = inside.offsetBy(dx: around.minX + 2, dy: around.minY + 2)
        try stage.click(mark(of: field))
        try await stage.until("live('.row').length === 3", in: frame)
        try await Task.sleep(nanoseconds: settle)
        XCTAssertEqual(stage.heard.last?["url"] as? String, "https://login.example.test/plain.html")
        try stage.click(row(0, under: field))
        try await stage.until("document.getElementById('password').value !== ''", world: page, in: frame)
        let password = try await value("password", in: frame)
        XCTAssertEqual(password, ExtensionStage.password)
    }

    func testAFormInAFrameOfAnotherSiteGetsNoMenu() async throws {
        try await stage.load("framed", query: "?frame=other.test")
        for _ in 0..<500 where stage.frames["other.test"] == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let frame = try XCTUnwrap(stage.frames["other.test"])
        try await stage.until("document.getElementById('password')", world: page, in: frame)
        try await Task.sleep(nanoseconds: settle)
        let drawn = try await stage.js("return live('.mark').length", in: frame) as? Int
        XCTAssertEqual(drawn, 0)
        XCTAssertEqual(stage.asked.compactMap { $0["kind"] as? String }.filter { !["landed", "passkeyNear"].contains($0) }, ["may"])
        XCTAssertEqual(heardOfTheFrame, [], "the app is not asked for such a frame")
    }

    func testAPageWithASearchBoxAndNoLoginIsLeftAlone() async throws {
        try await stage.load("search")
        try await Task.sleep(nanoseconds: settle)
        let drawn = try await stage.js("return live('.mark').length") as? Int
        XCTAssertEqual(drawn, 0)
        XCTAssertEqual(stage.asked.compactMap { $0["kind"] as? String }.sorted(), ["landed", "passkeyNear"],
                       "and all the app hears is whether a passkey is near, for the wrapper")
        XCTAssertEqual(heardOfTheFrame, [])
    }

    func testAPageWithAStrictPolicyStillDrawsTheMenu() async throws {
        try await stage.load("strict")
        try await marks(2)
        let field = try await openMenu("username")
        let ground = try await stage.js("return getComputedStyle(live('.card')[0]).borderRadius") as? String
        XCTAssertEqual(ground, "10px", "the style reached the shadow root")
        try stage.click(row(0, under: field))
        try await stage.until("document.getElementById('password').value !== ''", world: page)
    }

    func testAQuietPageIsNotLookedAtAgain() async throws {
        try await stage.load("plain")
        try await marks(2)
        try await Task.sleep(nanoseconds: settle)
        let before = try await stage.js("return looks") as? Int
        try await Task.sleep(nanoseconds: settle * 2)
        let after = try await stage.js("return looks") as? Int
        XCTAssertEqual(before, after, "drawing its own marks set the content script off again")
    }

    func testAMarkGoesWithItsField() async throws {
        try await stage.load("plain")
        try await marks(2)
        try await stage.js("document.getElementById('form').style.display = 'none'", world: page)
        try await marks(0)
    }

    func testReturnDoesNotReachTheFormWhileAFillWaits() async throws {
        var answers: [[String: Any]] = []
        stage.door = { message in
            if message["type"] as? String == "fill" { answers.append(message) }
            return ExtensionStage.openDoor(message)
        }
        try await stage.load("plain")
        try await marks(2)
        try await stage.js("document.getElementById('username').focus()", world: page)
        try stage.press(.down)
        try await stage.until("live('.row').length === 3")
        try await Task.sleep(nanoseconds: settle)
        try stage.press(.enter)
        try stage.press(.enter)
        try await stage.until("document.getElementById('password').value !== ''", world: page)
        try await Task.sleep(nanoseconds: settle)
        XCTAssertEqual(answers.count, 1)
        let submitted = try await stage.js("return window.submitted", world: page) as? Int
        XCTAssertEqual(submitted, 0)
    }

    // MARK: Where the mark goes

    private func drawn() async throws -> Int {
        try await stage.js("return live('.mark').length") as? Int ?? -1
    }

    /// How many marks are drawn once the page has had time to draw them.
    private func stands(_ form: String) async throws -> Int {
        try await stage.load(form)
        try await Task.sleep(nanoseconds: settle * 2)
        return try await drawn()
    }

    /// Whether each field by id stands under a mark, read from where a mark is.
    private func marked(_ ids: [String]) async throws -> [String: Bool] {
        var found: [String: Bool] = [:]
        for id in ids {
            found[id] = try await stage.js("""
            const box = document.getElementById("\(id)").getBoundingClientRect();
            const left = box.right - 22, top = box.top + (box.height - 16) / 2;
            return live(".mark").some((mark) => {
                const at = mark.getBoundingClientRect();
                return Math.abs(at.left - left) < 1 && Math.abs(at.top - top) < 1;
            });
            """) as? Bool
        }
        return found
    }

    func testASignUpWithANameAndAnEmailAndNoPasswordHasTheMark() async throws {
        let count = try await stands("signup-name")
        XCTAssertEqual(count, 1)
        let found = try await marked(["name", "username"])
        XCTAssertEqual(found, ["name": false, "username": true], "a newsletter's tick box does not make it a newsletter")
    }

    func testASignUpWithPasswordsHasAMarkOnEachOfThem() async throws {
        let count = try await stands("signup")
        XCTAssertEqual(count, 3)
        let found = try await marked(["name", "username", "password", "again"])
        XCTAssertEqual(found, ["name": false, "username": true, "password": true, "again": true])
    }

    func testAFormWithNoFormTakesARow() async throws {
        try await stage.load("no-form")
        try await marks(2)
        let field = try await openMenu("username")
        try stage.click(row(0, under: field))
        try await stage.until("document.getElementById('password').value !== ''", world: page)
        let username = try await value("username")
        XCTAssertEqual(username, ExtensionStage.username)
    }

    func testFieldsInOpenShadowRootsAreOneFormAndAClosedRootIsNot() async throws {
        try await stage.load("shadow")
        try await marks(2)
        let parts = try await stage.js("""
        const inner = (id) => document.getElementById(id).shadowRoot.getElementById("inner");
        const box = inner("first").getBoundingClientRect();
        return [box.left, box.top, box.width, box.height];
        """, world: page) as? [Double]
        let found = try XCTUnwrap(parts)
        let field = CGRect(x: found[0], y: found[1], width: found[2], height: found[3])
        try stage.click(mark(of: field))
        try await stage.until("live('.row').length === 3")
        try await Task.sleep(nanoseconds: settle)
        try stage.click(row(0, under: field))
        try await stage.until("document.getElementById('second').shadowRoot.getElementById('inner').value !== ''", world: page)
        let filled = try await stage.js("""
        const read = (id) => document.getElementById(id).shadowRoot.getElementById("inner").value;
        return [read("first"), read("second")];
        """, world: page) as? [String]
        XCTAssertEqual(filled, [ExtensionStage.username, ExtensionStage.password], "the form is around their roots")
    }

    func testAMarkKeepsToAFieldInARootWhenThePageRewritesIt() async throws {
        try await stage.load("shadow")
        try await marks(2)
        try await stage.js("""
        const root = document.getElementById("first").shadowRoot;
        root.getElementById("inner").remove();
        """, world: page)
        try await marks(1)
    }

    func testAFormThatArrivesAfterASecondHasTheMark() async throws {
        try await stage.load("after-load")
        let early = try await drawn()
        XCTAssertEqual(early, 0)
        try await marks(1)
    }

    func testTurkishLabelsSayALoginAndTurkishSearchesAndCodesDoNot() async throws {
        let count = try await stands("turkish")
        XCTAssertEqual(count, 3)
        let found = try await marked(["name", "secret", "address", "search", "sms"])
        XCTAssertEqual(found, ["name": true, "secret": true, "address": true, "search": false, "sms": false])
    }

    func testASearchBoxAFooterNewsletterACardAndACodeAreLeftAlone() async throws {
        let count = try await stands("not-a-login")
        XCTAssertEqual(count, 0)
        XCTAssertEqual(heardOfTheFrame, [], "the app hears nothing of such a page but the wrapper's one question")
    }

    func testTenThousandNodesCostAPageNothingItCouldFeel() async throws {
        try await stage.load("ten-thousand")
        try await marks(2)
        let nodes = try await stage.js("return window.nodes", world: page) as? Int
        XCTAssertGreaterThan(try XCTUnwrap(nodes), 10_000)
        func read() async throws -> [String: [Double]] {
            try await stage.js("return timings") as? [String: [Double]] ?? [:]
        }
        let first = try await read()
        try await stage.js("""
        window.changes = 0;
        const beat = setInterval(() => {
            const line = document.createElement("p");
            line.textContent = `line ${window.changes}`;
            document.getElementById("page").append(line);
            document.body.style.paddingTop = `${window.changes % 2}px`;
            window.changes += 1;
            if (window.changes === 100) clearInterval(beat);
        }, 20);
        """, world: page)
        try await stage.until("window.changes === 100", world: page, seconds: 20)
        try await Task.sleep(nanoseconds: settle)
        let after = try await read()
        let watching = (after["watching"] ?? []).dropFirst(first["watching"]?.count ?? 0)
        let looking = (after["looking"] ?? []).dropFirst(first["looking"]?.count ?? 0)
        let firstLook = first["looking"]?.max() ?? 0
        let spent = watching.reduce(0, +) + looking.reduce(0, +)
        let idle = try await stage.js("return typeof requestIdleCallback") as? String ?? ""
        let line = String(format: "%d nodes: first look %.2f ms; under 100 changes in 2 s, %d callbacks %.2f ms, %d looks %.2f ms, longest %.2f ms; requestIdleCallback is ",
                          nodes ?? 0, firstLook, watching.count, watching.reduce(0, +),
                          looking.count, looking.reduce(0, +), (watching + looking).max() ?? 0) + idle
        print("op83-measured: \(line)")
        try? line.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oripass-ten-thousand.txt"),
                        atomically: true, encoding: .utf8)
        XCTAssertLessThan(firstLook, 50, "the first look is the only one that walks the whole page")
        XCTAssertLessThan(spent, 2000 * 0.05, "under a twentieth of the two seconds that page was changing")
        XCTAssertLessThan((watching + looking).max() ?? 0, 16, "no look is longer than a frame")
    }

    func testAPageThatHoldsStillIsNotWalkedAgain() async throws {
        try await stage.load("ten-thousand")
        try await marks(2)
        let walked = try await stage.js("""
        let walks = 0;
        const all = Document.prototype.querySelectorAll;
        Document.prototype.querySelectorAll = function (selector) {
            if (selector === "*") walks += 1;
            return all.call(this, selector);
        };
        document.body.style.paddingTop = "1px";
        await new Promise((done) => setTimeout(done, 500));
        return walks;
        """) as? Int
        XCTAssertEqual(walked, 0, "a change of style has nothing new to walk")
    }

    // MARK: A field with no login for the site

    private func opened(_ form: String, door: @escaping ([String: Any]) -> [String: Any]? = ExtensionStage.noLogins,
                        field id: String, rows: Int) async throws -> CGRect {
        stage.door = door
        try await stage.load(form)
        try await stage.until("live('.mark').length > 0")
        let field = try await stage.box(of: id)
        try stage.click(mark(of: field))
        try await stage.until("live('.row').length === \(rows)")
        try await Task.sleep(nanoseconds: settle)
        return field
    }

    private var askedUsernames: [[String: Any]] { stage.heard.filter { $0["type"] as? String == "usernames" } }

    func testAnEmailFieldWithNoLoginOffersTheAddressesAlreadyUsed() async throws {
        let field = try await opened("signup-name", field: "username", rows: 2)
        XCTAssertEqual(askedUsernames.first?["address"] as? Bool, true)
        XCTAssertEqual(askedUsernames.first?["url"] as? String, "https://www.example.test/signup-name.html")
        let names = try await stage.js("return live('.row').map((row) => row.getAttribute('aria-label'))") as? [String]
        XCTAssertEqual(names, [ExtensionStage.username, "kanarya-work@example.test"])
        let heading = try await stage.js("return live('.heading')[0].textContent") as? String
        XCTAssertEqual(heading, "Used in your vault")
        try stage.click(CGPoint(x: field.minX + 60, y: field.maxY + 4 + 6 + 22 + 16 + 32))
        try await stage.until("document.getElementById('username').value !== ''", world: page)
        let username = try await value("username")
        XCTAssertEqual(username, "kanarya-work@example.test")
        XCTAssertTrue(fills.isEmpty, "a word is filled with nothing asked of the door")
        try await stage.until("live('.card').length === 0")
    }

    func testAUsernameFieldIsOfferedEveryWord() async throws {
        _ = try await opened("no-form", field: "username", rows: 3)
        XCTAssertNil(askedUsernames.first?["address"])
    }

    func testAClickInAnEmptyFieldOpensTheWordsAndAClickOnSomethingTypedDoesNot() async throws {
        stage.door = ExtensionStage.noLogins
        try await stage.load("signup-name")
        try await marks(1)
        let field = try await stage.box(of: "username")
        try stage.click(CGPoint(x: field.minX + 20, y: field.midY))
        try await stage.until("live('.row').length === 2")
        try stage.press(.escape)
        try await stage.until("live('.card').length === 0")
        try await stage.js("document.getElementById('username').value = 'kanarya'", world: page)
        try stage.click(CGPoint(x: field.minX + 40, y: field.midY))
        try await Task.sleep(nanoseconds: settle)
        let shown = try await stage.js("return live('.card').length") as? Int
        XCTAssertEqual(shown, 0)
    }

    func testALoginForTheSiteComesBeforeAnyWord() async throws {
        _ = try await opened("signup-name", door: ExtensionStage.openDoor, field: "username", rows: 3)
        XCTAssertTrue(askedUsernames.isEmpty)
    }

    func testAFieldInASignUpMakesAPasswordThroughTheDoorIntoBothFields() async throws {
        let field = try await opened("signup", field: "again", rows: 1)
        XCTAssertTrue(stage.heard.allSatisfy { $0["type"] as? String != "generate" }, "not before it is chosen")
        let name = try await stage.js("return live('.row')[0].getAttribute('aria-label')") as? String
        XCTAssertEqual(name, "Make a strong password")
        try stage.click(row(0, under: field))
        try await stage.until("document.getElementById('password').value !== ''", world: page)
        let both = [try await value("password"), try await value("again")]
        XCTAssertEqual(both, [ExtensionStage.generated, ExtensionStage.generated])
        XCTAssertEqual(stage.heard.last?["url"] as? String, "https://www.example.test/signup.html")
    }

    func testAFieldsLimitGoesToTheDoor() async throws {
        let field = try await opened("signup", field: "password", rows: 1)
        try await stage.js("document.getElementById('again').maxLength = 16", world: page)
        try stage.click(row(0, under: field))
        try await stage.until("document.getElementById('password').value !== ''", world: page)
        XCTAssertEqual(stage.heard.last?["most"] as? Int, 16)
    }

    func testAPageWithAPasswordMadeHereAsksToSaveItWhenItIsSent() async throws {
        let field = try await opened("signup", field: "password", rows: 1)
        try stage.click(row(0, under: field))
        try await stage.until("document.getElementById('password').value !== ''", world: page)
        try await stage.js("document.getElementById('username').value = '\(ExtensionStage.username)'", world: page)
        try stage.click(CGPoint(x: try await stage.box(of: "send").midX, y: try await stage.box(of: "send").midY))
        try await stage.until("live('.toast').length === 1")
    }

    func testAPasswordFieldWithNoLoginOffersTheGeneratorOnlyWhenAskedByHand() async throws {
        stage.door = ExtensionStage.noLogins
        try await stage.load("plain")
        try await marks(2)
        let field = try await stage.box(of: "password")
        try stage.click(CGPoint(x: field.minX + 20, y: field.midY))
        try await Task.sleep(nanoseconds: settle)
        let quiet = try await stage.js("return live('.card').length") as? Int
        XCTAssertEqual(quiet, 0)
        try stage.click(mark(of: field))
        try await stage.until("live('.row').length === 1")
    }

    func testASiteThatPutsNewPasswordOnASignInStillFills() async throws {
        stage.door = ExtensionStage.openDoor
        try await stage.load("plain")
        try await stage.js("document.getElementById('password').autocomplete = 'new-password'", world: page)
        try await marks(2)
        let field = try await stage.box(of: "password")
        try stage.click(mark(of: field))
        try await stage.until("live('.row').length === 4")
        try await Task.sleep(nanoseconds: settle)
        try stage.click(row(1, under: field))
        try await stage.until("document.getElementById('password').value !== ''", world: page)
        let password = try await value("password")
        XCTAssertEqual(password, ExtensionStage.password, "the generator leads, and the site's logins are still there")
    }

    func testAnEngineThatMadeNothingSaysSo() async throws {
        stage.door = { message in
            message["type"] as? String == "generate" ? ["v": 1, "type": "refused", "reason": "unmade"]
                : ExtensionStage.noLogins(message)
        }
        try await stage.load("signup")
        try await marks(3)
        let field = try await stage.box(of: "password")
        try stage.click(mark(of: field))
        try await stage.until("live('.row').length === 1")
        try await Task.sleep(nanoseconds: settle)
        try stage.click(row(0, under: field))
        try await stage.until("live('.line').some((line) => !line.hidden && line.textContent === 'OriPass could not make a password just now.')")
    }

    func testOnlyTheWordsLeaveTheBackgroundPage() async throws {
        stage.door = { message in
            guard message["type"] as? String == "usernames" else { return ExtensionStage.openDoor(message) }
            return ["v": 1, "type": "usernames", "usernames": ["kanarya", 3, ["password": "kanarya-stray"]]]
        }
        let answer = try await stage.deliver(["kind": "usernames"], from: sender(top))
        XCTAssertEqual(answer["usernames"] as? [String], ["kanarya"])
        XCTAssertEqual(Set(answer.keys), ["state", "usernames"])
    }

    func testAFrameOfAnotherSiteIsOfferedNothing() async throws {
        let wrong = sender("https://other.test/", frame: 7, top: "https://another.co.uk/")
        for kind in ["usernames", "generate"] {
            let answer = try await stage.deliver(["kind": kind], from: wrong)
            XCTAssertEqual(answer["state"] as? String, "refused", kind)
        }
        XCTAssertTrue(stage.heard.isEmpty)
    }

    func testAPageReadsNothingOfTheWords() async throws {
        _ = try await opened("signup-name", field: "username", rows: 2)
        let read = try await stage.js("""
        return {
            html: document.documentElement.outerHTML.includes("kanarya"),
            found: window.find("kanarya-user"),
        };
        """, world: page) as? [String: Any]
        XCTAssertEqual(read?["html"] as? Bool, false)
        XCTAssertEqual(read?["found"] as? Bool, false)
    }

    // MARK: What a page can reach

    func testAPageReadsNothingOfTheMenu() async throws {
        try await stage.load("plain")
        try await marks(2)
        _ = try await openMenu("username")
        let read = try await stage.js("""
        const hosts = Array.from(document.querySelectorAll("*"));
        return {
            roots: hosts.filter((element) => element.shadowRoot !== null).length,
            html: document.documentElement.outerHTML.includes("kanarya"),
            text: document.documentElement.textContent.includes("Canary"),
            found: window.find("kanarya-user") || window.find("Canary Mail"),
            size: hosts.filter((element) => element.parentElement === document.documentElement
                && element.tagName === "DIV").map((element) => element.offsetHeight),
        };
        """, world: page) as? [String: Any]
        XCTAssertEqual(read?["roots"] as? Int, 0)
        XCTAssertEqual(read?["html"] as? Bool, false)
        XCTAssertEqual(read?["text"] as? Bool, false)
        XCTAssertEqual(read?["found"] as? Bool, false, "window.find reaches into a shadow root it cannot read")
        XCTAssertEqual(read?["size"] as? [Int], [0, 0, 0], "not even the height of the rows")
    }

    func testASyntheticClickOrKeyFillsNothing() async throws {
        try await stage.load("plain")
        try await marks(2)
        _ = try await openMenu("username")
        try await stage.js("""
        const field = document.getElementById("username");
        for (const key of ["ArrowDown", "Enter"]) {
            field.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true }));
        }
        for (const element of document.documentElement.children) {
            element.click();
            element.dispatchEvent(new MouseEvent("click", { bubbles: true, composed: true }));
        }
        """, world: page)
        try await stage.js("""
        for (const row of live(".row")) {
            row.click();
            row.dispatchEvent(new MouseEvent("click", { bubbles: true, composed: true }));
        }
        """)
        try await Task.sleep(nanoseconds: settle)
        XCTAssertTrue(fills.isEmpty)
        let username = try await value("username")
        XCTAssertEqual(username, "")
    }

    func testARowCannotBeChosenWhileAPageHasMadeItUnseen() async throws {
        try await stage.load("plain")
        try await marks(2)
        let field = try await openMenu("username")
        try await stage.js("document.documentElement.style.opacity = '0.01'", world: page)
        try stage.click(row(0, under: field))
        try await stage.until("live('.card').length === 0")
        XCTAssertTrue(fills.isEmpty)
    }

    func testARowCannotBeChosenTheMomentItAppears() async throws {
        try await stage.load("plain")
        try await marks(2)
        let field = try await stage.box(of: "username")
        try stage.click(mark(of: field))
        try await stage.until("live('.row').length === 3")
        try stage.click(row(0, under: field))
        try await Task.sleep(nanoseconds: settle)
        XCTAssertTrue(fills.isEmpty)
    }

    // MARK: The background page

    private let top = "https://www.example.test/login"
    private func sender(_ url: String, frame: Int = 0, top: String? = nil) -> [String: Any] {
        ["url": url, "frameId": frame, "tab": ["id": 1, "url": top ?? self.top]]
    }

    func testAFillFromAnotherPageThanTheListsIsRefused() async throws {
        let list = try await stage.deliver(["kind": "list"], from: sender(top))
        XCTAssertEqual(list["state"] as? String, "ready")
        XCTAssertEqual((list["logins"] as? [Any])?.count, 3)

        for wrong in ["https://www.example.test/other", "https://elsewhere.test/login"] {
            let answer = try await stage.deliver(["kind": "fill", "id": "one", "wants": ["password"]],
                                                 from: sender(wrong, top: wrong))
            XCTAssertEqual(answer["state"] as? String, "refused", wrong)
            XCTAssertEqual(answer["reason"] as? String, "page")
        }
        XCTAssertTrue(fills.isEmpty)

        let fragment = try await stage.deliver(["kind": "fill", "id": "one", "wants": ["password"]],
                                               from: sender(top + "#step", top: top + "#step"))
        XCTAssertEqual(fragment["password"] as? String, ExtensionStage.password)
        XCTAssertEqual(fills.first?["url"] as? String, top + "#step")
    }

    func testTheAddressIsTheSendersAndNeverTheScripts() async throws {
        _ = try await stage.deliver(["kind": "list", "url": "https://elsewhere.test/"], from: sender(top))
        XCTAssertEqual(stage.heard.last?["url"] as? String, top)
        _ = try await stage.deliver(["kind": "fill", "id": "one", "url": "https://elsewhere.test/", "wants": ["password"]],
                                    from: sender(top))
        XCTAssertEqual(fills.first?["url"] as? String, top)
    }

    func testAFillOfWhatWasNotListedOrWithNoListIsRefused() async throws {
        let unlisted = try await stage.deliver(["kind": "fill", "id": "one", "wants": ["password"]], from: sender(top))
        XCTAssertEqual(unlisted["state"] as? String, "stale", "an unloaded background page has no list")
        _ = try await stage.deliver(["kind": "list"], from: sender(top))
        let other = try await stage.deliver(["kind": "fill", "id": "nine", "wants": ["password"]], from: sender(top))
        XCTAssertEqual(other["state"] as? String, "refused")
        XCTAssertTrue(fills.isEmpty)
    }

    func testAFrameOfAnotherSiteIsRefusedHoweverItAsks() async throws {
        for host in ["https://other.test/", "https://example.co.uk/"] {
            let wrong = sender(host, frame: 7, top: "https://another.co.uk/")
            let may = try await stage.deliver(["kind": "may"], from: wrong)
            XCTAssertEqual(may["may"] as? Bool, false, host)
            let list = try await stage.deliver(["kind": "list"], from: wrong)
            XCTAssertEqual(list["state"] as? String, "refused", host)
        }
        XCTAssertTrue(stage.heard.isEmpty)
        let scheme = try await stage.deliver(["kind": "may"], from: sender("http://www.example.test/", frame: 7))
        XCTAssertEqual(scheme["may"] as? Bool, false)
        let same = try await stage.deliver(["kind": "may"], from: sender("https://a.b.example.test/", frame: 7))
        XCTAssertEqual(same["may"] as? Bool, true)
    }

    func testOnlyWhatAListIsMadeOfAndWhatWasWantedLeavesTheBackgroundPage() async throws {
        stage.door = { message in
            var answer = ExtensionStage.openDoor(message)
            if message["type"] as? String == "logins" {
                answer?["logins"] = [["id": "one", "title": "A", "username": "b", "password": "kanarya-stray"]]
            }
            return answer
        }
        let list = try await stage.deliver(["kind": "list"], from: sender(top))
        XCTAssertEqual(list["logins"] as? [[String: String]], [["id": "one", "title": "A", "username": "b"]])
        let filled = try await stage.deliver(["kind": "fill", "id": "one", "wants": ["username"]], from: sender(top))
        XCTAssertEqual(Set(filled.keys), ["state", "username"], "no password and no code")
    }

    func testTheDoorsStatusesComeBackAsTheyAre() async throws {
        for status in ["locked", "unknown", "closed"] {
            stage.door = { _ in ["v": 1, "type": status] }
            let answer = try await stage.deliver(["kind": "list"], from: sender(top))
            XCTAssertEqual(answer["state"] as? String, status)
        }
        stage.door = { _ in nil }
        let gone = try await stage.deliver(["kind": "list"], from: sender(top))
        XCTAssertEqual(gone["state"] as? String, "closed", "no host at all is an app that is not open")
    }

    /// `siteOf` is `PublicSuffix.site(of:)` a second time, since an extension
    /// cannot import the app, so the two are held to each other.
    func testASiteIsWhatTheAppCallsASite() async throws {
        let hosts = ["www.example.com", "isbank.com.tr", "garanti.com.tr", "a.b.example.co.uk", "foo.github.io",
                     "github.io", "www.ck", "a.www.ck", "b.c.ck", "com", "localhost", "xn--fiq228c.com",
                     "a.xn--55qx5d.cn", "example.test"]
        for host in hosts {
            let site = try await stage.background.callAsyncJavaScript(
                "return siteOf(host, await loadSuffixes())", arguments: ["host": host], in: nil, contentWorld: .page
            )
            XCTAssertEqual(site as? String, PublicSuffix.standard.site(of: host), host)
        }
    }

    // MARK: Keyboard alone, and what VoiceOver hears

    func testTheKeyboardAloneOpensMovesFillsAndCloses() async throws {
        try await stage.load("plain")
        try await marks(2)
        try await stage.js("document.getElementById('username').focus()", world: page)
        try stage.press(.down)
        try await stage.until("live('.row').length === 3")
        try await Task.sleep(nanoseconds: settle)
        try stage.press(.down)
        try await stage.until("live('.row')[1].getAttribute('aria-selected') === 'true'")
        try stage.press(.up)
        try await stage.until("live('.row')[0].getAttribute('aria-selected') === 'true'")
        try stage.press(.up)
        try await stage.until("live('.row')[2].getAttribute('aria-selected') === 'true'", seconds: 2)
        try stage.press(.down)
        try await stage.until("live('.row')[0].getAttribute('aria-selected') === 'true'")
        try stage.press(.escape)
        try await stage.until("live('.card').length === 0")

        try stage.press(.down)
        try await stage.until("live('.row').length === 3")
        try stage.press(.tab)
        try await stage.until("live('.card').length === 0")

        try await stage.js("document.getElementById('username').focus()", world: page)
        try stage.press(.down)
        try await stage.until("live('.row').length === 3")
        try await Task.sleep(nanoseconds: settle)
        try stage.press(.down)
        try await stage.until("live('.row')[1].getAttribute('aria-selected') === 'true'")
        try stage.press(.enter)
        try await stage.until("document.getElementById('password').value !== ''", world: page)
        XCTAssertEqual(fills.first?["id"] as? String, "two")
        let submitted = try await stage.js("return window.submitted", world: page) as? Int
        XCTAssertEqual(submitted, 0, "Return went to the menu and not the form")
    }

    func testVoiceOverHasANameForTheMenuAndEachRow() async throws {
        try await stage.load("plain")
        try await marks(2)
        _ = try await openMenu("username")
        let names = try await stage.js("""
        const rows = live("[role=option]");
        return {
            mark: live(".mark")[0].getAttribute("aria-label"),
            list: live("[role=listbox]")[0].getAttribute("aria-label"),
            rows: rows.map((row) => row.getAttribute("aria-label")),
            place: rows.map((row) => `${row.getAttribute("aria-posinset")} ${row.getAttribute("aria-setsize")}`),
            voice: live("[role=status]")[0].textContent,
            live: live("[role=status]")[0].getAttribute("aria-live"),
        };
        """) as? [String: Any]
        XCTAssertEqual(names?["mark"] as? String, "Show OriPass logins")
        XCTAssertEqual(names?["list"] as? String, "Logins for example.test")
        XCTAssertEqual(names?["rows"] as? [String], ["Canary Mail, \(ExtensionStage.username)",
                                                     "Canary Work, kanarya-other@example.test", "No Name"])
        XCTAssertEqual(names?["place"] as? [String], ["1 3", "2 3", "3 3"])
        XCTAssertEqual(names?["voice"] as? String, "Canary Mail, \(ExtensionStage.username), 1 of 3")
        XCTAssertEqual(names?["live"] as? String, "polite")

        try stage.press(.down)
        try await stage.until("live('[role=status]')[0].textContent.endsWith('2 of 3')")
    }

    func testUnderReduceMotionTheMenuFadesAndDoesNotTravel() throws {
        let style = try ExtensionStage.file("style.css")
        func block(after media: String) throws -> String {
            let start = try XCTUnwrap(style.range(of: "@media (prefers-reduced-motion: \(media))"))
            let rest = style[start.upperBound...]
            return String(rest[..<(rest.range(of: "@media") ?? rest.endIndex..<rest.endIndex).lowerBound])
        }
        let moving = try block(after: "no-preference")
        let plain = try block(after: "reduce")
        XCTAssertTrue(moving.contains("transform"))
        XCTAssertTrue(moving.contains("\(Int(Motion.quick.duration * 1000))ms"))
        XCTAssertFalse(plain.contains("transform"))
        XCTAssertTrue(plain.contains("\(Int(Motion.reducedDuration * 1000))ms linear"))

        let outside = style.components(separatedBy: "@media (prefers-reduced-motion")[0]
        XCTAssertFalse(outside.contains("transition"))
        XCTAssertFalse(outside.contains("animation:"), "motion is only under the two media rules")
        for name in ["content.js", "menu.js", "popup.js"] {
            XCTAssertFalse(try ExtensionStage.file(name).contains("smooth"), name)
        }
    }

    // MARK: What a popup says

    private func popupLine() async throws -> String? {
        let view = try XCTUnwrap(stage.popup)
        for _ in 0..<500 {
            let line = try await view.callAsyncJavaScript(
                "const line = document.querySelector('.line'); return line && !line.hidden ? line.textContent : null",
                arguments: [:], in: nil, contentWorld: .page
            ) as? String
            if let line, line != "Waiting for OriPass…" { return line }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    func testThePopupSaysWhatIsWrongInOneLine() async throws {
        try await stage.load("plain")
        for (status, line) in [("locked", "OriPass is locked. Unlock it to see this site's logins."),
                               ("closed", "OriPass is not open."),
                               ("unknown", "OriPass has not allowed this browser yet.")] {
            stage.door = { _ in ["v": 1, "type": status] }
            try await stage.openPopup()
            let said = try await popupLine()
            XCTAssertEqual(said, line)
        }
        stage.door = { message in
            message["type"] as? String == "hello" ? ["v": 1, "type": "ready"]
                : ["v": 1, "type": "logins", "site": "example.test", "logins": [[String: String]]()]
        }
        try await stage.openPopup()
        let empty = try await popupLine()
        XCTAssertEqual(empty, "No logins for this site.")
    }

    func testThePopupSaysItIsWaitingUntilTheDoorAnswers() async throws {
        stage.door = { _ in ["v": 1, "type": "locked"] }
        stage.doorTakes = 600_000_000
        try await stage.load("plain")
        try await stage.openPopup()
        let view = try XCTUnwrap(stage.popup)
        let drawn = try await view.callAsyncJavaScript("""
        const line = document.querySelector(".line");
        return { line: line.hidden ? null : line.textContent, keys: document.querySelector(".keys").hidden };
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(drawn?["line"] as? String, "Waiting for OriPass…")
        XCTAssertEqual(drawn?["keys"] as? Bool, true, "no keys for a list that is not there")
        let said = try await popupLine()
        XCTAssertEqual(said, "OriPass is locked. Unlock it to see this site's logins.")
    }

    func testAPopupRowFillsTheTabsForm() async throws {
        try await stage.load("plain")
        try await marks(2)
        try await stage.openPopup()
        let view = try XCTUnwrap(stage.popup)
        func popup(_ source: String) async throws -> Any? {
            try await view.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: .page)
        }
        for _ in 0..<500 {
            if try await popup("return document.querySelectorAll('.row').length") as? Int == 3 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // A popup's rows are clicked in a window of the browser's own, which
        // no page can reach, so this one is reached through its list.
        try await popup("list.press('ArrowDown'); list.press('Enter')")
        try await stage.until("document.getElementById('password').value !== ''", world: page)
        XCTAssertEqual(fills.first?["id"] as? String, "two")
        let closed = try await popup("return window.wasClosed") as? Bool
        XCTAssertEqual(closed, true)
        let wanted = stage.heard.filter { $0["type"] as? String == "fill" }.first?["url"] as? String
        XCTAssertEqual(wanted, "https://www.example.test/plain.html")
    }

    func testAPopupWithNoFormOnThePageAsksForNoPassword() async throws {
        try await stage.load("search")
        try await stage.openPopup()
        let view = try XCTUnwrap(stage.popup)
        for _ in 0..<500 {
            let rows = try await view.callAsyncJavaScript("return document.querySelectorAll('.row').length",
                                                          arguments: [:], in: nil, contentWorld: .page) as? Int
            if rows == 3 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        _ = try await view.callAsyncJavaScript("list.press('Enter')", arguments: [:], in: nil, contentWorld: .page)
        let said = try await popupLine()
        XCTAssertEqual(said, "There is no login form on this page.")
        XCTAssertTrue(fills.isEmpty)
    }

    func testARefusalIsSaidInOneLine() async throws {
        try await stage.load("plain")
        try await stage.openPopup()
        let view = try XCTUnwrap(stage.popup)
        for (reason, line) in [("page", "That login is not for this page."),
                               ("gone", "That login is no longer in the vault."),
                               ("insecure", "This page is not secure, and the login is saved for a secure one."),
                               ("declined", "OriPass was not told to fill that login."),
                               ("nothing the app says", "That login is not for this page.")] {
            let said = try await view.callAsyncJavaScript(
                "return sentence({ state: 'refused', reason: reason })", arguments: ["reason": reason],
                in: nil, contentWorld: .page
            ) as? String
            XCTAssertEqual(said, line)
        }
    }

    func testTheMarkSaysWhatIsWrongAndAClickInTheFieldDoesNot() async throws {
        stage.door = { _ in ["v": 1, "type": "locked"] }
        try await stage.load("plain")
        try await marks(2)
        let field = try await stage.box(of: "username")
        try stage.click(CGPoint(x: field.minX + 20, y: field.midY))
        try await stage.until("true")
        try await Task.sleep(nanoseconds: settle)
        let quiet = try await stage.js("return live('.card').length") as? Int
        XCTAssertEqual(quiet, 0)
        try stage.click(mark(of: field))
        try await stage.until("live('.line').length === 1 && !live('.line')[0].hidden")
        let line = try await stage.js("return live('.line')[0].textContent") as? String
        XCTAssertEqual(line, "OriPass is locked. Unlock it to see this site's logins.")
        XCTAssertFalse(stage.heard.contains { $0["type"] as? String == "logins" })
    }

    // MARK: What is in the folder

    /// Every custom property of `style.css` beside the colour it stands for.
    private func palette() -> [String: (Color, Double)] {
        ["--menu": (Palette.menu, 1), "--text": (Palette.text, 1), "--second-text": (Palette.secondText, 1),
         "--prompt": (Palette.prompt, 1), "--row-hover": (Palette.rowHover, 1), "--lit": (Palette.lit, 1),
         "--on-colour": (Palette.onColour, 1), "--on-selection": (Palette.onColour, Palette.quickOnSelection),
         "--outline": (Palette.outline, 1), "--hairline": (Palette.hairline, 1), "--shadow": (Palette.shadow, 1),
         "--accent": (Palette.accent, 1), "--cell": (Palette.cell, 1), "--band": (Palette.toastBand, 1),
         "--red": (Palette.red, 1), "--good": (Palette.good, 1)]
    }

    private func declared(in block: Substring) throws -> [String: Contrast.Parts] {
        var found: [String: Contrast.Parts] = [:]
        let hex = try NSRegularExpression(pattern: #"(--[a-z-]+): #([0-9A-F]{6});"#)
        let rgb = try NSRegularExpression(pattern: #"(--[a-z-]+): rgb\((\d+) (\d+) (\d+) / ([\d.]+)\);"#)
        let text = String(block)
        let whole = NSRange(text.startIndex..., in: text)
        func piece(_ match: NSTextCheckingResult, _ place: Int) -> String {
            String(text[Range(match.range(at: place), in: text)!])
        }
        for match in hex.matches(in: text, range: whole) {
            let value = UInt32(piece(match, 2), radix: 16)!
            found[piece(match, 1)] = (Double((value >> 16) & 255) / 255, Double((value >> 8) & 255) / 255,
                                      Double(value & 255) / 255, 1)
        }
        for match in rgb.matches(in: text, range: whole) {
            found[piece(match, 1)] = (Double(piece(match, 2))! / 255, Double(piece(match, 3))! / 255,
                                      Double(piece(match, 4))! / 255, Double(piece(match, 5))!)
        }
        return found
    }

    func testTheColoursAreThePalettes() throws {
        let style = try ExtensionStage.file("style.css")
        let dark = try XCTUnwrap(style.range(of: "@media (prefers-color-scheme: dark)"))
        let end = try XCTUnwrap(style.range(of: ".mark {"))
        let sides = [(style[..<dark.lowerBound], NSAppearance.Name.aqua),
                     (style[dark.upperBound..<end.lowerBound], .darkAqua)]
        for (block, appearance) in sides {
            let declared = try declared(in: block)
            XCTAssertEqual(Set(declared.keys), Set(palette().keys), "\(appearance.rawValue)")
            for (name, (colour, share)) in palette() {
                let wanted = Contrast.parts(of: colour, in: appearance)
                let written = try XCTUnwrap(declared[name], name)
                XCTAssertEqual(written.red, wanted.red, accuracy: 0.002, name)
                XCTAssertEqual(written.green, wanted.green, accuracy: 0.002, name)
                XCTAssertEqual(written.blue, wanted.blue, accuracy: 0.002, name)
                XCTAssertEqual(written.alpha, wanted.alpha * share, accuracy: 0.002, name)
            }
        }
    }

    func testTheManifestIsTheFormBothBrowsersTake() throws {
        let data = try Data(contentsOf: ExtensionStage.folder.appendingPathComponent("manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(manifest["manifest_version"] as? Int, 2)
        let background = try XCTUnwrap(manifest["background"] as? [String: Any])
        XCTAssertEqual(background["persistent"] as? Bool, false)
        XCTAssertEqual(manifest["permissions"] as? [String], ["nativeMessaging", "tabs", "storage", "alarms"])
        XCTAssertEqual(manifest["web_accessible_resources"] as? [String], ["wrapper.js"],
                       "a page can fetch nothing else of the extension's")
        let entries = try XCTUnwrap(manifest["content_scripts"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0]["all_frames"] as? Bool, true)
        XCTAssertEqual(entries[0]["js"] as? [String], ["menu.js", "fields.js", "typed.js", "toast.js", "content.js"])
        XCTAssertEqual(entries[1]["css"] as? [String], ["page.css"])
        XCTAssertEqual(entries[1]["all_frames"] as? Bool, false,
                       "a frame of another site has no mark, so it keeps the browser's key")
    }

    func testOnlyTheBackgroundPageSpeaksToTheApp() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: ExtensionStage.folder.path)
        XCTAssertTrue(names.contains("content.js"))
        for name in names where name.hasSuffix(".js") || name.hasSuffix(".html") || name.hasSuffix(".css") {
            let text = try ExtensionStage.file(name)
            XCTAssertEqual(text.contains("sendNativeMessage"), name == "background.js", name)
            XCTAssertFalse(text.contains("innerHTML"), name)
            XCTAssertFalse(text.contains("console."), name)
            XCTAssertEqual(text.contains("storage"), name == "background.js", name)
            XCTAssertFalse(text.contains("storage.local"), name)
            XCTAssertFalse(text.contains("localStorage"), name)
            for word in ["1Password", "Bitwarden"] { XCTAssertFalse(text.contains(word), name) }
        }
    }

    func testTheCopiesInTheFolderAreTheAppsOwn() throws {
        let root = ExtensionStage.root
        let list = "Vendor/psl/public_suffix_list.dat"
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(list)),
                       try Data(contentsOf: ExtensionStage.folder.appendingPathComponent("public_suffix_list.dat")))
        let icons = root.appendingPathComponent("Sources/Assets.xcassets/AppIcon.appiconset")
        for (name, source) in [("16", "icon_16x16"), ("32", "icon_32x32"), ("64", "icon_32x32@2x"), ("128", "icon_128x128")] {
            XCTAssertEqual(try Data(contentsOf: icons.appendingPathComponent("\(source).png")),
                           try Data(contentsOf: ExtensionStage.folder.appendingPathComponent("icons/\(name).png")), name)
        }
    }

    /// `make shots` draws what the app draws, and this is not that, so the
    /// shot of the menu is written beside the test's temp files to be read
    /// against `docs/look.md`.
    func testTheMenuDrawsInBothAppearances() async throws {
        try await stage.load("plain")
        try await marks(2)
        _ = try await openMenu("username")
        for dark in [false, true] {
            let url = try await stage.snapshot(named: "extension-menu", dark: dark)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    /// The mark and each new menu on a light page and a dark one, under each
    /// appearance of the Mac, which is two different things: the mark's colours
    /// come from the Mac and the field's from the page. The folder is
    /// `docs/toast/`'s source, as `ToastTests` has it.
    func testTheMarkAndTheMenusDrawOnLightAndDarkPages() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oripass-toast")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for pageIsDark in [false, true] {
            for (name, form, id, rows) in [("words", "signup-name", "username", 2), ("generator", "signup", "password", 1)] {
                _ = try await opened(form, field: id, rows: rows)
                try await stage.paintPage(dark: pageIsDark)
                for dark in [false, true] {
                    let shot = try await stage.snapshot(named: "field-\(name)", dark: dark)
                    let wanted = "field-\(name)-\(pageIsDark ? "dark" : "light")-page-\(dark ? "dark" : "light").png"
                    let target = folder.appendingPathComponent(wanted)
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.copyItem(at: shot, to: target)
                }
            }
        }
    }
}

/// `make extension`, into a folder of the test's own.
final class ExtensionZipTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let run = Process()
        run.executableURL = URL(fileURLWithPath: tool)
        run.arguments = arguments
        let said = Pipe()
        run.standardOutput = said
        run.standardError = said
        try run.run()
        let output = String(decoding: said.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        run.waitUntilExit()
        return (run.terminationStatus, output)
    }

    func testTheZipIsTheFolderWithItsManifestAtTheTop() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let zip = directory.appendingPathComponent("extension.zip")

        let made = try run("/usr/bin/make", ["-C", Self.root.path, "extension", "EXTENSION_ZIP=\(zip.path)"])
        XCTAssertEqual(made.status, 0, made.output)
        let listed = try run("/usr/bin/zipinfo", ["-1", zip.path])
        XCTAssertEqual(listed.status, 0, listed.output)
        let held = Set(listed.output.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/") })

        let folder = Self.root.appendingPathComponent("Extension")
        let files = try XCTUnwrap(FileManager.default.subpathsOfDirectory(atPath: folder.path) as [String]?)
            .filter { path in
                var isFolder: ObjCBool = false
                FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path, isDirectory: &isFolder)
                return !isFolder.boolValue && !path.hasPrefix(".") && !path.contains("/.")
            }
        XCTAssertEqual(held, Set(files))
        XCTAssertTrue(held.contains("manifest.json"), "the manifest is at the top, where a browser looks")
    }
}
