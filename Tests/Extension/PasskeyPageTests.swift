import AppKit
import CryptoKit
import WebKit
import XCTest
@testable import OriPass

/// A page asking for a passkey: `wrapper.js` in the page's own world, around
/// WebKit's real `navigator.credentials.get`, `content.js`, the background page
/// and a door the stage plays or the real one. The browser's own call is real
/// where a test is about how it looks, and counted where one is about what it
/// was handed.
@MainActor
final class PasskeyPageTests: XCTestCase {
    private var stage: ExtensionStage!
    private let page = WKContentWorld.page
    private let settle: UInt64 = 300_000_000
    private let quiet: UInt64 = 600_000_000

    private static let mail = ["id": "b25l", "title": "Canary Mail", "username": "kanarya-user@example.test"]
    private static let work = ["id": "dHdv", "title": "Canary Work", "username": "kanarya-other@example.test"]
    private static let top: [String: Any] = ["url": "https://www.example.test/passkey.html", "frameId": 0,
                                             "tab": ["id": 1, "url": "https://www.example.test/passkey.html"]]
    private static let assertion: [String: Any] = [
        "credential": "b25l", "userHandle": "dXNlcg==", "authenticatorData": "ZGF0YQ==", "signature": "c2lnbg==",
    ]

    override func setUp() async throws {
        stage = ExtensionStage()
        stage.countsTheBrowsersOwn = true
        stage.door = Self.holding([Self.mail])
        try await stage.open()
    }

    override func tearDown() async throws {
        stage.close()
        stage = nil
    }

    /// A door with these passkeys, that signs whatever it is asked to.
    private static func holding(_ logins: [[String: String]],
                                assert: [String: Any] = ["v": 1, "type": "asserted", "assertion": assertion])
        -> ([String: Any]) -> [String: Any]? {
        { message in
            switch message["type"] as? String {
            case "passkeys": return ["v": 1, "type": "logins", "site": "example.test", "logins": logins]
            case "assert": return assert
            default: return ExtensionStage.openDoor(message)
            }
        }
    }

    private func asked(_ type: String) -> [[String: Any]] { stage.heard.filter { $0["type"] as? String == type } }

    /// What a page's call asked for, and not what a mark asked.
    private var lists: [[String: Any]] { asked("passkeys").filter { $0["rp"] != nil } }

    /// A page whose wrapper has been told whether the vault has anything here.
    private func load(host: String = "www.example.test") async throws {
        try await stage.load("passkey", host: host)
        try await told()
    }

    private func told(_ times: Int = 1) async throws {
        try await stage.until("window.portHeard.filter((said) => 'near' in said).length >= \(times)", world: page)
    }

    /// Whether a `get` made now reached the browser's own before it returned,
    /// and whatever crossed the port from the wrapper since the page began.
    private func standsAside() async throws -> (reached: Bool, said: Int) {
        let seen = try await stage.js("""
        const before = window.handedOver.length;
        navigator.credentials.get({ publicKey: { challenge: new Uint8Array(32) } });
        return [window.handedOver.length - before, window.portSaid.length];
        """, world: page) as? [Int]
        return (seen?.first == 1, seen?.last ?? -1)
    }

    private func toastIsUp() async throws {
        try await stage.until("live('.toast').length === 1"
            + " && live('.stand')[0].getAnimations().every((motion) => motion.playState === 'finished')")
        try await Task.sleep(nanoseconds: settle)
    }

    private func ask(_ extra: String = "{}", publicKey: String = "{}") async throws {
        try await stage.js("window.ask(\(extra), \(publicKey))", world: page)
    }

    private func outcome() async throws -> [String: String]? {
        try await stage.until("window.outcome", world: page)
        return try await stage.js("return window.outcome", world: page) as? [String: String]
    }

    private func handedOver() async throws -> Int {
        try await stage.js("return window.handedOver.length", world: page) as? Int ?? -1
    }

    private func toastCount() async throws -> Int {
        try await stage.js("return live('.toast').length") as? Int ?? -1
    }

    private func press(_ selector: String, at place: Int = 0) async throws {
        let parts = try await stage.js("""
        const box = live('\(selector)')[\(place)].getBoundingClientRect();
        return [box.left + box.width / 2, box.top + box.height / 2];
        """) as? [Double]
        let point = try XCTUnwrap(parts)
        try stage.click(CGPoint(x: point[0], y: point[1]))
    }

    // MARK: The toast

