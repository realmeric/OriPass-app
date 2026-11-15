import XCTest
@testable import OriPass

final class ItemTests: XCTestCase {
    func testEveryFixtureDecodes() throws {
        let items = try Fixture.items()
        XCTAssertEqual(items.map(\.type), [.login, .login, .secureNote, .card, .identity,
                                           .sshKey, .unknown(9), .login])
        XCTAssertEqual(try Fixture.items("list-trash").count, 1)
        XCTAssertTrue(try Fixture.items("list-trash")[0].isInTrash)
        let folders = (try Fixture.json("list-folders")["data"]?["data"]?.array ?? [])
            .compactMap(Folder.init(json:))
        XCTAssertEqual(folders.map(\.name), ["İş", "Ev"], "the row with no id is not a folder")
        _ = try Item(json: try XCTUnwrap(Fixture.json("item")["data"]))
    }

    func testTheEnumTablesAreTheNotes() throws {
        XCTAssertEqual([ItemType.login, .secureNote, .card, .identity, .sshKey].map(\.rawValue),
                       [1, 2, 3, 4, 5])
        XCTAssertEqual(Field.Kind.allCases.map(\.rawValue), [0, 1, 2, 3])
        XCTAssertEqual(URIMatch.allCases.map(\.rawValue), [0, 1, 2, 3, 4, 5])

        let bank = try Fixture.item(named: "İş Bankası")
        XCTAssertEqual(bank.fields.map(\.kind), [.text, .hidden, .boolean, .linked])
        XCTAssertEqual(bank.fields[3].linkedID, 100)
        XCTAssertEqual(bank.login?.uris.map(\.match), [nil, .host])
        XCTAssertFalse(bank.reprompt)
        XCTAssertTrue(try Fixture.item(named: "GitHub").reprompt)
    }

    func testALoginReadsWhatItHolds() throws {
        let bank = try Fixture.item(named: "İş Bankası")
        XCTAssertEqual(bank.login?.username, "deniz.yilmaz")
        XCTAssertEqual(bank.login?.password, "CANARY-1")
        XCTAssertEqual(bank.login?.totp, "JBSWY3DPEHPK3PXP")
        XCTAssertTrue(bank.favorite)
        XCTAssertNotNil(bank.folderID)
        XCTAssertEqual(bank.passwordHistory.map(\.password), ["CANARY-OLD-1", "CANARY-OLD-2"])
        XCTAssertEqual(try Fixture.item(named: "GitHub").login?.passkeysCreated.count, 1)
        XCTAssertTrue(try Fixture.item(named: "Eski forum").isArchived)
    }

    func testDatesDecodeWithAndWithoutFractionalSeconds() throws {
        let history = try Fixture.item(named: "İş Bankası").passwordHistory
        XCTAssertEqual(history[0].lastUsedDate, "2026-06-01T12:00:00.000Z")
        XCTAssertNotNil(history[0].lastUsed)
        XCTAssertEqual(history[1].lastUsedDate, "2025-11-12T08:30:00Z")
        XCTAssertNotNil(history[1].lastUsed)
        XCTAssertEqual(VaultDate.parse("2026-06-01T12:00:00.000Z"),
                       VaultDate.parse("2026-06-01T12:00:00Z"))
    }

    func testAnUntouchedItemGoesBackAsItCame() throws {
        for item in try Fixture.items() where item.type != .unknown(9) {
            let sent = try XCTUnwrap(item.patched(item))
            XCTAssertTrue(sent == item.raw, "\(item.id) changed on the way through")
            // And through bytes, since bytes are what is sent.
            XCTAssertTrue(try JSONValue(data: sent.data()) == item.raw)
        }
    }

