import AppKit
import SwiftUI
import XCTest
@testable import OriPass

/// The details of the four types that are not a login, and of a fifth that
/// this app does not know.
@MainActor
final class OtherDetailTests: XCTestCase {
    private func object(_ type: Int64, _ name: String, _ key: String, _ payload: [String: JSONValue],
                        _ more: [String: JSONValue] = [:]) -> JSONValue {
        let common: [String: JSONValue] = [
            "object": .string("item"), "id": .string("other-\(name)"), "type": .int(type), "name": .string(name),
            "favorite": .bool(false), "reprompt": .int(0), "notes": .null, "fields": .null,
            "creationDate": .string("2025-01-05T09:30:00.000Z"), "revisionDate": .string("2025-03-12T16:41:03.000Z"),
            key: .object(payload),
        ]
        return .object(common.merging(more) { $1 })
    }

    private func detail(_ json: JSONValue) throws -> ItemDetail {
        ItemDetail(item: try Item(json: json), vault: .personal)
    }

    private func card(_ payload: [String: JSONValue]) throws -> ItemDetail {
        try detail(object(3, "Kart", "card", payload))
    }

    private func identity(_ payload: [String: JSONValue]) throws -> ItemDetail {
        try detail(object(4, "Kimlik", "identity", payload))
    }

    private func store(_ items: [JSONValue]) async -> VaultStore {
        let backend = FakeBackend(items: items, folders: [], password: DemoVault.password)
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        return store
    }

    private func demo() async -> VaultStore {
        let vault = DemoVault.objects()
        let backend = FakeBackend(items: vault.items, folders: vault.folders, password: DemoVault.password)
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        return store
    }