    func testAGetWithAPasskeyRaisesTheToast() async throws {
        try await load()
        try await ask()
        try await toastIsUp()
        let said = try await stage.js("""
        return {
            head: live('.head')[0].textContent,
            lines: live('.line-of').map((line) => line.textContent),
            buttons: live('.toast button').map((button) => button.textContent),
            voice: live('.toast [role=status]')[0].textContent,
        };
        """) as? [String: Any]
        XCTAssertEqual(said?["head"] as? String, "Sign in with your passkey?")
        XCTAssertEqual(said?["lines"] as? [String], ["example.test", Self.mail["username"]!])
        XCTAssertEqual(said?["buttons"] as? [String], ["Sign In", "Not Now"])
        XCTAssertEqual(said?["voice"] as? String, "Sign in with your passkey?, example.test, \(Self.mail["username"]!)")
        let list = try XCTUnwrap(lists.last)
        XCTAssertEqual(list["url"] as? String, "https://www.example.test/passkey.html")
        XCTAssertEqual(list["rp"] as? String, "www.example.test", "a page that names none is its own host")
        XCTAssertNil(list["challenge"], "the door hears no challenge until it is asked to sign")
        XCTAssertTrue(asked("assert").isEmpty, "nothing is signed for being asked")
        let outcome = try await stage.js("return window.outcome", world: page)
        XCTAssertTrue(outcome is NSNull || outcome == nil, "the call waits for an answer")
        let handed = try await handedOver()
        XCTAssertEqual(handed, 0)
    }

    func testNoPasskeyHereIsTheBrowsersAtOnce() async throws {
        stage.door = Self.holding([])
        try await load()
        try await ask()
        let outcome = try await outcome()
        XCTAssertEqual(outcome?["kind"], "the browser's own")
        let toasts = try await toastCount()
        XCTAssertEqual(toasts, 0)
    }

    func testAShutOrAbsentDoorIsTheBrowsersAtOnceAndPromisesNothing() async throws {
        for door in [{ _ in ["v": 1, "type": "locked"] }, { _ in nil }] as [([String: Any]) -> [String: Any]?] {
            stage.door = door
            try await load()
            try await ask()
            let outcome = try await outcome()
            XCTAssertEqual(outcome?["kind"], "the browser's own")
            let toasts = try await toastCount()
            XCTAssertEqual(toasts, 0)
        }
    }

    func testNotNowHandsTheCallToTheOriginalWithWhatItWasGiven() async throws {
        try await load()
        try await ask()
        try await toastIsUp()
        try await press(".quiet")
        let outcome = try await outcome()
        XCTAssertEqual(outcome?["kind"], "the browser's own")
        let same = try await stage.js("return window.handedOver[0] === window.options", world: page) as? Bool
        XCTAssertEqual(same, true)
        try await stage.until("live('.toast').length === 0")
        XCTAssertTrue(asked("assert").isEmpty)

        let before = lists.count
        try await told(2)
        let aside = try await standsAside()
        XCTAssertTrue(aside.reached, "a page told Not Now is left alone, in the tick it asks")
        XCTAssertEqual(lists.count, before, "and the door is not asked")
    }

    func testNotNowReachesTheBrowsersOwnInsideThePress() async throws {
        try await load()
        try await ask()
        try await toastIsUp()
        try await stage.js("""
        addEventListener("click", () => { window.atThePress = window.handedOver.length; }, { once: true });
        """, world: page)
        try await press(".quiet")
        try await stage.until("window.atThePress !== undefined", world: page)
        let handed = try await stage.js("return window.atThePress", world: page) as? Int
        XCTAssertEqual(handed, 1, "by the time the click had reached the page's window")
    }

    func testAToastLeftAloneHandsTheCallOnWhenItsTimeIsUp() async throws {
        try await load()
        try await ask(publicKey: "{ timeout: 900 }")
        try await stage.until("live('.toast').length === 1")
        let outcome = try await outcome()
        XCTAssertEqual(outcome?["kind"], "the browser's own")
        try await stage.until("live('.toast').length === 0")
    }

    func testSeveralPasskeysAreAListAndTheRowIsTheOneSigned() async throws {
        stage.door = Self.holding([Self.mail, Self.work])
        try await load()
        try await ask()
        try await toastIsUp()
        let rows = try await stage.js("return live('.choice').length") as? Int
        XCTAssertEqual(rows, 2)
        let head = try await stage.js("return live('.head')[0].textContent") as? String
        XCTAssertEqual(head, "Which passkey?")
        try await press(".choice", at: 1)
        let outcome = try await outcome()
        XCTAssertEqual(outcome?["kind"], "credential")
        XCTAssertEqual(asked("assert").first?["id"] as? String, Self.work["id"])
    }

    // MARK: Standing aside

    func testWithNothingNearTheCallReachesTheOriginalInTheSameTickAndThePortHearsNothing() async throws {
        stage.door = Self.holding([])
        try await load()
        let same = try await stage.js("""
        const options = { publicKey: { challenge: new Uint8Array(32) } };
        navigator.credentials.get(options);
        return window.handedOver[0] === options;
        """, world: page) as? Bool
        XCTAssertEqual(same, true)
        let aside = try await standsAside()
        XCTAssertTrue(aside.reached)
        XCTAssertEqual(aside.said, 0, "no port message")
        XCTAssertTrue(lists.isEmpty)
        let toasts = try await toastCount()
        XCTAssertEqual(toasts, 0)
    }

