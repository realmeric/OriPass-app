import AuthenticationServices
import XCTest
@testable import OriPass

/// The sheet over a door that remembers what it was asked. The provider is
/// never started here, since nothing but the system starts one.
@MainActor
final class AutoFillSheetTests: XCTestCase {
    private static let page = AutoFillService.page(url: "https://github.com/login", name: "github.com")
    private static let bank = AutoFillService.page(url: "https://isbank.com.tr/", name: "isbank.com.tr")
    private static let logins = [DoorLogin(id: "a", title: "GitHub", username: "canary"),
                                 DoorLogin(id: "b", title: "GitHub, work", username: nil)]

    private static let passkey = AutoFillService.passkey(relyingParty: "github.com", allowed: [Data([1])],
                                                         clientDataHash: Data(repeating: 7, count: 32))
    private static let assertion = SheetAssertion(credential: Data([1]), userHandle: Data([2]),
                                                  authenticatorData: Data([3]), signature: Data([4]))

    private var finished: [SheetCredential] = []
    private var asserted: [SheetAssertion] = []
    private var codes: [SheetCode] = []
    private var dismissals = 0

    override func setUp() {
        finished = []
        asserted = []
        codes = []
        dismissals = 0
    }

    private func sheet(_ services: [AutoFillService] = [page], door: AnsweringDoor, isForCodes: Bool = false,
                       looksInFront: Bool = false) -> AutoFillSheet {
        AutoFillSheet(services: services, door: door, again: .milliseconds(5), isForCodes: isForCodes,
                      looksInFront: looksInFront) { [weak self] in
            self?.finished.append($0)
        } assert: { [weak self] in
            self?.asserted.append($0)
        } code: { [weak self] in
            self?.codes.append($0)
        } dismiss: { [weak self] in
            self?.dismissals += 1
        }
    }