    private func hosted(_ panes: Panes) -> NSWindow {
        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: PanesView(panes: panes))
        window.setContentSize(CGSize(width: Metrics.windowSize.width, height: Metrics.windowSize.height * 2))
        window.layoutIfNeeded()
        return window
    }

    private func turn(_ seconds: Double = 0.05) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func choose(_ title: String, in panes: Panes) throws {
        let entry = try XCTUnwrap(panes.list.entries.first { $0.item.name == title }, "no \(title)")
        panes.select(item: entry.id)
    }

    // MARK: A card

    func testACardShowsItsHolderBrandNumberExpiryAndCode() throws {
        let read = try card([
            "cardholderName": .string("Deniz Yılmaz"), "brand": .string("Visa"),
            "number": .string("4539578763621486"), "expMonth": .string("3"), "expYear": .string("2029"),
            "code": .string("CANARY-CVV"),
        ])
        XCTAssertEqual(read.main.map(\.label), ["cardholder name", "brand", "number", "expiry date", "security code"])
        XCTAssertEqual(read.main.map(\.spoken), [
            "Deniz Yılmaz", "Visa", "concealed, ending 1486", "03/2029", "concealed",
        ])
        XCTAssertEqual(read.main.map(\.isHidden), [false, false, true, false, true])
        XCTAssertNil(read.notice)
    }

    func testAnExpiryIsAMonthAndAYearOrWhicheverWasWritten() {
        XCTAssertEqual(ItemDetail.expiry(month: "10", year: "2026"), "10/2026")
        XCTAssertEqual(ItemDetail.expiry(month: "7", year: " 2031 "), "07/2031")
        XCTAssertEqual(ItemDetail.expiry(month: "Oct", year: "2026"), "Oct/2026", "a month that is not a number stays as written")
        XCTAssertEqual(ItemDetail.expiry(month: nil, year: "2026"), "2026")
        XCTAssertEqual(ItemDetail.expiry(month: "11", year: ""), "11")
        XCTAssertNil(ItemDetail.expiry(month: nil, year: ""))
    }

    func testANumberTooShortToHideBehindFourDigitsIsHiddenWhole() throws {
        let short = try card(["number": .string("1234567")])
        XCTAssertEqual(short.main.map(\.spoken), ["concealed"])
        let spaced = try card(["number": .string("3742 454554 00126")])
        XCTAssertEqual(spaced.main.map(\.spoken), ["concealed, ending 0126"])
        // Whatever the length, the same dots.
        if case .masked(_, let last) = spaced.main[0].value { XCTAssertEqual(last, "0126") } else { XCTFail("not masked") }
    }

    // MARK: An identity

    func testAnIdentityIsANameThenCompanyEmailPhoneAnAddressBlockAndThreeHiddenNumbers() throws {
        let read = try identity([
            "title": .string("Mx"), "firstName": .string("Deniz"), "middleName": .null, "lastName": .string("Yılmaz"),
            "company": .string("Şişecam"), "email": .string("deniz@kanarya.invalid"), "phone": .string("+90 555 000 00 00"),
            "address1": .string("Moda Cd. 12"), "address2": .string("D: 4"), "address3": .null,
            "city": .string("İstanbul"), "state": .string("Kadıköy"), "postalCode": .string("34710"),
            "country": .string("TR"), "ssn": .string("CANARY-SSN-1"), "passportNumber": .string("CANARY-PASSPORT-1"),
            "licenseNumber": .string("CANARY-LICENCE-1"), "username": .null,
        ])
        XCTAssertEqual(read.main.map(\.label), [
            "name", "company", "email", "phone", "address", "social security number", "passport number",
            "licence number",
        ])
        XCTAssertEqual(read.main.map(\.spoken), [
            "Mx Deniz Yılmaz", "Şişecam", "deniz@kanarya.invalid", "+90 555 000 00 00",
            "Moda Cd. 12\nD: 4\n34710 İstanbul\nKadıköy\nTR", "concealed", "concealed", "concealed",
        ])
        XCTAssertEqual(read.main.map(\.isHidden), [false, false, false, false, false, true, true, true])
    }

    // MARK: A key, and a note

    func testAnSSHKeyShowsItsPublicKeyAndFingerprintAndHidesTheOtherHalf() throws {
        let read = try detail(object(5, "Anahtar", "sshKey", [
            "publicKey": .string("ssh-ed25519 AAAA deniz@mac"), "keyFingerprint": .string("SHA256:abc"),
            "privateKey": .string("CANARY-private"),
        ]))
        XCTAssertEqual(read.main.map(\.label), ["public key", "fingerprint", "private key"])
        XCTAssertEqual(read.main.map(\.spoken), ["ssh-ed25519 AAAA deniz@mac", "SHA256:abc", "concealed"])
    }

    func testANoteIsItsNotesAndNothingElse() async throws {
        let read = try detail(object(2, "Not", "secureNote", ["type": .int(0)], ["notes": .string("Bir **not**.")]))
        XCTAssertTrue(read.main.isEmpty)
        XCTAssertTrue(read.websites.isEmpty && read.fields.isEmpty)
        XCTAssertEqual(read.note?.plain, "Bir not.")
        XCTAssertNil(read.notice)
        XCTAssertTrue(read.canEdit)
    }

    // MARK: Nothing, and a type nobody told us of

    func testAnEmptyValueDrawsNoRow() throws {
        XCTAssertTrue(try card([:]).main.isEmpty)
        XCTAssertTrue(try card(["cardholderName": .string(""), "brand": .string("  "), "number": .string(""),
                                "expMonth": .string(""), "expYear": .null, "code": .string("")]).main.isEmpty)
        XCTAssertEqual(try card(["brand": .string("Visa"), "code": .string("CANARY-CVV")]).main.map(\.label),
                       ["brand", "security code"])
        XCTAssertTrue(try identity(["firstName": .string(""), "address1": .string(" "), "city": .null,
                                    "ssn": .string("")]).main.isEmpty)
        XCTAssertEqual(try identity(["city": .string("İstanbul")]).main.map(\.spoken), ["İstanbul"],
                       "a lone city is still an address")
        XCTAssertTrue(try detail(object(5, "Anahtar", "sshKey", ["publicKey": .string(""), "privateKey": .null])).main.isEmpty)
        XCTAssertTrue(try detail(object(9, "Yeni", "driversLicense", ["firstName": .string(""), "number": .null,
                                                                       "extra": .object([:]), "list": .array([])])).main.isEmpty)
    }

    func testATypeThatIsNotKnownShowsEveryKeyAndHidesTheSecretOnes() throws {
        let read = try detail(object(9, "Ehliyet", "driversLicense", [
            "firstName": .string("Deniz"), "licenseNumber": .string("CANARY-LICENCE-1"),
            "issuingCountry": .string("TR"), "expirationDate": .string("2031-01-01"),
            "points": .int(12), "valid": .bool(true), "pin": .string("CANARY-pin"),
            "restrictions": .array([.string("B"), .string("C")]),
            "address": .object(["street": .string("Moda"), "secretNote": .string("CANARY-x")]),
        ]))
        XCTAssertEqual(read.notice, ItemDetail.unknownNotice)
        let rows = Dictionary(uniqueKeysWithValues: read.main.map { ($0.label, $0) })
        XCTAssertEqual(Set(rows.keys), [
            "first name", "license number", "issuing country", "expiration date", "points", "valid", "pin",
            "restrictions 1", "restrictions 2", "address street", "address secret note",
        ])
        XCTAssertEqual(read.main.map(\.label).first, "address secret note", "in the order of the keys' names")
        for hidden in ["license number", "pin", "address secret note"] {
            XCTAssertEqual(rows[hidden]?.spoken, "concealed", hidden)
        }
        for shown in ["first name": "Deniz", "issuing country": "TR", "points": "12", "valid": "yes",
                      "restrictions 2": "C", "address street": "Moda"] {
            XCTAssertEqual(rows[shown.key]?.spoken, shown.value, shown.key)
        }
    }

    func testWhatMakesAKeyLookLikeASecret() {
        for name in ["password", "licenseNumber", "api_key", "cvv", "PIN", "recoveryPhrase", "accessToken", "apikey",
                     "accountNumber", "clientSecret"] {
            XCTAssertTrue(ItemDetail.suggestsSecret(name), name)
        }
        for name in ["firstName", "issuingCountry", "expirationDate", "keyboard", "pinned", "points", "street"] {
            XCTAssertFalse(ItemDetail.suggestsSecret(name), name)
        }
    }

    func testTheUnknownTypesEditIsDisabledAndSaysWhy() async throws {
        let read = try detail(object(9, "Ehliyet", "driversLicense", ["firstName": .string("Deniz")]))
        XCTAssertFalse(read.canEdit)
        XCTAssertEqual(read.editHelp, ItemDetail.unknownEditHelp)
        for json in [object(3, "Kart", "card", [:]), object(4, "Kimlik", "identity", [:]),
                     object(5, "Anahtar", "sshKey", [:]), object(2, "Not", "secureNote", [:])] {
            XCTAssertTrue(try detail(json).canEdit)
            XCTAssertNil(try detail(json).editHelp)
        }

        let panes = Panes(store: await demo())
        let window = hosted(panes)
        try choose("Ehliyet", in: panes)
        try await turn()
        let help = said(in: window.contentView, keys: ["accessibilityHelp"])
        XCTAssertTrue(help.contains(ItemDetail.unknownEditHelp), "\(help)")
        let words = said(in: window.contentView)
        XCTAssertTrue(words.contains("Edit"), "\(words)")
        XCTAssertTrue(words.contains(ItemDetail.unknownNotice), "the banner is over the fields: \(words)")
        XCTAssertEqual(editButton(in: window.contentView), false, "the element with the tooltip cannot be pressed")

        try choose("Bonus Kart", in: panes)
        try await turn()
        XCTAssertFalse(said(in: window.contentView, keys: ["accessibilityHelp"]).contains(ItemDetail.unknownEditHelp))
        XCTAssertFalse(said(in: window.contentView).contains(ItemDetail.unknownNotice))
    }

    /// The element that carries Edit's tooltip, and whether it is enabled.
    private func editButton(in element: Any?, depth: Int = 0) -> Bool? {
        guard let object = element as AnyObject?, depth < 40 else { return nil }
        if let help = object.accessibilityHelp?(), help == ItemDetail.unknownEditHelp {
            return object.isAccessibilityEnabled?()
        }
        var children = object.accessibilityChildren?() ?? []
        if children.isEmpty, let lazy = object as? NSObject {
            let count = lazy.accessibilityArrayAttributeCount(.children)
            children = count > 0 ? lazy.accessibilityArrayAttributeValues(.children, index: 0, maxCount: count) : []
        }
        for child in children {
            if let found = editButton(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    // MARK: What is hidden

    func testNothingHiddenIsInTheAccessibilityTreeOfTheOtherTypes() async throws {
        let panes = Panes(store: await demo())
        let window = hosted(panes)
        // The note's own canary and the email's domain are shown where they are.
        var seen = Set<ItemType>()
        var hiddenSomething = 0
        let secrets = DemoVault.cardNumbers + [DemoVault.cardCode, DemoVault.privateKey, DemoVault.hiddenField]
            + DemoVault.numbers
        var walked = 0
        // The archive and the trash too, as the logins are walked: an item
        // put away is drawn by the same view.
        for row in [SidebarRow.allItems, .archive, .trash] {
            panes.select(row)
            walked += panes.list.entries.count
            for entry in panes.list.entries where entry.item.type != .login {
                panes.select(item: entry.id)
                try await turn(0.02)
                let words = said(in: window.contentView)
                XCTAssertTrue(words.contains(entry.item.name), "\(entry.id) is not drawn")
                for secret in secrets {
                    XCTAssertFalse(words.contains { $0.contains(secret) }, "\(entry.item.name) says a hidden value")
                }
                if panes.detail?.main.contains(where: \.isHidden) == true {
                    XCTAssertTrue(words.contains { $0.hasPrefix(ItemDetail.concealed) }, "\(entry.item.name): \(words)")
                    hiddenSomething += 1
                }
                seen.insert(entry.item.type)
            }
        }
        panes.select(.allItems)
        XCTAssertEqual(walked, DemoVault.objects().items.count, "all three rows hold the whole demo between them")
        XCTAssertEqual(seen, [.secureNote, .card, .identity, .sshKey, .unknown(9)])
        // Three cards, the first identity, two keys and the licence. The
        // demo's archived and deleted items are both logins, so the two
        // rows after All Items add nothing to the count today.
        XCTAssertEqual(hiddenSomething, 7)

        // A card says its last four, which is what a printed card does.
        try choose("Maximum", in: panes)
        try await turn()
        let words = said(in: window.contentView)
        XCTAssertTrue(words.contains("concealed, ending 1486"), "\(words)")
        XCTAssertTrue(words.contains("Visa") && words.contains("Deniz Yılmaz"), "\(words)")
        XCTAssertFalse(words.contains { $0.contains("453957876362") }, "\(words)")
    }

    func testTheOtherDetailsSayNothingOfWhatTheyHoldWhenPrinted() throws {
        let read = try card(["number": .string("CANARY-4539578763621486"), "code": .string("CANARY-CVV")])
        let unknown = try detail(object(9, "Ehliyet", "driversLicense", ["licenseNumber": .string("CANARY-licence")]))
        var out = ""
        dump(read, to: &out)
        dump(unknown.main, to: &out)
        out += "\(read.main) \(unknown.main)"
        XCTAssertFalse(out.contains("CANARY"), out)
    }

    func testALinkedFieldNamesWhatItPointsAtOnEveryType() {
        XCTAssertEqual(ItemDetail.linked(305), "number")
        XCTAssertEqual(ItemDetail.linked(303), "security code")
        XCTAssertEqual(ItemDetail.linked(410), "email")
        XCTAssertEqual(ItemDetail.linked(100), "username")
        XCTAssertEqual(ItemDetail.linked(nil), "another field")
    }
}