    func testACallIsNotReadWhenThereIsNothingNear() async throws {
        stage.door = Self.holding([])
        try await load()
        let reads = try await stage.js("""
        let reads = 0;
        navigator.credentials.get({ get publicKey() { reads += 1; return { challenge: new Uint8Array(32) }; } });
        return reads;
        """, world: page) as? Int
        XCTAssertEqual(reads, 0, "the counting `get` reads nothing, so neither did the wrapper")
    }

    func testOverAShutOrAbsentDoorOrAnAddressItWillNotAnswerForTheWrapperStandsAside() async throws {
        let doors: [([String: Any]) -> [String: Any]?] = [
            { _ in ["v": 1, "type": "locked"] }, { _ in ["v": 1, "type": "closed"] }, { _ in ["v": 1, "type": "unknown"] },
            { _ in ["v": 1, "type": "refused", "reason": "page"] }, { _ in nil },
        ]
        for door in doors {
            stage.door = door
            try await load()
            let aside = try await standsAside()
            XCTAssertTrue(aside.reached)
            XCTAssertEqual(aside.said, 0)
        }
    }

    func testWhileTheAnswerIsOutACallThatWantsAClickIsTheBrowsers() async throws {
        stage.doorTakes = 2_000_000_000
        try await stage.load("passkey")
        let aside = try await standsAside()
        XCTAssertTrue(aside.reached, "the door has not answered, and the vault does have one")
        XCTAssertEqual(aside.said, 0)
    }

    func testAConditionalCallWaitsToHearAndIsOffered() async throws {
        stage.doorTakes = 400_000_000
        try await stage.load("passkey")
        try await ask("{ mediation: 'conditional' }")
        let handed = try await handedOver()
        XCTAssertEqual(handed, 0)
        try await toastIsUp()
        try await press(".lit")
        let outcome = try await outcome()
        XCTAssertEqual(outcome?["kind"], "credential")
    }

    func testAConditionalCallWithNothingNearIsTheBrowsersWhenItHears() async throws {
        stage.door = Self.holding([])
        stage.doorTakes = 300_000_000
        try await stage.load("passkey")
        try await ask("{ mediation: 'conditional' }")
        let handed = try await handedOver()
        XCTAssertEqual(handed, 0)
        let outcome = try await outcome()
        XCTAssertEqual(outcome?["kind"], "the browser's own")
        let said = try await stage.js("return window.portSaid.length", world: page) as? Int
        XCTAssertEqual(said, 0)
    }

    func testAConditionalCallWaitsNoLongerThanTheLimit() async throws {
        stage.doorTakes = 2_500_000_000
        try await stage.load("passkey")
        let started = Date()
        try await ask("{ mediation: 'conditional' }")
        let outcome = try await outcome()
        XCTAssertEqual(outcome?["kind"], "the browser's own")
        let waited = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(waited, 0.5)
        XCTAssertLessThan(waited, 2.0)

        try await told()
        try await ask()
        try await toastIsUp()
    }

    func testAConditionalCallAbortedWhileItWaitsReachesNobody() async throws {
        stage.doorTakes = 400_000_000
        try await stage.load("passkey")
        try await stage.js("""
        window.aborts = new AbortController();
        window.ask({ mediation: 'conditional', signal: window.aborts.signal });
        setTimeout(() => window.aborts.abort(), 50);
        """, world: page)
        let outcome = try await outcome()
        XCTAssertEqual(outcome?["name"], "AbortError")
        try await told()
        try await Task.sleep(nanoseconds: settle)
        let handed = try await handedOver()
        XCTAssertEqual(handed, 0)
        XCTAssertTrue(lists.isEmpty)
    }

    func testARequestTheVaultHasNothingForGoesOnceByTheDoorAndThenStandsAside() async throws {
        stage.door = { message in
            message["type"] as? String == "passkeys" && message["rp"] != nil
                ? ["v": 1, "type": "logins", "site": "example.test", "logins": [[String: String]]()]
                : Self.holding([Self.mail])(message)
        }
        try await load()
        try await ask(publicKey: "{ allowCredentials: [{ type: 'public-key', id: new Uint8Array(16) }] }")
        let outcome = try await outcome()
        XCTAssertEqual(outcome?["kind"], "the browser's own")
        XCTAssertEqual(lists.count, 1)
        try await told(2)
        let aside = try await standsAside()
        XCTAssertTrue(aside.reached, "which is what a press on the page's own Try Again meets")
        XCTAssertEqual(lists.count, 1)
    }