    func testARenameKeepsThePasskeyAndTheKeyNobodyModelled() throws {
        let github = try Fixture.item(named: "GitHub")
        var edited = github
        edited.name = "GitHub (work)"
        let sent = try XCTUnwrap(github.patched(edited))

        XCTAssertEqual(sent["name"]?.string, "GitHub (work)")
        XCTAssertTrue(sent["login"]?["fido2Credentials"] == github.raw["login"]?["fido2Credentials"])
        XCTAssertEqual(sent["login"]?["fido2Credentials"]?.array?.count, 1)
        XCTAssertTrue(sent["somethingNew"] == github.raw["somethingNew"])
        XCTAssertNotNil(sent["somethingNew"])
        // Nothing but the name moved.
        XCTAssertTrue(sent.setting(["name"], to: .string("GitHub")) == github.raw)
    }

    /// `key` is the item's own key in its encrypted form, 180 characters on
    /// the items 2026.9.1 answers a write with. An edit sends it back as it
    /// came, whatever else it changed.
    func testAnEditSendsTheItemsOwnKeyBackAsItCame() throws {
        let answered = try Item(json: try XCTUnwrap(Fixture.json("item")["data"]))
        for item in [answered, try Fixture.item(named: "İş Bankası")] {
            let key = try XCTUnwrap(item.raw["key"]?.string)
            XCTAssertEqual(key.count, 180)
            var edited = item
            edited.name = "Başka bir ad"
            edited.favorite.toggle()
            edited.notes = "yeni not"
            guard case .login(var login) = edited.payload else { return XCTFail("not a login") }
            login.password = "CANARY-NEW"
            edited.payload = .login(login)
            let sent = try XCTUnwrap(item.patched(edited))
            XCTAssertEqual(sent["login"]?["password"]?.string, "CANARY-NEW")
            XCTAssertEqual(sent["key"]?.string, key)
            XCTAssertEqual(try JSONValue(data: sent.data())["key"]?.string, key)
        }
    }

    func testAPasswordChangeTouchesOnlyThePassword() throws {
        let github = try Fixture.item(named: "GitHub")
        var edited = github
        guard case .login(var login) = edited.payload else { return XCTFail("not a login") }
        login.password = "CANARY-NEW"
        edited.payload = .login(login)
        let sent = try XCTUnwrap(github.patched(edited))

        XCTAssertEqual(sent["login"]?["password"]?.string, "CANARY-NEW")
        XCTAssertTrue(sent.setting(["login", "password"], to: .string("CANARY-2")) == github.raw)
    }

    func testAnUnknownTypeDecodesAndIsNeverWritten() throws {
        let licence = try Fixture.item(named: "Ehliyet")
        XCTAssertEqual(licence.type, .unknown(9))
        guard case .unknown(let payload) = licence.payload else { return XCTFail("modelled?") }
        XCTAssertEqual(payload["issuingCountry"]?.string, "TR")
        var edited = licence
        edited.name = "Driving licence"
        XCTAssertNil(licence.patched(edited))
    }

    func testAMissingNameIsAShapeErrorAndNotATrap() throws {
        let nameless = try Fixture.item(named: "GitHub").raw.object?.filter { $0.key != "name" }
        XCTAssertThrowsError(try Item(json: .object(nameless ?? [:]))) {
            XCTAssertEqual($0 as? ShapeError, ShapeError(missing: "name"))
        }
    }

    func testNothingThatHoldsASecretDescribesIt() throws {
        for item in try Fixture.items() + Fixture.items("list-trash") {
            var dumped = ""
            dump(item, to: &dumped)
            dump(item.payload, to: &dumped)
            dump(item.raw, to: &dumped)
            dump(item.fields, to: &dumped)
            dump(item.passwordHistory, to: &dumped)
            let said = [String(describing: item), String(reflecting: item), "\(item)",
                        String(describing: item.payload), String(reflecting: item.payload),
                        String(describing: item.raw), String(reflecting: item.raw),
                        String(describing: item.fields), String(reflecting: item.passwordHistory),
                        dumped].joined(separator: "\n")
            XCTAssertFalse(said.contains("CANARY"), "item \(item.id) describes a secret")
        }
        XCTAssertEqual(String(describing: try Fixture.item(named: "İş Bankası")),
                       "Item(3f9d0c7a-0001-4b6e-9d1f-b2f400a1e000, type 1)")
    }
}
