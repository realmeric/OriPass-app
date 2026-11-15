import AppKit
import WebKit
import XCTest
@testable import OriPass

/// What a page takes, and the toast that asks about it: `content.js`, the
/// background page and the door the stage plays, over the sign-in pages under
/// `Tests/Fixtures/forms/`. A press here is a real one, so `isTrusted` holds.
@MainActor
final class ToastTests: XCTestCase {
    private var stage: ExtensionStage!
    private let page = WKContentWorld.page
    private static let typed = "kanarya-typed-password"
    private static let user = "kanarya-new@example.test"

    /// Longer than a toast takes to come to rest and its drawing to play.
    private let rest: UInt64 = 1_500_000_000
    /// Longer than `settle`, and than the looks a page has to pass.
    private let settle: UInt64 = 300_000_000
    private let quiet: UInt64 = 1_500_000_000

    override func setUp() async throws {
        stage = ExtensionStage()
        try await stage.open()
    }

    override func tearDown() async throws {
        stage.close()
        stage = nil
    }

    // MARK: Driving a page

    private func fill(_ values: [String: String]) async throws {
        for (id, value) in values {
            try await stage.js("document.getElementById('\(id)').value = '\(value)'", world: page)
        }
    }

    private func press(_ id: String) async throws {
        try stage.click(CGPoint(x: try await stage.box(of: id).midX, y: try await stage.box(of: id).midY))
    }

    private func signIn(on form: String = "signin", password: String = typed) async throws {
        try await stage.load(form)
        try await fill(["username": Self.user, "password": password])
        try await press("send")
    }

    /// Up, come to rest and past the moment a button cannot be pressed in.
    private func toastIsUp() async throws {
        try await stage.until("live('.toast').length === 1"
            + " && live('.stand')[0].getAnimations().every((motion) => motion.playState === 'finished')")
        try await Task.sleep(nanoseconds: settle)
    }

    private func said(_ selector: String) async throws -> String? {
        try await stage.js("return live('\(selector)')[0]?.textContent") as? String
    }

    private func toastCount() async throws -> Int {
        try await stage.js("return live('.toast').length") as? Int ?? -1
    }

    /// A press of the first button of a class on the toast.
    private func pressToast(_ selector: String, at place: Int = 0) async throws {
        let parts = try await stage.js("""
        const box = live('\(selector)')[\(place)].getBoundingClientRect();
        return [box.left + box.width / 2, box.top + box.height / 2];
        """) as? [Double]
        let point = try XCTUnwrap(parts)
        try stage.click(CGPoint(x: point[0], y: point[1]))
    }

    private func asked(_ type: String) -> [[String: Any]] { stage.heard.filter { $0["type"] as? String == type } }

    private func held() async throws -> [String: Any] {
        try await stage.background.callAsyncJavaScript(
            "return Object.fromEntries(session)", arguments: [:], in: nil, contentWorld: .page
        ) as? [String: Any] ?? [:]
    }