    func testAVaultUnlockedSinceIsAskedAgainWhenThePersonComesBack() async throws {
        stage.door = { _ in ["v": 1, "type": "locked"] }
        try await load()
        stage.door = Self.holding([Self.mail])
        try await stage.js("dispatchEvent(new Event('focus'))")
        try await told(2)
        try await ask()
        try await toastIsUp()
    }

    func testAVaultLockedSinceStandsAsideWhenThePersonComesBack() async throws {
        try await load()
        stage.door = { _ in ["v": 1, "type": "locked"] }
        try await stage.js("dispatchEvent(new Event('focus'))")
        try await told(2)
        let aside = try await standsAside()
        XCTAssertTrue(aside.reached)
    }

    func testANoStandsForTheDocument() async throws {
        stage.door = Self.holding([])
        try await load()
        let before = asked("passkeys").count
        try await stage.js("dispatchEvent(new Event('focus'))")
        try await Task.sleep(nanoseconds: settle)
        XCTAssertEqual(asked("passkeys").count, before)
    }

    func testAFingerGivenSaysSoAndTheToastGoes() async throws {
        try await load()
        try await ask()
        try await toastIsUp()
        try await press(".lit")
        _ = try await outcome()
        try await stage.until("live('.toast')[0]?.dataset.state === 'saved'")
        let head = try await stage.js("return live('.head')[0].textContent") as? String
        XCTAssertEqual(head, "Passkey sent")
    }

    func testARefusedFingerRejectsAsNotAllowedError() async throws {
        stage.door = Self.holding([Self.mail], assert: ["v": 1, "type": "refused", "reason": "declined"])
        try await load()
        try await ask()
        try await toastIsUp()
        try await press(".lit")
        let outcome = try await outcome()
        XCTAssertEqual(outcome, ["kind": "error", "name": "NotAllowedError"])
        try await stage.until("live('.toast').length === 0")
        let handed = try await handedOver()
        XCTAssertEqual(handed, 0, "he said no, which is not a question for the browser")
    }

    func testAnythingElseThatGoesWrongIsTheBrowsersToTry() async throws {
        for said in [["v": 1, "type": "locked"], ["v": 1, "type": "refused", "reason": "gone"]] as [[String: Any]] {
            stage.door = Self.holding([Self.mail], assert: said)
            try await load()
            try await ask()
            try await toastIsUp()
            try await press(".lit")
            let outcome = try await outcome()
            XCTAssertEqual(outcome?["kind"], "the browser's own")
        }
    }

    func testASaveOfferUpIsLeftAndTheCallIsTheBrowsers() async throws {
        try await stage.load("signin")
        try await stage.js("""
        document.getElementById('username').value = 'kanarya-new@example.test';
        document.getElementById('password').value = 'kanarya-typed-password';
        """, world: page)
        let box = try await stage.box(of: "send")
        try stage.click(CGPoint(x: box.midX, y: box.midY))
        try await stage.until("live('.toast').length === 1")
        let before = lists.count
        try await stage.js("""
        window.outcome = null;
        navigator.credentials.get({ publicKey: { challenge: new Uint8Array(32) } })
            .then((got) => { window.outcome = { kind: got }; });
        """, world: page)
        let outcome = try await outcome()
        XCTAssertEqual(outcome?["kind"], "the browser's own")
        XCTAssertEqual(lists.count, before)
        let state = try await stage.js("return live('.toast')[0].dataset.state") as? String
        XCTAssertEqual(state, "new")
    }

    // MARK: Conditional mediation

    func testAConditionalRequestAtLoadIsOfferedAndAnsweredTheSameWay() async throws {
        try await load()
        try await ask("{ mediation: 'conditional' }", publicKey: "{ allowCredentials: [] }")
        try await toastIsUp()
        XCTAssertEqual(lists.last?["allowed"] as? [String], [])
        try await press(".lit")
        let outcome = try await outcome()
        XCTAssertEqual(outcome?["kind"], "credential")
    }

    func testAPageThatAbortsTakesTheToastAwayAndAsksAgain() async throws {
        try await load()
        try await stage.js("""
        window.aborts = new AbortController();
        window.ask({ mediation: 'conditional', signal: window.aborts.signal });
        """, world: page)
        try await toastIsUp()
        try await stage.js("window.aborts.abort()", world: page)
        let outcome = try await outcome()
        XCTAssertEqual(outcome, ["kind": "error", "name": "AbortError"])
        try await stage.until("live('.toast').length === 0")
        let handed = try await handedOver()
        XCTAssertEqual(handed, 0)

        try await ask("{ mediation: 'conditional' }")
        try await stage.until("live('.toast').length === 1")
    }