    private func until(_ isSo: () -> Bool) async {
        for _ in 0..<400 where !isSo() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func listed(_ door: AnsweringDoor) async -> AutoFillSheet {
        let sheet = sheet(door: door)
        sheet.begin()
        await until { sheet.state == .listed }
        return sheet
    }

    // MARK: What the system named

    func testADomainIsAskedForAsAPage() {
        let named = AutoFillService(ASCredentialServiceIdentifier(identifier: "github.com", type: .domain))
        XCTAssertEqual(named, .page(url: "https://github.com/", name: "github.com"))
    }

    func testAnAddressIsAskedForAsItCame() {
        let named = AutoFillService(ASCredentialServiceIdentifier(identifier: "http://192.168.1.1/admin", type: .URL))
        XCTAssertEqual(named, .page(url: "http://192.168.1.1/admin", name: "192.168.1.1"))
    }

    func testAnAddressWithNoSchemeIsAskedForUnderHTTPS() {
        let named = AutoFillService(ASCredentialServiceIdentifier(identifier: "github.com/login", type: .URL))
        XCTAssertEqual(named, .page(url: "https://github.com/login", name: "github.com"))
    }

    func testAnAppIsItsIdAndItsName() {
        let named = AutoFillService(ASCredentialServiceIdentifier(identifier: "com.tinyspeck.slackmacgap", type: .app,
                                                                  displayName: "Slack"))
        XCTAssertEqual(named, .app(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"))
    }

    func testAnAppIDLosesItsTeam() {
        let named = AutoFillService(ASCredentialServiceIdentifier(identifier: "BQR82RBBHL.com.tinyspeck.slackmacgap", type: .app,
                                                                  displayName: "Slack"))
        XCTAssertEqual(named, .app(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"))
    }

    func testNothingNamedIsNoService() {
        XCTAssertNil(AutoFillService(ASCredentialServiceIdentifier(identifier: "  ", type: .domain)))
    }

    // MARK: The list

    func testTheListForAServiceIsWhatTheDoorSaid() async {
        let door = AnsweringDoor { _ in .logins(site: "github.com", Self.logins) }
        let sheet = await listed(door)
        XCTAssertEqual(sheet.rows.map(\.title), ["GitHub", "GitHub, work"])
        XCTAssertEqual(sheet.rows.map(\.username), ["canary", nil])
        XCTAssertEqual(sheet.statement, "Logins for github.com")
        XCTAssertEqual(door.asked.count, 1)
    }

    /// One login twice is one row, under the service that found it first.
    func testTwoServicesAreOneListWithNoRowTwice() async {
        let door = AnsweringDoor { request in
            guard case .logins(let service) = request else { return .refused("page") }
            return .logins(site: nil, service == Self.page ? Self.logins : [Self.logins[1], DoorLogin(id: "c", title: "Bank", username: nil)])
        }
        let sheet = sheet([Self.page, Self.bank], door: door)
        sheet.begin()
        await until { sheet.state == .listed }
        XCTAssertEqual(sheet.rows.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(sheet.rows.map(\.service), [Self.page, Self.page, Self.bank])
    }

    func testAServiceNoLoginHoldsForSaysSo() async {
        let sheet = sheet(door: AnsweringDoor { _ in .logins(site: "github.com", []) })
        sheet.begin()
        await until { sheet.state == .nothing }
        XCTAssertEqual(sheet.statement, "No login for github.com")
        XCTAssertEqual(sheet.sentence, "Quick Access can find any login and type it here.")
    }

    func testAnAddressTheDoorWillNotReadIsAListOfNothing() async {
        let sheet = sheet(door: AnsweringDoor { _ in .refused("page") })
        sheet.begin()
        await until { sheet.state == .nothing }
        XCTAssertEqual(sheet.rows, [])
    }

    /// A passkey with no relying party or an identity with no service names
    /// nothing either, and those are no question for what is in front.
    func testNothingNamedThatIsNotToLookAsksNobody() async {
        let door = AnsweringDoor { _ in .logins(site: nil, Self.logins) }
        let sheet = sheet([], door: door)
        sheet.begin()
        XCTAssertEqual(sheet.state, .unnamed)
        XCTAssertEqual(sheet.statement, "This app did not say what it signs in to")
        XCTAssertNil(sheet.sentence)
        XCTAssertFalse(sheet.showsField)
        XCTAssertTrue(door.asked.isEmpty)
    }

    // MARK: Nothing named

    private static let google = AutoFillService.page(url: "https://accounts.google.com/signin", name: "google.com")
    private static let found = [DoorLogin(id: "x", title: "Bank", username: nil)]

    /// `front` lists the page, a word lists `found`, and each is written down.
    private func frontDoor(_ front: SheetAnswer = .front(google, logins)) -> AnsweringDoor {
        AnsweringDoor { request in
            switch request {
            case .front: return front
            case .find: return .logins(site: nil, Self.found)
            case .fill: return .filled(SheetCredential(username: "canary", password: "kanarya-secret"))
            case .pick: return .filled(SheetCredential(username: "canary", password: "kanarya-picked"))
            case .codes: return .logins(site: "google.com", [Self.logins[0]])
            case .code: return .code(SheetCode(code: "123456"))
            default: return .refused("page")
            }
        }
    }

    func testAServiceNamedAsksNothingOfWhatIsInFront() async {
        let door = frontDoor()
        let sheet = sheet(door: door, looksInFront: true)
        sheet.begin()
        await until { sheet.state == .listed }
        XCTAssertFalse(sheet.showsField, "the system said what it is for")
        guard case .logins(Self.page)? = door.asked.first else { return XCTFail("not asked for its logins") }
        XCTAssertEqual(door.asked.count, 1)
    }

    func testWhatIsInFrontIsListedUnderItsNameBelowTheField() async {
        let sheet = sheet([], door: frontDoor(), looksInFront: true)
        sheet.begin()
        await until { sheet.state == .listed }
        XCTAssertEqual(sheet.statement, "Logins for google.com")
        XCTAssertEqual(sheet.rows.map(\.id), ["a", "b"])
        XCTAssertTrue(sheet.showsField)
    }

    func testARowOfWhatIsInFrontIsAFillForTheAddressTheAppSaid() async {
        let door = frontDoor()
        let sheet = sheet([], door: door, looksInFront: true)
        sheet.begin()
        await until { sheet.state == .listed }
        sheet.chooseFirst()
        await until { !finished.isEmpty }
        guard case .fill("a", Self.google)? = door.asked.last else { return XCTFail("not a fill for that page") }
    }

    func testNothingInFrontIsTheFieldAndALine() async {
        let sheet = sheet([], door: frontDoor(.front(nil, [])), looksInFront: true)
        sheet.begin()
        await until { sheet.state == .unnamed }
        XCTAssertEqual(sheet.statement, "This app did not say what it signs in to")
        XCTAssertNil(sheet.sentence, "the field is what to do about it")
        XCTAssertTrue(sheet.showsField)
    }

    func testAPageNoLoginHoldsForSaysWhichWithTheFieldThere() async {
        let sheet = sheet([], door: frontDoor(.front(Self.google, [])), looksInFront: true)
        sheet.begin()
        await until { sheet.state == .nothing }
        XCTAssertEqual(sheet.statement, "No login for google.com")
        XCTAssertNil(sheet.sentence)
        XCTAssertTrue(sheet.showsField)
    }

    func testAWordListsWhatItFoundAndTheFieldEmptiedBringsThePageBack() async {
        let sheet = sheet([], door: frontDoor(), looksInFront: true)
        sheet.begin()
        await until { sheet.state == .listed }
        sheet.word = "ba"
        await until { sheet.rows.map(\.id) == ["x"] }
        XCTAssertEqual(sheet.statement, "Logins found")
        XCTAssertNil(sheet.rows[0].service)
        sheet.word = ""
        XCTAssertEqual(sheet.rows.map(\.id), ["a", "b"])
        XCTAssertEqual(sheet.statement, "Logins for google.com")
    }

    func testAWordThatFindsNothingSaysSo() async {
        let door = frontDoor()
        let sheet = sheet([], door: door, looksInFront: true)
        sheet.begin()
        await until { sheet.state == .listed }
        door.answering = { _ in .logins(site: nil, []) }
        sheet.word = "zz"
        await until { sheet.state == .nothing }
        XCTAssertEqual(sheet.statement, "No login found")
        XCTAssertEqual(sheet.rows, [])
    }

    func testARowAWordFoundIsAPick() async {
        let door = frontDoor()
        let sheet = sheet([], door: door, looksInFront: true)
        sheet.begin()
        await until { sheet.state == .listed }
        sheet.word = "ba"
        await until { sheet.rows.map(\.id) == ["x"] }
        sheet.chooseFirst()
        await until { !finished.isEmpty }
        guard case .pick("x")? = door.asked.last else { return XCTFail("not a pick") }
        XCTAssertEqual(finished.first?.password, "kanarya-picked")
    }

    func testAPickRefusedStaysOnTheList() async {
        let door = frontDoor()
        let sheet = sheet([], door: door, looksInFront: true)
        sheet.begin()
        await until { sheet.state == .listed }
        sheet.word = "ba"
        await until { sheet.rows.map(\.id) == ["x"] }
        door.answering = { _ in .refused("declined") }
        sheet.chooseFirst()
        await until { sheet.refusal != nil }
        XCTAssertEqual(sheet.refusal, "OriPass was not told to fill that login.")
        XCTAssertEqual(sheet.rows.map(\.id), ["x"])
        XCTAssertTrue(finished.isEmpty)
    }

    /// A tab can take a second to say, and the field is his before it has.
    func testAWordTypedBeforeTheAppAnswersIsNotTakenAway() async {
        let door = frontDoor()
        let gate = AsyncStream<Void>.makeStream()
        door.held = gate.stream
        let sheet = sheet([], door: door, looksInFront: true)
        sheet.begin()
        await until { door.asked.count == 1 }
        door.held = nil
        sheet.word = "ba"
        await until { sheet.rows.map(\.id) == ["x"] }
        gate.continuation.finish()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(sheet.rows.map(\.id), ["x"])
        sheet.word = ""
        XCTAssertEqual(sheet.rows.map(\.id), ["a", "b"])
    }

    func testAShutVaultHidesTheFieldAndTheListComesWhenItOpens() async {
        let door = AnsweringDoor { _ in .shut(isRunning: true) }
        let sheet = sheet([], door: door, looksInFront: true)
        sheet.begin()
        await until { sheet.state == .shut(isRunning: true) }
        XCTAssertFalse(sheet.showsField)
        door.answering = { _ in .front(Self.google, Self.logins) }
        await until { sheet.state == .listed }
        XCTAssertTrue(sheet.showsField)
        XCTAssertEqual(sheet.rows.count, 2)
    }

    func testALockUnderAWordTakesTheWordAndTheListAway() async {
        let door = frontDoor()
        let sheet = sheet([], door: door, looksInFront: true)
        sheet.begin()
        await until { sheet.state == .listed }
        door.answering = { _ in .shut(isRunning: true) }
        sheet.word = "ba"
        await until { sheet.state == .shut(isRunning: true) }
        XCTAssertEqual(sheet.word, "")
        XCTAssertEqual(sheet.rows, [])
        sheet.end()
    }

    func testEndingTheSheetForgetsWhatWasInFront() async {
        let sheet = sheet([], door: frontDoor(), looksInFront: true)
        sheet.begin()
        await until { sheet.state == .listed }
        sheet.end()
        sheet.word = "ba"
        sheet.word = ""
        XCTAssertEqual(sheet.rows, [])
    }

    /// A code's list is asked for the address the app used, and has no
    /// field: a code is made only for a login held to an address.
    func testACodeWithNothingNamedAsksWhatIsInFrontAndHasNoField() async throws {
        let door = frontDoor()
        let sheet = sheet([], door: door, isForCodes: true, looksInFront: true)
        sheet.begin()
        await until { sheet.state == .listed }
        XCTAssertEqual(sheet.statement, "One-time codes for google.com")
        XCTAssertFalse(sheet.showsField)
        sheet.choose(try XCTUnwrap(sheet.rows.first))
        await until { !codes.isEmpty }
        guard case .code("a", Self.google)? = door.asked.last else { return XCTFail("not a code for that page") }
    }

    func testACodeWithNothingInFrontKeepsItsLine() async {
        let sheet = sheet([], door: frontDoor(.front(nil, [])), isForCodes: true, looksInFront: true)
        sheet.begin()
        await until { sheet.state == .unnamed }
        XCTAssertEqual(sheet.sentence, "Quick Access can find any login and copy its code.")
    }

    // MARK: A fill

    func testAFillHandsTheCredentialToTheSystemAndAsksNoMore() async {
        let door = AnsweringDoor { request in
            if case .fill(let id, let service) = request {
                XCTAssertEqual(id, "a")
                XCTAssertEqual(service, Self.page)
                return .filled(SheetCredential(username: "canary", password: "kanarya-secret"))
            }
            return .logins(site: nil, Self.logins)
        }
        let sheet = await listed(door)
        sheet.choose(sheet.rows[0])
        XCTAssertEqual(sheet.state, .filling(id: "a"))
        XCTAssertEqual(sheet.statement, "Waiting for OriPass…")
        await until { !finished.isEmpty }
        XCTAssertEqual(finished, [SheetCredential(username: "canary", password: "kanarya-secret")])
        XCTAssertEqual(sheet.rows, [], "nothing of the vault is kept past the sheet")
    }

    func testALoginWithNoUsernameIsHandedOverWithAnEmptyOne() async {
        let door = AnsweringDoor { request in
            if case .fill = request { return .filled(SheetCredential(username: "", password: "kanarya-secret")) }
            return .logins(site: nil, Self.logins)
        }
        let sheet = await listed(door)
        sheet.choose(sheet.rows[1])
        await until { !finished.isEmpty }
        XCTAssertEqual(finished.first?.username, "")
    }

    func testASecondRowWhileTheFirstIsWaitedForIsNotSent() async {
        let door = AnsweringDoor { request in
            if case .fill = request { return .refused("declined") }
            return .logins(site: nil, Self.logins)
        }
        let sheet = await listed(door)
        sheet.choose(sheet.rows[0])
        sheet.choose(sheet.rows[1])
        await until { sheet.refusal != nil }
        XCTAssertEqual(door.asked.filter { if case .fill = $0 { true } else { false } }.count, 1)
    }

    func testARefusalIsSaidAndTheListStays() async {
        let words = ["page": "That login is not for this page.", "gone": "That login is no longer in the vault.",
                     "insecure": "This page is not secure, and the login is saved for a secure one.",
                     "declined": "OriPass was not told to fill that login."]
        for (reason, sentence) in words {
            let door = AnsweringDoor { request in
                if case .fill = request { return .refused(reason) }
                return .logins(site: nil, Self.logins)
            }
            let sheet = await listed(door)
            sheet.choose(sheet.rows[0])
            await until { sheet.refusal != nil }
            XCTAssertEqual(sheet.refusal, sentence)
            XCTAssertEqual(sheet.state, .listed)
            XCTAssertEqual(sheet.rows.count, 2)
            XCTAssertTrue(finished.isEmpty)
        }
    }

    func testALoginWithNoPasswordIsNotHandedOver() async {
        let door = AnsweringDoor { request in
            if case .fill = request { return .filled(SheetCredential(username: "canary", password: "")) }
            return .logins(site: nil, Self.logins)
        }
        let sheet = await listed(door)
        sheet.choose(sheet.rows[0])
        await until { sheet.refusal != nil }
        XCTAssertEqual(sheet.refusal, "That login has no password.")
        XCTAssertTrue(finished.isEmpty)
    }

    // MARK: A shut vault

    func testAShutVaultSaysSoAndHandsOverToQuickAccess() async {
        let sheet = sheet(door: AnsweringDoor { _ in .shut(isRunning: true) })
        sheet.begin()
        await until { sheet.state == .shut(isRunning: true) }
        sheet.end()
        XCTAssertEqual(sheet.statement, "OriPass is locked")
        XCTAssertEqual(sheet.sentence, "Unlock it in Quick Access, on its key or from the mark in the menu bar, and the logins will come here.")
        XCTAssertEqual(sheet.rows, [])
    }

    func testAnAppThatIsNotUpSaysSo() async {
        let sheet = sheet(door: AnsweringDoor { _ in .shut(isRunning: false) })
        sheet.begin()
        await until { sheet.state == .shut(isRunning: false) }
        sheet.end()
        XCTAssertEqual(sheet.statement, "OriPass is not open")
    }

    /// The hand-over: nothing is done on the sheet, and the vault unlocked
    /// in Quick Access brings the list.
    func testTheListComesOnceTheVaultIsOpened() async {
        let door = AnsweringDoor { _ in .shut(isRunning: true) }
        let sheet = sheet(door: door)
        sheet.begin()
        await until { sheet.state == .shut(isRunning: true) }
        door.answering = { _ in .logins(site: "github.com", Self.logins) }
        await until { sheet.state == .listed }
        XCTAssertEqual(sheet.rows.count, 2)
    }

    /// Between the list and the row the vault shut, and the sheet goes back
    /// to saying so, with the rows gone.
    func testALockUnderAFillTakesTheListAway() async {
        let door = AnsweringDoor { request in
            if case .fill = request { return .shut(isRunning: true) }
            return .logins(site: nil, Self.logins)
        }
        let sheet = await listed(door)
        door.answering = { _ in .shut(isRunning: true) }
        sheet.choose(sheet.rows[0])
        await until { sheet.state == .shut(isRunning: true) }
        sheet.end()
        XCTAssertEqual(sheet.rows, [])
        XCTAssertTrue(finished.isEmpty)
    }

    func testCancelStopsAskingAndGoes() async {
        let door = AnsweringDoor { _ in .shut(isRunning: true) }
        let sheet = sheet(door: door)
        sheet.begin()
        await until { door.asked.count > 1 }
        sheet.cancel()
        XCTAssertEqual(dismissals, 1)
        let asked = door.asked.count
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertLessThanOrEqual(door.asked.count, asked + 1, "one may have been on its way")
    }

    func testACredentialSaysNothingOfItself() {
        let credential = SheetCredential(username: "canary", password: "kanarya-secret")
        XCTAssertFalse("\(credential)".contains("kanarya"))
        XCTAssertFalse(String(reflecting: credential).contains("kanarya"))
    }

    // MARK: D6

    /// The system's list of identities is usernames and hosts in a database
    /// of the system's, so nothing here may touch it for a login or a code:
    /// neither identity's name is in a file that goes into either target,
    /// and the store's is in the one file that writes passkeys, off by
    /// default.
    func testNothingWritesToTheSystemsListOfIdentitiesButTheOffer() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var read = 0
        for folder in ["Sources", "AutoFill", "Helper", "Safari"] {
            let files = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            while let file = files?.nextObject() as? URL {
                guard ["swift", "plist", "entitlements"].contains(file.pathExtension) else { continue }
                let text = try String(contentsOf: file, encoding: .utf8)
                XCTAssertEqual(text.contains("ASCredentialIdentityStore"), file.lastPathComponent == "PasskeyOffer.swift",
                               file.lastPathComponent)
                XCTAssertFalse(text.contains("ASPasswordCredentialIdentity"), file.lastPathComponent)
                XCTAssertFalse(text.contains("ASOneTimeCodeCredentialIdentity"), file.lastPathComponent)
                read += 1
            }
        }
        XCTAssertGreaterThan(read, 100, "the walk found the sources")
    }

    /// The three the door can hand over, and nothing it has no way to.
    func testTheProviderSaysItProvidesPasswordsPasskeysAndCodesAlone() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let capabilities = try XCTUnwrap(project.components(separatedBy: "ASCredentialProviderExtensionCapabilities:\n").last)
            .split(separator: "\n").prefix(4).map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(Array(capabilities.prefix(3)), ["ProvidesOneTimeCodes: true", "ProvidesPasskeys: true", "ProvidesPasswords: true"])
        XCTAssertFalse(capabilities[3].hasPrefix("Provides") || capabilities[3].hasPrefix("Supports"), capabilities[3])
        let plist = try String(contentsOf: root.appendingPathComponent("AutoFill/Info.plist"), encoding: .utf8)
        XCTAssertTrue(plist.contains("<key>ProvidesPasskeys</key>"))
        XCTAssertTrue(plist.contains("<key>ProvidesOneTimeCodes</key>"))
    }

    // MARK: A passkey

    private func passkeyDoor() -> AnsweringDoor {
        AnsweringDoor { request in
            switch request {
            case .passkeys: return .logins(site: nil, [DoorLogin(id: "AQ==", title: "GitHub", username: "canary")])
            case .assert: return .asserted(Self.assertion)
            default: return .refused("page")
            }
        }
    }

    func testAPasskeyIsListedAndAskedForAsAPasskey() async throws {
        let door = passkeyDoor()
        let sheet = sheet([Self.passkey], door: door)
        sheet.begin()
        await until { sheet.state == .listed }
        XCTAssertEqual(sheet.statement, "Passkeys for github.com")
        guard case .passkeys(Self.passkey)? = door.asked.first else { return XCTFail("not asked for passkeys") }
        sheet.choose(try XCTUnwrap(sheet.rows.first))
        await until { !self.asserted.isEmpty }
        XCTAssertEqual(asserted, [Self.assertion])
        XCTAssertEqual(finished, [])
        XCTAssertEqual(sheet.rows, [], "the list goes with the sheet")
        guard case .assert(let id, Self.passkey)? = door.asked.last else { return XCTFail("not asked to assert") }
        XCTAssertEqual(id, "AQ==")
    }

    func testAPasskeyTheSystemsListOfferedIsTakenWithNoRowChosen() async {
        let door = passkeyDoor()
        let sheet = sheet([Self.passkey], door: door)
        sheet.begin(takingALoneRow: true)
        await until { !self.asserted.isEmpty }
        XCTAssertEqual(asserted, [Self.assertion])
    }

    func testTwoRowsAreLeftToBeChosenFrom() async {
        let door = AnsweringDoor { _ in .logins(site: nil, Self.logins) }
        let sheet = sheet([Self.passkey], door: door)
        sheet.begin(takingALoneRow: true)
        await until { sheet.state == .listed }
        XCTAssertEqual(door.asked.count, 1)
    }

    func testAPasskeySheetSaysPasskeys() async {
        let door = AnsweringDoor { _ in .logins(site: nil, []) }
        let sheet = sheet([Self.passkey], door: door)
        sheet.begin()
        await until { sheet.state == .nothing }
        XCTAssertEqual(sheet.statement, "No passkey for github.com")
        XCTAssertFalse(sheet.sentence?.contains("Quick Access") ?? true, "it types no passkey")

        let shut = AnsweringDoor { _ in .shut(isRunning: true) }
        let locked = self.sheet([Self.passkey], door: shut)
        locked.begin()
        await until { locked.state == .shut(isRunning: true) }
        XCTAssertTrue(locked.sentence?.contains("the passkeys will come here") ?? false)
        locked.end()
    }

    func testAPasskeyRefusedStaysOnTheListAndSaysSoInItsOwnWords() async throws {
        for (reason, said) in [("gone", "That passkey can no longer be used."),
                               ("declined", "OriPass was not told to sign in with that passkey."),
                               ("page", "That passkey is not for this site.")] {
            let door = AnsweringDoor { request in
                if case .passkeys = request { return .logins(site: nil, Self.logins) }
                return .refused(reason)
            }
            let sheet = sheet([Self.passkey], door: door)
            sheet.begin()
            await until { sheet.state == .listed }
            sheet.choose(try XCTUnwrap(sheet.rows.first))
            await until { sheet.refusal != nil }
            XCTAssertEqual(sheet.refusal, said)
            XCTAssertEqual(sheet.state, .listed)
        }
    }

    func testAnAssertionIsNotShownInADump() {
        XCTAssertEqual("\(Self.assertion)", "SheetAssertion")
    }

    // MARK: A code

    private func codeDoor() -> AnsweringDoor {
        AnsweringDoor { request in
            switch request {
            case .codes: return .logins(site: "github.com", [Self.logins[0]])
            case .code: return .code(SheetCode(code: "123456"))
            default: return .refused("page")
            }
        }
    }

    func testACodeIsListedAndAskedForAsACodeAndHandsBackNothingElse() async throws {
        let door = codeDoor()
        let sheet = sheet(door: door, isForCodes: true)
        sheet.begin()
        await until { sheet.state == .listed }
        XCTAssertEqual(sheet.statement, "One-time codes for github.com")
        guard case .codes(Self.page)? = door.asked.first else { return XCTFail("not asked for codes") }
        sheet.choose(try XCTUnwrap(sheet.rows.first))
        await until { !self.codes.isEmpty }
        XCTAssertEqual(codes, [SheetCode(code: "123456")])
        XCTAssertEqual(finished, [])
        XCTAssertEqual(asserted, [])
        XCTAssertEqual(sheet.rows, [], "the list goes with the sheet")
        guard case .code("a", Self.page)? = door.asked.last else { return XCTFail("not asked for a code") }
    }

    func testAListOfCodesSaysSoWhenItHasNoneAndWhenItIsShut() async {
        let sheet = sheet(door: AnsweringDoor { _ in .logins(site: nil, []) }, isForCodes: true)
        sheet.begin()
        await until { sheet.state == .nothing }
        XCTAssertEqual(sheet.statement, "No one-time code for github.com")
        XCTAssertEqual(sheet.sentence, "Quick Access can find any login and copy its code.")

        let unnamed = self.sheet([], door: AnsweringDoor { _ in .logins(site: nil, []) }, isForCodes: true)
        unnamed.begin()
        XCTAssertEqual(unnamed.state, .unnamed)
        XCTAssertEqual(unnamed.sentence, "Quick Access can find any login and copy its code.")

        let locked = self.sheet(door: AnsweringDoor { _ in .shut(isRunning: true) }, isForCodes: true)
        locked.begin()
        await until { locked.state == .shut(isRunning: true) }
        XCTAssertTrue(locked.sentence?.contains("the one-time codes will come here") ?? false)
        locked.end()
    }

    func testACodeRefusedStaysOnTheListAndSaysSoInItsOwnWords() async throws {
        for (reason, said) in [("gone", "That login no longer has a code."),
                               ("declined", "OriPass was not told to hand over that code."),
                               ("insecure", "This page is not secure, and the login is saved for a secure one."),
                               ("page", "That login is not for this page.")] {
            let door = AnsweringDoor { request in
                if case .codes = request { return .logins(site: nil, Self.logins) }
                return .refused(reason)
            }
            let sheet = sheet(door: door, isForCodes: true)
            sheet.begin()
            await until { sheet.state == .listed }
            sheet.choose(try XCTUnwrap(sheet.rows.first))
            await until { sheet.refusal != nil }
            XCTAssertEqual(sheet.refusal, said)
            XCTAssertEqual(sheet.state, .listed)
            XCTAssertTrue(codes.isEmpty)
        }
    }

    func testACodeIsNotShownInADump() {
        let code = SheetCode(code: "123456")
        XCTAssertFalse("\(code)".contains("123456"))
        XCTAssertFalse(String(reflecting: code).contains("123456"))
    }
}

/// A door that answers as it is told and writes down what it was asked.
private final class AnsweringDoor: SheetDoor, @unchecked Sendable {
    private let lock = NSLock()
    private var said: [SheetRequest] = []
    private var answer: (SheetRequest) -> SheetAnswer
    private var gate: AsyncStream<Void>?

    init(_ answering: @escaping (SheetRequest) -> SheetAnswer) {
        answer = answering
    }

    var asked: [SheetRequest] { lock.withLock { said } }

    var answering: (SheetRequest) -> SheetAnswer {
        get { lock.withLock { answer } }
        set { lock.withLock { answer = newValue } }
    }

    /// When set, the next answer waits for this to end.
    var held: AsyncStream<Void>? {
        get { lock.withLock { gate } }
        set { lock.withLock { gate = newValue } }
    }

    func ask(_ request: SheetRequest) async -> SheetAnswer {
        let (answered, waiting) = lock.withLock {
            said.append(request)
            defer { gate = nil }
            return (answer(request), gate)
        }
        if let waiting {
            for await _ in waiting {}
        }
        return answered
    }
}