    private func background(_ source: String) async throws -> Any? {
        try await stage.background.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: .page)
    }

    /// `known` answering this, with `locked` and the rest of the door as it is.
    private func answering(_ state: String, logins: [[String: String]] = []) {
        stage.door = { message in
            guard message["type"] as? String == "known" else { return ExtensionStage.openDoor(message) }
            return ["v": 1, "type": "known", "state": state, "site": "example.test", "logins": logins]
        }
    }

    private static let mail = ["id": "one", "title": "Canary Mail", "username": user]
    private static let work = ["id": "two", "title": "Canary Work", "username": "kanarya-other@example.test"]

    // MARK: Which pages ask

    func testASignInThatGoesThroughAsks() async throws {
        try await signIn()
        try await toastIsUp()
        let known = try XCTUnwrap(asked("known").first)
        XCTAssertEqual(known["url"] as? String, "https://www.example.test/signin.html")
        XCTAssertEqual(known["username"] as? String, Self.user)
        XCTAssertNil(known["password"], "the door is asked with a mark")
        let mark = try XCTUnwrap(known["mark"] as? String)
        XCTAssertEqual(Data(base64Encoded: mark)?.count, 32)
        XCTAssertFalse("\(known)".contains(Self.typed))
        let head = try await said(".head")
        XCTAssertEqual(head, "Save this login?")
        let lines = try await stage.js("return live('.line-of').map((line) => line.textContent)") as? [String]
        XCTAssertEqual(lines, ["example.test", Self.user])
    }

    func testTheMarkIsTheOneTheDoorWouldMake() async throws {
        try await signIn()
        try await toastIsUp()
        let known = try XCTUnwrap(asked("known").first)
        let key = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(known["key"] as? String)))
        let mark = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(known["mark"] as? String)))
        let typed = BridgeTyped(url: "https://www.example.test/", username: nil, key: key, mark: mark)
        XCTAssertTrue(SaveDoor.holds(typed, password: Self.typed))
        XCTAssertFalse(SaveDoor.holds(typed, password: "kanarya-another"))
    }

    func testASignUpWithTwoPasswordFieldsAsks() async throws {
        try await stage.load("signup")
        try await fill(["name": "Ada", "username": Self.user, "password": Self.typed, "again": Self.typed])
        try await press("send")
        try await toastIsUp()
        XCTAssertEqual(asked("known").first?["username"] as? String, Self.user, "the email and not the name")
        try await pressToast(".lit")
        try await stage.until("live('.toast')[0]?.dataset.state === 'saved'")
        let save = try XCTUnwrap(asked("save").first)
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(save["password"] as? String)), Data(Self.typed.utf8))
    }

    func testASignUpWhoseTwoPasswordsDifferDoesNotAsk() async throws {
        try await stage.load("signup")
        try await fill(["username": Self.user, "password": Self.typed, "again": "kanarya-else"])
        try await press("send")
        try await stage.until("document.title === 'Home'", world: page)
        try await Task.sleep(nanoseconds: quiet)
        let count = try await toastCount()
        XCTAssertEqual(count, 0)
        XCTAssertTrue(asked("known").isEmpty)
    }

    func testAChangedPasswordIsTheNewOneOfTheThree() async throws {
        answering("update", logins: [Self.mail])
        try await stage.load("change")
        try await fill(["old": "kanarya-old", "password": Self.typed, "again": Self.typed])
        try await press("send")
        try await toastIsUp()
        XCTAssertNil(asked("known").first?["username"], "this form has none")
        try await pressToast(".lit")
        try await stage.until("live('.toast')[0]?.dataset.state === 'saved'")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(asked("save").first?["password"] as? String)),
                       Data(Self.typed.utf8))
    }

    func testASignInThatComesBackDoesNotAsk() async throws {
        try await signIn(on: "refused")
        try await stage.until("document.getElementById('username').value === ''", world: page)
        try await Task.sleep(nanoseconds: quiet)
        let count = try await toastCount()
        XCTAssertEqual(count, 0)
        XCTAssertTrue(asked("known").isEmpty)
    }

    func testASinglePageAppAsksWhenTheAddressMoves() async throws {
        try await signIn(on: "single-page")
        try await toastIsUp()
        XCTAssertEqual(asked("known").first?["url"] as? String, "https://www.example.test/single-page.html",
                       "the page the password was typed on")
    }

    func testASinglePageAppThatRefusesDoesNotAsk() async throws {
        try await signIn(on: "single-page", password: "wrong")
        try await Task.sleep(nanoseconds: quiet)
        let count = try await toastCount()
        XCTAssertEqual(count, 0)
        XCTAssertTrue(asked("known").isEmpty)
    }

    func testAFormInTwoStepsKeepsTheUsernameForTheSecond() async throws {
        try await stage.load("steps")
        try await fill(["username": Self.user])
        try await press("send")
        try await stage.until("document.getElementById('password')", world: page)
        try await Task.sleep(nanoseconds: quiet)
        let early = try await toastCount()
        XCTAssertEqual(early, 0, "a username alone asks nothing")
        try await fill(["password": Self.typed])
        try await press("send")
        try await toastIsUp()
        XCTAssertEqual(asked("known").first?["username"] as? String, Self.user)
    }

    func testASignInRefusedAndThenLeftDoesNotAsk() async throws {
        try await signIn(on: "single-page", password: "wrong")
        try await Task.sleep(nanoseconds: settle)
        try await stage.js("""
        const field = document.getElementById("password");
        field.value = "kanarya-try";
        field.dispatchEvent(new InputEvent("input", { bubbles: true, composed: true }));
        """, world: page)
        try await stage.until("true")
        let left = try await held()
        XCTAssertTrue(left.isEmpty, "typing again says the last one did not go through")
        try await stage.js("history.pushState({}, '', '/elsewhere'); document.getElementById('root').remove()", world: page)
        try await Task.sleep(nanoseconds: quiet)
        let count = try await toastCount()
        XCTAssertEqual(count, 0)
        XCTAssertTrue(asked("known").isEmpty)
    }

    func testAFormThatComesBackIsForgottenAndLeavingLaterDoesNotAsk() async throws {
        try await signIn(on: "refused")
        try await stage.until("document.getElementById('username').value === ''", world: page)
        for _ in 0..<200 {
            if try await held().isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let left = try await held()
        XCTAssertTrue(left.isEmpty)
    }

    func testAToastOverAShutVaultIsNotDrawnAgainEachTimeItAsks() async throws {
        stage.door = { _ in ["v": 1, "type": "locked"] }
        try await signIn()
        try await toastIsUp()
        try await stage.js("live('.head')[0].dataset.first = 'yes'")
        let asks = asked("known").count
        for _ in 0..<300 where asked("known").count == asks { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertGreaterThan(asked("known").count, asks, "it asked again")
        let same = try await stage.js("return live('.head')[0].dataset.first") as? String
        XCTAssertEqual(same, "yes")
    }

    func testAToastDrawsUnderAStrictPolicyWithTheSitesIcon() async throws {
        let icon = try Data(contentsOf: ExtensionStage.root.appendingPathComponent("Tests/Fixtures/icon-globe.png"))
        stage.door = { message in
            guard message["type"] as? String == "known" else { return ExtensionStage.openDoor(message) }
            return ["v": 1, "type": "known", "state": "new", "site": "example.test",
                    "logins": [[String: String]](), "icon": icon.base64EncodedString()]
        }
        try await stage.load("strict")
        try await fill(["username": Self.user, "password": Self.typed])
        try await press("send")
        for _ in 0..<250 where !stage.asked.contains(where: { $0["kind"] as? String == "typed" }) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await stage.js("document.querySelector('form').remove()", world: page)
        try await toastIsUp()
        try await stage.until("live('.face canvas').length === 1")
        let radius = try await stage.js("return getComputedStyle(live('.toast')[0]).borderRadius") as? String
        XCTAssertEqual(radius, "16px", "the style reached the shadow root")
        let width = try await stage.js("return live('.scene')[0].getBoundingClientRect().width") as? Double
        XCTAssertEqual(width, 372)
    }

    /// The page fills its own form and sends it as it loads. A script run
    /// from a test counts as a person's act, so this one is the page's.
    func testAPageNobodyTouchedAsksNothing() async throws {
        try await stage.load("by-itself")
        try await stage.until("document.title === 'Sent'", world: page)
        try await Task.sleep(nanoseconds: quiet)
        XCTAssertFalse(stage.asked.contains { $0["kind"] as? String == "typed" })
        let held = try await held()
        XCTAssertTrue(held.isEmpty)
    }

    // MARK: What each answer shows

    func testThePasswordItHasAndANeverSiteShowNothing() async throws {
        for state in ["same", "never"] {
            answering(state)
            try await signIn()
            try await stage.until("document.title === 'Home'", world: page)
            try await Task.sleep(nanoseconds: quiet)
            let count = try await toastCount()
            XCTAssertEqual(count, 0, state)
            let left = try await held()
            XCTAssertTrue(left.isEmpty, "answered, and wiped: \(state)")
        }
    }

    func testAnUpdateNamesTheLoginAndOffersBoth() async throws {
        answering("update", logins: [Self.mail])
        try await signIn()
        try await toastIsUp()
        let lines = try await stage.js("return live('.line-of').map((line) => line.textContent)") as? [String]
        XCTAssertEqual(lines, ["Canary Mail", Self.user])
        let words = try await stage.js("return live('.buttons button').map((button) => button.textContent)") as? [String]
        XCTAssertEqual(words, ["Save as New", "Update"])
        try await pressToast(".lit")
        try await stage.until("live('.toast')[0]?.dataset.state === 'saved'")
        XCTAssertEqual(asked("save").first?["id"] as? String, "one")
        let head = try await said(".head")
        XCTAssertEqual(head, "Password changed")
    }

    func testSaveAsNewSendsNoId() async throws {
        answering("update", logins: [Self.mail])
        try await signIn()
        try await toastIsUp()
        try await pressToast(".plain")
        try await stage.until("live('.toast')[0]?.dataset.state === 'saved'")
        XCTAssertNil(asked("save").first?["id"])
        let head = try await said(".head")
        XCTAssertEqual(head, "Login saved")
    }

    func testSeveralLoginsAreAMenu() async throws {
        answering("choose", logins: [Self.mail, Self.work])
        try await signIn()
        try await toastIsUp()
        let rows = try await stage.js("return live('.choice').map((row) => row.textContent)") as? [String]
        XCTAssertEqual(rows?.count, 2)
        try await pressToast(".choice", at: 1)
        try await stage.until("live('.toast')[0]?.dataset.state === 'saved'")
        XCTAssertEqual(asked("save").first?["id"] as? String, "two")
    }

    func testARefusedFingerStaysAndCanBeAskedAgain() async throws {
        var refused = true
        stage.door = { message in
            switch message["type"] as? String {
            case "known":
                return ["v": 1, "type": "known", "state": "update", "site": "example.test", "logins": [Self.mail]]
            case "save" where refused:
                refused = false
                return ["v": 1, "type": "refused", "reason": "declined"]
            default:
                return ExtensionStage.openDoor(message)
            }
        }
        try await signIn()
        try await toastIsUp()
        try await pressToast(".lit")
        try await stage.until("live('.note.refused')[0]?.hidden === false")
        let kept = try await held()
        XCTAssertEqual(kept.count, 1, "still held for another try")
        try await pressToast(".lit")
        try await stage.until("live('.toast')[0]?.dataset.state === 'saved'")
        let left = try await held()
        XCTAssertTrue(left.isEmpty)
    }

    func testNotNowWipesAndNeverSendsTheHostAndWipes() async throws {
        try await signIn()
        try await toastIsUp()
        try await pressToast(".quiet", at: 0)
        try await stage.until("live('.toast').length === 0")
        let left = try await held()
        XCTAssertTrue(left.isEmpty)
        XCTAssertTrue(asked("save").isEmpty)

        try await signIn()
        try await toastIsUp()
        try await pressToast(".quiet", at: 1)
        try await stage.until("live('.toast').length === 0")
        XCTAssertEqual(asked("never").first?["url"] as? String, "https://www.example.test/signin.html")
        let after = try await held()
        XCTAssertTrue(after.isEmpty)
    }

    func testOverAShutVaultItSaysSoAndAsksWhenTheVaultOpens() async throws {
        var isShut = true
        stage.door = { message in
            isShut ? ["v": 1, "type": "locked"] : ExtensionStage.openDoor(message)
        }
        try await signIn()
        try await toastIsUp()
        let head = try await said(".head")
        XCTAssertEqual(head, "OriPass is locked")
        let buttons = try await stage.js("return live('.lit').length") as? Int
        XCTAssertEqual(buttons, 0, "nothing can be sent until the door says what this is")
        isShut = false
        try await stage.until("live('.toast')[0]?.dataset.state === 'new'", seconds: 8)
        XCTAssertTrue(asked("save").isEmpty, "only a click sends it")
        try await Task.sleep(nanoseconds: settle)
        try await pressToast(".lit")
        try await stage.until("live('.toast')[0]?.dataset.state === 'saved'")
        XCTAssertEqual(asked("save").count, 1)
    }

    func testTheToastComesAfterEveryPageOfARedirectUntilItIsAnswered() async throws {
        try await signIn()
        try await toastIsUp()
        try await stage.load("home")
        try await toastIsUp()
        XCTAssertEqual(asked("known").last?["url"] as? String, "https://www.example.test/signin.html")
    }

    func testAFrameOfAnotherSiteHoldsNothing() async throws {
        let frame: [String: Any] = ["url": "https://other.test/", "frameId": 7,
                                    "tab": ["id": 1, "url": "https://www.example.test/"]]
        let answer = try await stage.deliver(["kind": "typed", "username": Self.user, "password": Self.typed], from: frame)
        XCTAssertEqual(answer["held"] as? Bool, false)
        let held = try await held()
        XCTAssertTrue(held.isEmpty)
    }

    func testASaveOrANeverFromAFrameIsRefused() async throws {
        let top: [String: Any] = ["url": "https://www.example.test/", "frameId": 0,
                                  "tab": ["id": 1, "url": "https://www.example.test/"]]
        try await stage.deliver(["kind": "typed", "password": Self.typed], from: top)
        var frame = top
        frame["frameId"] = 7
        let answer = try await stage.deliver(["kind": "save"], from: frame)
        XCTAssertEqual(answer["state"] as? String, "refused")
        try await stage.deliver(["kind": "never"], from: frame)
        XCTAssertTrue(asked("save").isEmpty)
        XCTAssertTrue(asked("never").isEmpty)
    }

    func testTheSiteIsTheSendersAndNeverTheScripts() async throws {
        let top: [String: Any] = ["url": "https://www.example.test/", "frameId": 0,
                                  "tab": ["id": 1, "url": "https://www.example.test/"]]
        try await stage.deliver(["kind": "typed", "password": Self.typed, "url": "https://elsewhere.test/"], from: top)
        try await stage.deliver(["kind": "save", "url": "https://elsewhere.test/"], from: top)
        XCTAssertEqual(asked("save").first?["url"] as? String, "https://www.example.test/")
    }

    // MARK: Where a password goes

    func testWhatWasTypedIsWipedAfterTwoMinutesAndAnsweredForNowhere() async throws {
        try await signIn()
        try await toastIsUp()
        let holding = try await held()
        XCTAssertEqual(holding.count, 1)
        try await background("""
        const real = Date.now;
        Date.now = () => real() + 121000;
        for (const listener of alarmListeners) await listener();
        Date.now = real;
        """)
        let left = try await held()
        XCTAssertTrue(left.isEmpty, "the alarm sweeps it")
        let alarmed = try await background("return alarms.length") as? Int
        XCTAssertGreaterThan(alarmed ?? 0, 0)
    }

    func testAPasswordIsOutOfLastingStorageThePageAndTheLog() async throws {
        try await stage.load("signin")
        try await fill(["username": Self.user, "password": Self.typed])
        try await stage.js("""
        window.before = document.documentElement.outerHTML;
        window.written = [];
        for (const name of ["localStorage", "sessionStorage"]) {
            const set = window[name].setItem.bind(window[name]);
            window[name].setItem = (key, value) => { window.written.push(value); set(key, value); };
        }
        """, world: page)
        try await press("send")
        try await toastIsUp()
        let wrote = try await background("return wroteToDisk") as? [String]
        XCTAssertEqual(wrote, [], "storage.local")
        let logged = try await background("return logged") as? [String]
        XCTAssertEqual(logged, [], "the background page's log")
        let content = try await stage.js("return logged") as? [String]
        XCTAssertEqual(content, [], "the content script's log")
        let seen = try await stage.js("""
        return {
            local: JSON.stringify(localStorage) + JSON.stringify(sessionStorage),
            page: document.documentElement.outerHTML,
            cookie: document.cookie,
        };
        """, world: page) as? [String: String]
        for (name, text) in seen ?? [:] { XCTAssertFalse(text.contains("kanarya-typed"), name) }
        let shown = try await stage.js("return live('.toast')[0].textContent") as? String
        XCTAssertFalse(shown?.contains(Self.typed) ?? true, "nothing of it comes back to the page's world")
    }

    func testWithNoSessionStorageItIsHeldInMemory() async throws {
        let again = ExtensionStage()
        again.noSessionStorage = true
        try await again.open()
        defer { again.close() }
        let top: [String: Any] = ["url": "https://www.example.test/", "frameId": 0,
                                  "tab": ["id": 1, "url": "https://www.example.test/"]]
        let answer = try await again.deliver(["kind": "typed", "password": Self.typed], from: top)
        XCTAssertEqual(answer["held"] as? Bool, true)
        let landed = try await again.deliver(["kind": "landed"], from: top)
        XCTAssertEqual(landed["held"] as? Bool, true)
        let session = try await again.background.callAsyncJavaScript(
            "return session.size + wroteToDisk.length", arguments: [:], in: nil, contentWorld: .page
        ) as? Int
        XCTAssertEqual(session, 0)
    }

    // MARK: What a page can do to it

    func testAPageCannotReadOrPressTheToastOrTellItIsThere() async throws {
        stage.door = { message in
            message["type"] as? String == "known" ? ["v": 1, "type": "locked"] : ExtensionStage.openDoor(message)
        }
        try await stage.load("single-page")
        try await fill(["username": Self.user, "password": Self.typed])
        try await stage.js("document.getElementById('username').focus()", world: page)
        try await stage.js("""
        window.changes = 0;
        window.seen = () => ({
            roots: Array.from(document.querySelectorAll("*")).filter((element) => element.shadowRoot !== null).length,
            html: document.documentElement.outerHTML.includes("OriPass") || document.documentElement.outerHTML.includes("Save"),
            text: document.documentElement.textContent.includes("OriPass"),
            found: window.find("Not Now") || window.find("OriPass"),
            popover: document.querySelectorAll(":popover-open").length,
            sizes: Array.from(document.documentElement.children).filter((element) => element.tagName === "DIV")
                .map((element) => element.offsetWidth + element.offsetHeight),
            active: document.activeElement?.id ?? "",
            children: document.documentElement.children.length,
        });
        """, world: page)
        try await press("send")
        // The stage is on the page before anyone knows what the door will say,
        // and the toast does not come until the password has been gone a while.
        try await stage.until("document.getElementById('root').textContent === 'Signed in'", world: page)
        try await stage.js("""
        window.changes = 0;
        window.watching = new MutationObserver((records) => { window.changes += records.length; });
        window.watching.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
        for (const name of ["beforetoggle", "toggle", "focusin"]) {
            document.addEventListener(name, () => { window.changes += 1; }, true);
        }
        window.quietly = window.seen();
        """, world: page)
        try await toastIsUp()
        let up = try await stage.js("return window.seen()", world: page) as? [String: AnyHashable]
        let before = try await stage.js("return window.quietly", world: page) as? [String: AnyHashable]
        XCTAssertEqual(up, before, "what a page can read is the same with the toast up and with none")
        XCTAssertEqual(up?["roots"], 0)
        XCTAssertEqual(up?["html"], false)
        XCTAssertEqual(up?["text"], false)
        XCTAssertEqual(up?["found"], false)
        XCTAssertEqual(up?["popover"], 0)
        XCTAssertEqual(up?["sizes"], [0] as [Int] as AnyHashable)
        let changes = try await stage.js("return window.changes", world: page) as? Int
        XCTAssertEqual(changes, 0, "no mutation, toggle or focus in the page's world as it came up")
    }

    func testASyntheticPressDoesNothing() async throws {
        try await signIn()
        try await toastIsUp()
        try await stage.js("""
        for (const element of document.documentElement.children) {
            element.click();
            element.dispatchEvent(new MouseEvent("click", { bubbles: true, composed: true }));
        }
        """, world: page)
        try await stage.js("""
        for (const button of live("button")) {
            button.click();
            button.dispatchEvent(new MouseEvent("click", { bubbles: true, composed: true }));
        }
        """)
        try await Task.sleep(nanoseconds: settle)
        XCTAssertTrue(asked("save").isEmpty)
        XCTAssertTrue(asked("never").isEmpty)
        let count = try await toastCount()
        XCTAssertEqual(count, 1)
    }

    func testAPressCountsForNothingWhileAPageHasMadeTheToastUnseen() async throws {
        try await signIn()
        try await toastIsUp()
        try await stage.js("document.documentElement.style.opacity = '0.01'", world: page)
        try await pressToast(".lit")
        try await Task.sleep(nanoseconds: settle)
        XCTAssertTrue(asked("save").isEmpty)
    }

    func testAPressCannotComeTheMomentItAppears() async throws {
        try await signIn()
        try await stage.until("live('.toast').length === 1")
        try await pressToast(".lit")
        try await Task.sleep(nanoseconds: settle)
        XCTAssertTrue(asked("save").isEmpty)
    }

    func testItTakesNoKeysItWasNotGiven() async throws {
        try await signIn(on: "single-page")
        try await toastIsUp()
        let tabbable = try await stage.js("return live('button').filter((button) => button.tabIndex !== -1).length") as? Int
        XCTAssertEqual(tabbable, 0)
        try stage.press(.enter)
        try stage.press(.escape)
        try await Task.sleep(nanoseconds: settle)
        XCTAssertTrue(asked("save").isEmpty)
        let count = try await toastCount()
        XCTAssertEqual(count, 1)
    }

    // MARK: How it comes and goes

    func testVoiceOverIsToldWhatItSays() async throws {
        answering("update", logins: [Self.mail])
        try await signIn()
        try await toastIsUp()
        let names = try await stage.js("""
        return {
            voice: live("[role=status]").find((element) => element.closest(".toast")).textContent,
            live: live("[role=status]").find((element) => element.closest(".toast")).getAttribute("aria-live"),
            group: live(".toast")[0].getAttribute("aria-label"),
            hidden: live(".toast svg").every((svg) => svg.getAttribute("aria-hidden") === "true"),
            buttons: live(".toast button").map((button) => button.textContent),
        };
        """) as? [String: Any]
        XCTAssertEqual(names?["voice"] as? String,
                       "Change this password?, Canary Mail, \(Self.user), OriPass has another password for this login.")
        XCTAssertEqual(names?["live"] as? String, "polite")
        XCTAssertEqual(names?["group"] as? String, "OriPass")
        XCTAssertEqual(names?["hidden"] as? Bool, true)
        XCTAssertEqual(names?["buttons"] as? [String], ["Save as New", "Update", "Not Now", "Never for this site"])
    }

    func testTheToastIsMadeOnceAndItsPlaceIsTheStylesheets() throws {
        let toast = try ExtensionStage.file("toast.js")
        XCTAssertFalse(toast.contains("\"stand\""), "what it says knows nothing of where it stands")
        for word in ["position", "top:", "right:", "translate", "innerWidth", "matchMedia"] {
            XCTAssertFalse(toast.contains(word), word)
        }
        let style = try ExtensionStage.file("style.css")
        let plain = try XCTUnwrap(style.range(of: "@media (prefers-reduced-motion: reduce)"))
        XCTAssertFalse(style[plain.upperBound...].contains("translate"), "under Reduce Motion it fades where it stands")
        XCTAssertTrue(style[plain.upperBound...].contains(".stand"))
    }

    // MARK: The picture

    /// `make shots` draws what the app draws, and this is not that. Each
    /// state over a page, at the Mac's own scale, in a folder of its own to
    /// be read at full size against `docs/look.md`.
    func testEachStateDrawsInBothAppearances() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oripass-toast")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let long = ["id": "three", "title": "A login whose name goes on for a very long way past the toast",
                    "username": "kanarya-a-very-long-address-indeed@mail.example.test"]
        let icon = try Data(contentsOf: ExtensionStage.root.appendingPathComponent("Tests/Fixtures/icon-globe.png"))
        let states: [(String, [String: Any])] = [
            ("new", ["state": "new", "logins": [[String: String]]()]),
            ("new-icon", ["state": "new", "logins": [[String: String]](), "icon": icon.base64EncodedString()]),
            ("update", ["state": "update", "logins": [Self.mail]]),
            ("choose", ["state": "choose", "logins": [Self.mail, Self.work, long]]),
            ("another", ["state": "another", "logins": [Self.work]]),
            ("long", ["state": "update", "logins": [long]]),
            ("locked", [:]),
        ]
        for (name, answer) in states {
            stage.door = { message in
                guard message["type"] as? String == "known" else { return ExtensionStage.openDoor(message) }
                if answer.isEmpty { return ["v": 1, "type": "locked"] }
                return answer.merging(["v": 1, "type": "known", "site": "northwind.example.test"]) { $1 }
            }
            try await signIn()
            try await toastIsUp()
            for dark in [false, true] {
                stage.page.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                try await Task.sleep(nanoseconds: rest)
                let shot = try await stage.snapshot(named: "toast-\(name)", dark: dark)
                let kept = folder.appendingPathComponent(shot.lastPathComponent)
                try? FileManager.default.removeItem(at: kept)
                try FileManager.default.moveItem(at: shot, to: kept)
            }
            if name == "update" {
                stage.page.appearance = NSAppearance(named: .aqua)
                try await pressToast(".lit")
                try await stage.until("live('.toast')[0]?.dataset.state === 'saved'")
                for dark in [false, true] {
                    stage.page.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    try await Task.sleep(nanoseconds: 700_000_000)
                    let shot = try await stage.snapshot(named: "toast-saved", dark: dark)
                    let kept = folder.appendingPathComponent(shot.lastPathComponent)
                    try? FileManager.default.removeItem(at: kept)
                    try FileManager.default.moveItem(at: shot, to: kept)
                }
            }
        }
    }
}