    func testACallAbortedBeforeTheDoorAnswersRaisesNothing() async throws {
        stage.doorTakes = 200_000_000
        try await load()
        try await stage.js("""
        window.aborts = new AbortController();
        window.ask({ mediation: 'conditional', signal: window.aborts.signal });
        setTimeout(() => window.aborts.abort(), 50);
        """, world: page)
        let outcome = try await outcome()
        XCTAssertEqual(outcome?["name"], "AbortError")
        XCTAssertEqual(lists.count, 1, "the door had been asked")
        try await Task.sleep(nanoseconds: quiet)
        let toasts = try await toastCount()
        XCTAssertEqual(toasts, 0)
    }

    func testASecondCallTakesTheToastAndTheFirstIsTheBrowsers() async throws {
        try await load()
        try await stage.js("""
        window.first = navigator.credentials.get({ mediation: 'conditional', publicKey: { challenge: new Uint8Array(32) } });
        """, world: page)
        try await toastIsUp()
        try await ask()
        try await stage.until("window.handedOver.length === 1", world: page)
        try await toastIsUp()
        try await Task.sleep(nanoseconds: settle)
        try await press(".lit")
        let outcome = try await outcome()
        XCTAssertEqual(outcome?["kind"], "credential")
    }

    func testACallThatIsNoPasskeysIsTheBrowsers() async throws {
        try await load()
        for options in ["{ password: true }", "{ mediation: 'silent', publicKey: { challenge: new Uint8Array(32) } }",
                        "{ publicKey: {} }", "{ publicKey: { challenge: 'not bytes' } }", "undefined"] {
            let before = try await handedOver()
            try await stage.js("navigator.credentials.get(\(options))", world: page)
            let after = try await handedOver()
            XCTAssertEqual(after, before + 1, options)
        }
        XCTAssertTrue(lists.isEmpty)
    }

    // MARK: Who may name what

    func testARelyingPartyThatIsNotThePagesIsRefused() async throws {
        try await load(host: "login.example.test")
        for party in ["other.test", "evil-example.test", "www.login.example.test", "test", "login.example.test.evil"] {
            try await ask(publicKey: "{ rpId: '\(party)' }")
            let outcome = try await outcome()
            XCTAssertEqual(outcome?["kind"], "the browser's own", "which says SecurityError itself: \(party)")
        }
        XCTAssertTrue(lists.isEmpty, "the door never heard of them")
        let toasts = try await toastCount()
        XCTAssertEqual(toasts, 0)
    }

    func testAPageMayNameItsHostOrAParentShortOfTheSuffix() async throws {
        try await load(host: "login.example.test")
        try await ask(publicKey: "{ rpId: 'example.test' }")
        try await toastIsUp()
        XCTAssertEqual(lists.last?["rp"] as? String, "example.test")
    }

    func testASigningIsHeldToTheRelyingPartyAgainAndTheSiteIsTheSenders() async throws {
        let answer = try await stage.deliver(["kind": "sign", "id": "b25l", "challenge": "Y2hhbGxlbmdl", "rp": "other.test",
                                              "url": "https://other.test/"], from: Self.top)
        XCTAssertEqual(answer["state"] as? String, "refused")
        XCTAssertTrue(asked("assert").isEmpty)
        try await stage.deliver(["kind": "sign", "id": "b25l", "challenge": "Y2hhbGxlbmdl", "allowed": [String](),
                                 "url": "https://other.test/", "origin": "https://other.test"], from: Self.top)
        XCTAssertEqual(asked("assert").first?["url"] as? String, "https://www.example.test/passkey.html")
    }

    func testAFrameIsNotAnswered() async throws {
        var frame = Self.top
        frame["frameId"] = 7
        let list = try await stage.deliver(["kind": "passkeys"], from: frame)
        XCTAssertEqual(list["state"] as? String, "none")
        let signed = try await stage.deliver(["kind": "sign", "id": "b25l", "challenge": "Y2hhbGxlbmdl"], from: frame)
        XCTAssertEqual(signed["state"] as? String, "refused")
        let near = try await stage.deliver(["kind": "passkeyNear"], from: frame)
        XCTAssertEqual(near["near"] as? Bool, false)
        XCTAssertTrue(stage.heard.isEmpty)
    }

    func testAFramesCallIsTheBrowsers() async throws {
        try await stage.load("framed", query: "?frame=www.example.test")
        try await stage.until("frames[0]?.document.readyState === 'complete'", world: page)
        try await Task.sleep(nanoseconds: quiet)
        let handed = try await stage.js("""
        frames[0].navigator.credentials.get({ publicKey: { challenge: new frames[0].Uint8Array(32) } });
        return frames[0].handedOver.length;
        """, world: page) as? Int
        XCTAssertEqual(handed, 1, "at once, with no wrapper to wait for")
        try await Task.sleep(nanoseconds: quiet)
        XCTAssertTrue(lists.isEmpty)
    }

    // MARK: What a page said

    func testTheClientDataIsTheExtensionsAndNothingThePageSaid() async throws {
        let answer = try await stage.deliver([
            "kind": "sign", "id": "b25l", "challenge": "Y2hhbGxlbmdlKys=", "origin": "https://evil.test",
            "clientData": "ZXZpbA==", "type": "webauthn.create", "crossOrigin": true,
        ], from: Self.top)
        let made = try XCTUnwrap(answer["made"] as? [String: Any])
        let bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(made["clientData"] as? String)))
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self),
                       #"{"type":"webauthn.get","challenge":"Y2hhbGxlbmdlKys","origin":"https://www.example.test","crossOrigin":false}"#)
        let hash = Data(SHA256.hash(data: bytes)).base64EncodedString()
        XCTAssertEqual(asked("assert").first?["hash"] as? String, hash, "what is signed is what the page is handed")
    }

    func testAChallengeThatIsNotBase64IsNotSigned() async throws {
        for challenge in ["\",\"origin\":\"https://evil.test", "", String(repeating: "A", count: 8193)] {
            let answer = try await stage.deliver(["kind": "sign", "id": "b25l", "challenge": challenge], from: Self.top)
            XCTAssertEqual(answer["state"] as? String, "refused", challenge)
        }
        let number = try await stage.deliver(["kind": "sign", "id": "b25l", "challenge": 12], from: Self.top)
        XCTAssertEqual(number["state"] as? String, "refused")
        XCTAssertTrue(asked("assert").isEmpty)
    }

    func testTooManyIdsOrIdsThatAreNotBase64AreNotAsked() async throws {
        let many = [String](repeating: "b25l", count: 65)
        for allowed in [many, ["not base64!"]] {
            let answer = try await stage.deliver(["kind": "passkeys", "allowed": allowed], from: Self.top)
            XCTAssertEqual(answer["state"] as? String, "none")
        }
        XCTAssertTrue(asked("passkeys").isEmpty)
    }

    func testAnInsecurePageAndAnAddressNameNothing() async throws {
        for url in ["http://www.example.test/", "https://192.168.1.1/"] {
            let sender: [String: Any] = ["url": url, "frameId": 0, "tab": ["id": 1, "url": url]]
            let answer = try await stage.deliver(["kind": "passkeys"], from: sender)
            XCTAssertEqual(answer["state"] as? String, "none", url)
        }
        XCTAssertTrue(asked("passkeys").isEmpty)
    }

    func testAPageCannotForgeThePortOrPressTheToast() async throws {
        try await load()
        try await stage.js("""
        const forged = new MessageChannel();
        window.forgedAnswers = [];
        forged.port1.onmessage = ({ data }) => window.forgedAnswers.push(data);
        window.postMessage({ oripass: "port" }, "*", [forged.port2]);
        forged.port1.postMessage({ call: 1, challenge: "Y2hhbGxlbmdl" });
        """, world: page)
        try await Task.sleep(nanoseconds: quiet)
        XCTAssertTrue(lists.isEmpty, "the port has been taken")
        let toasts = try await toastCount()
        XCTAssertEqual(toasts, 0)

        try await ask()
        try await toastIsUp()
        try await stage.js("""
        for (const button of live("button")) {
            button.click();
            button.dispatchEvent(new MouseEvent("click", { bubbles: true, composed: true }));
        }
        """)
        try await Task.sleep(nanoseconds: settle)
        XCTAssertTrue(asked("assert").isEmpty)
        try await stage.js("document.documentElement.style.opacity = '0.01'", world: page)
        try await press(".lit")
        try await Task.sleep(nanoseconds: settle)
        XCTAssertTrue(asked("assert").isEmpty, "a press on a toast a page has made unseen")
    }

    func testAPressCannotComeTheMomentItAppears() async throws {
        try await load()
        try await ask()
        try await stage.until("live('.toast').length === 1")
        try await press(".lit")
        try await Task.sleep(nanoseconds: settle)
        XCTAssertTrue(asked("assert").isEmpty)
    }

    // MARK: How it looks to a page

    func testACredentialsContainerStillLooksNative() async throws {
        let bare = ExtensionStage()
        try await bare.open()
        defer { bare.close() }
        try await bare.load("passkey")
        try await bare.until("Function.prototype.toString.toString().includes('native')", world: page)
        try await bare.until("document.querySelector('script[src]') === null", world: page)
        try await Task.sleep(nanoseconds: quiet)
        let seen = try await bare.js("""
        const frame = document.createElement("iframe");
        document.body.append(frame);
        const own = frame.contentWindow;
        const get = CredentialsContainer.prototype.get;
        const toString = Function.prototype.toString;
        const pair = (ours, theirs) => [ours, theirs];
        const result = {
            text: pair(get.toString(), own.CredentialsContainer.prototype.get.toString()),
            textBy: pair(toString.call(get), own.Function.prototype.toString.call(own.CredentialsContainer.prototype.get)),
            toString: pair(toString.toString(), own.Function.prototype.toString.toString()),
            name: pair(get.name, own.CredentialsContainer.prototype.get.name),
            length: pair(get.length, own.CredentialsContainer.prototype.get.length),
            toStringName: pair(toString.name, own.Function.prototype.toString.name),
            described: pair(JSON.stringify(Object.getOwnPropertyDescriptor(CredentialsContainer.prototype, "get"), (key, value) => typeof value === "function" ? "function" : value),
                JSON.stringify(Object.getOwnPropertyDescriptor(own.CredentialsContainer.prototype, "get"), (key, value) => typeof value === "function" ? "function" : value)),
            keys: pair(Object.getOwnPropertyNames(CredentialsContainer.prototype).sort().join(),
                Object.getOwnPropertyNames(own.CredentialsContainer.prototype).sort().join()),
            ownKeys: pair(Object.getOwnPropertyNames(navigator.credentials).join(), Object.getOwnPropertyNames(own.navigator.credentials).join()),
            kind: pair(Object.prototype.toString.call(navigator.credentials), Object.prototype.toString.call(own.navigator.credentials)),
            isGet: pair(navigator.credentials.get === get, own.navigator.credentials.get === own.CredentialsContainer.prototype.get),
            hasPrototype: pair("prototype" in get, "prototype" in own.CredentialsContainer.prototype.get),
        };
        frame.remove();
        return result;
        """, world: page) as? [String: [Any]]
        let parts = try XCTUnwrap(seen)
        XCTAssertEqual(parts.count, 12)
        for (name, pair) in parts { XCTAssertEqual("\(pair[0])", "\(pair[1])", name) }
        let throwing = try await bare.js("""
        return await CredentialsContainer.prototype.get.call({}, { publicKey: { challenge: new Uint8Array(32) } })
            .then(() => "resolved", (error) => error.name);
        """, world: page) as? String
        XCTAssertEqual(throwing, "TypeError", "a bad `this` is told what the browser would tell it")
        let left = try await bare.js("""
        return {
            scripts: Array.from(document.scripts).filter((script) => script.src !== "").length,
            messages: window.heardMessages,
            html: document.documentElement.outerHTML.includes("oripass") || document.documentElement.outerHTML.includes("wrapper"),
        };
        """, world: page) as? [String: AnyHashable]
        XCTAssertEqual(left?["scripts"], 0, "the script went with its load")
        XCTAssertEqual(left?["messages"], 0, "the message that brought the port reached nobody of the page's")
        XCTAssertEqual(left?["html"], false)
    }

    func testAPageThatAsksTheBrowsersOwnIsAnsweredByTheRealOne() async throws {
        let bare = ExtensionStage()
        bare.door = Self.holding([])
        try await bare.open()
        defer { bare.close() }
        try await bare.load("passkey")
        try await bare.until("document.querySelector('script[src]') === null", world: page)
        try await Task.sleep(nanoseconds: quiet)
        try await bare.js("window.ask()", world: page)
        try await bare.until("window.outcome", world: page, seconds: 15)
        let outcome = try await bare.js("return window.outcome", world: page) as? [String: String]
        XCTAssertEqual(outcome?["kind"], "error", "a web view with no relying party refuses, by WebKit's own hand")
        XCTAssertNotNil(outcome?["name"])
    }

    // MARK: A real one

    /// The whole way: WebKit's page, the wrapper, the content script, the
    /// background page, the wire, the real door over the demo's vault, and a
    /// page that checks what it was given as a server would.
    func testARealAssertionThroughTheWrapperIsTakenByAVerifier() async throws {
        let vault = DemoVault.objects()
        let backend = FakeBackend(items: vault.items, folders: vault.folders, password: DemoVault.password)
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        let authoriser = FakeAuthoriser()
        let reprompt = Reprompt(store: store, authoriser: authoriser)
        let door = BrowserDoor(store: store, reprompt: reprompt, preferences: Preferences())
        await store.unlock(password: SecretBytes(DemoVault.password))
        stage.wholeDoor = { message in
            guard let body = try? JSONSerialization.data(withJSONObject: message), let request = BridgeRequest(body) else {
                return ["v": 1, "type": "closed"]
            }
            let answer = await door.answer(request, from: .safari)
            return try? JSONSerialization.jsonObject(with: answer.body) as? [String: Any]
        }
        try await load(host: "www.github.com")
        try await ask(publicKey: "{ rpId: 'github.com' }")
        try await toastIsUp()
        try await press(".lit")
        let outcome = try await outcome()
        XCTAssertEqual(outcome?["kind"], "credential")
        XCTAssertEqual(authoriser.asked, [.passkey], "one finger for one signature")

        let key = try P256.Signing.PrivateKey(rawRepresentation: Data(DemoVault.passkeySeed.utf8)).publicKey
        let point = key.x963Representation
        let safe = { (part: Data) in
            part.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let jwk = ["kty": "EC", "crv": "P-256", "x": safe(point[1..<33]), "y": safe(point[33..<65])]
        let id = withUnsafeBytes(of: UUID(uuidString: DemoVault.passkeyCredential)!.uuid) { Data($0) }
        let verdict = try await stage.page.callAsyncJavaScript(
            "return await window.verify(origin, relyingParty, key, id)",
            arguments: ["origin": "https://www.github.com", "relyingParty": "github.com", "key": jwk, "id": safe(id)],
            in: nil, contentWorld: page
        ) as? String
        XCTAssertEqual(verdict, "taken")
        let wrong = try await stage.page.callAsyncJavaScript(
            "return await window.verify(origin, relyingParty, key, id)",
            arguments: ["origin": "https://evil.test", "relyingParty": "github.com", "key": jwk, "id": safe(id)],
            in: nil, contentWorld: page
        ) as? String
        XCTAssertEqual(wrong, "client data's origin", "the verifier can tell")

        let held = try await stage.js("return live('.toast')[0].textContent") as? String
        XCTAssertFalse(held?.contains(DemoVault.passkey) ?? true)
        let logged = try await stage.js("return logged") as? [String]
        XCTAssertEqual(logged, [])
    }

    // MARK: The mark

    func testAMarkSaysAPasskeyIsThereBeforeThePageHasAsked() async throws {
        try await load()
        try await stage.until("live('.mark.with-passkey').length === 2")
        XCTAssertEqual(asked("passkeys").first?["url"] as? String, "https://www.example.test/passkey.html")
        XCTAssertNil(asked("passkeys").first?["rp"], "whatever this page could ask for")
        let label = try await stage.js("return live('.mark')[0].getAttribute('aria-label')") as? String
        XCTAssertEqual(label, "Show OriPass logins. OriPass has a passkey for this site.")
        let toasts = try await toastCount()
        XCTAssertEqual(toasts, 0, "it has not asked, so there is nothing to answer")

        let box = try await stage.box(of: "username")
        try stage.click(CGPoint(x: box.midX, y: box.midY))
        try await stage.until("live('.passkey-line').some((line) => !line.hidden)")
    }

    func testAPageWithNoFieldsAsksOnceAndRaisesTheToast() async throws {
        try await stage.load("no-fields")
        try await told()
        XCTAssertEqual(asked("passkeys").count, 1)
        XCTAssertEqual(asked("passkeys").first?["url"] as? String, "https://www.example.test/no-fields.html")
        try await stage.js("navigator.credentials.get({ publicKey: { challenge: new Uint8Array(32) } })", world: page)
        try await toastIsUp()
    }

    func testAPageWithNoPasskeyHasThePlainMarkAndAsksOnce() async throws {
        stage.door = Self.holding([])
        try await load()
        try await stage.until("live('.mark').length === 2")
        try await stage.js("document.getElementById('username').type = 'email'", world: page)
        try await Task.sleep(nanoseconds: quiet)
        let count = try await stage.js("return live('.with-passkey').length") as? Int
        XCTAssertEqual(count, 0)
        XCTAssertEqual(asked("passkeys").count, 1)
    }

    // MARK: The picture

    /// Beside what `ToastTests` writes, to be read at full size against
    /// `docs/look.md`.
    func testEachPasskeyStateDrawsInBothAppearances() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oripass-toast")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func keep(_ name: String, resting: UInt64 = 1_500_000_000) async throws {
            for dark in [false, true] {
                stage.page.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                try await Task.sleep(nanoseconds: resting)
                let shot = try await stage.snapshot(named: "toast-\(name)", dark: dark)
                let kept = folder.appendingPathComponent(shot.lastPathComponent)
                try? FileManager.default.removeItem(at: kept)
                try FileManager.default.moveItem(at: shot, to: kept)
            }
        }
        func holding(_ logins: [[String: String]]) -> ([String: Any]) -> [String: Any]? {
            { message in
                var said = Self.holding(logins)(message)
                if message["type"] as? String == "passkeys" { said?["site"] = "northwind.example.test" }
                return said
            }
        }
        stage.door = holding([Self.mail, Self.work])
        try await load()
        try await ask()
        try await toastIsUp()
        try await keep("passkeys")

        stage.door = holding([Self.mail])
        try await load()
        try await stage.until("live('.with-passkey').length === 2")
        let box = try await stage.box(of: "username")
        try stage.click(CGPoint(x: box.midX, y: box.midY))
        try await stage.until("live('.card').length === 1")
        try await keep("mark-passkey")

        try await load()
        try await ask()
        try await toastIsUp()
        try await keep("passkey")
        stage.page.appearance = NSAppearance(named: .aqua)
        try await press(".lit")
        try await stage.until("live('.toast')[0]?.dataset.state === 'saved'")
        try await keep("passkey-sent", resting: 700_000_000)
    }
}
