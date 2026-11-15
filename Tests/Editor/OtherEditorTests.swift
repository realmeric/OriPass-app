import AppKit
import SwiftUI
import XCTest
@testable import OriPass

/// The form for a card, an identity, a note and a key, over the fake
/// engine: one part changed, and the one key that goes back different.
@MainActor
final class OtherEditorTests: XCTestCase {
    private var backend: FakeBackend!
    private var pasteboard: NSPasteboard!

    override func setUp() {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("oripass-test-\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        backend = nil
    }

    private func demo(_ change: (JSONValue) -> JSONValue = { $0 }) async -> VaultStore {
        let vault = DemoVault.objects()
        backend = FakeBackend(items: vault.items.map(change), folders: vault.folders, password: DemoVault.password)
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        return store
    }

    private func editing(_ title: String, in store: VaultStore) throws -> (panes: Panes, editor: Editor, item: Item) {
        let panes = Panes(store: store, clipboard: Clipboard(pasteboard: pasteboard))
        let entry = try XCTUnwrap(panes.list.entries.first { $0.item.name == title }, "no \(title)")
        panes.select(item: entry.id)
        XCTAssertTrue(panes.beginEdit(), title)
        return (panes, try XCTUnwrap(panes.editor), entry.item)
    }

    /// Opens the form on `title`, makes the change and saves, and expects
    /// the object that was read to go back with `path` now `value` and
    /// nothing else different.
    private func expect(_ title: String, _ change: (Editor) -> Void, sends path: [String], as value: JSONValue,
                        in store: VaultStore, line: UInt = #line) async throws {
        let (panes, editor, item) = try editing(title, in: store)
        XCTAssertFalse(editor.isDirty, line: line)
        change(editor)
        XCTAssertTrue(editor.isDirty, "\(path)", line: line)
        let before = backend.count(of: "save")
        await panes.saveEdit()?.value
        XCTAssertEqual(backend.count(of: "save"), before + 1, "\(path)", line: line)
        XCTAssertEqual(backend.lastSaved, item.raw.setting(path, to: value), "\(path)", line: line)
        XCTAssertNil(panes.editor, line: line)
        XCTAssertNil(panes.refused, line: line)
    }

    private func hosted(_ panes: Panes) -> NSWindow {
        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: PanesView(panes: panes))
        window.setContentSize(Metrics.windowSize)
        window.layoutIfNeeded()
        return window
    }

    // MARK: A card

    func testEachPartOfACardChangesItsOwnKey() async throws {
        let store = await demo()
        let changes: [(String, (Editor) -> Void, JSONValue)] = [
            ("cardholderName", { $0.form.card.holder = "D. Yılmaz" }, .string("D. Yılmaz")),
            ("brand", { $0.brand("Maestro") }, .string("Maestro")),
            ("number", { $0.form.card.number = DemoVault.cardNumbers[0] }, .string(DemoVault.cardNumbers[0])),
            ("expYear", { $0.form.card.year = " 2041 " }, .string("2041")),
            ("code", { $0.form.card.code = DemoVault.typedCode }, .string(DemoVault.typedCode)),
            ("code", { $0.form.card.code = "" }, .null),
        ]
        for (key, change, value) in changes {
            try await expect("Bonus Kart", change, sends: ["card", key], as: value, in: store)
        }
        try await expect("Bonus Kart", { $0.form.title = "Bonus" }, sends: ["name"], as: .string("Bonus"), in: store)
    }

    func testAMonthIsChosenAndTheSameMonthSpelledAnotherWayIsNoChange() async throws {
        let store = await demo()
        let (panes, editor, item) = try editing("Maximum", in: store)
        let was = try XCTUnwrap(item.raw["card"]?["expMonth"]?.string.flatMap(Int.init))
        editor.toggle(.month)
        editor.month(was)
        XCTAssertNil(editor.menu)
        XCTAssertFalse(editor.isDirty)
        let other = was % 12 + 1
        editor.month(other)
        await panes.saveEdit()?.value
        XCTAssertEqual(backend.lastSaved, item.raw.setting(["card", "expMonth"], to: .string(String(other))))

        XCTAssertTrue(panes.beginEdit())
        panes.editor?.month(nil)
        await panes.saveEdit()?.value
        XCTAssertEqual(backend.lastSaved?["card"]?["expMonth"], .null)
        XCTAssertEqual(Card.month("7"), "07")
        XCTAssertEqual(Card.month("07"), "07")
        XCTAssertEqual(Card.month("13"), "13")
    }

    func testACardsFormSaysItsRowsAndNotItsNumberOrItsCode() async throws {
        let store = await demo()
        let (panes, editor, item) = try editing("Bonus Kart", in: store)
        let window = hosted(panes)
        var words = said(in: window.contentView)
        for word in ["cardholder name", "brand", "Mastercard", "number", "expiry month", "expiry year",
                     "security code", "Deniz Yılmaz", "add more", "notes"] {
            XCTAssertTrue(words.contains(word), "the form does not say \(word)")
        }
        XCTAssertFalse(words.contains("website"))
        XCTAssertFalse(words.contains("add a website"))
        let number = try XCTUnwrap(item.raw["card"]?["number"]?.string)
        for value in [number, DemoVault.cardCode] {
            XCTAssertFalse(words.contains { $0.contains(value) }, "a hidden value is said while it is concealed")
        }
        XCTAssertEqual(editor.hiddenRows, [Editor.numberRow, Editor.codeRow])

        panes.toggleRevealed()
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        words = said(in: window.contentView)
        XCTAssertTrue(words.contains(number), "⌘R did not show the number")
        XCTAssertTrue(words.contains(DemoVault.cardCode), "⌘R did not show the code")
    }

    // MARK: An identity

    func testEachPartOfAnIdentityChangesItsOwnKey() async throws {
        let store = await demo()
        // Dükkan (fatura) has seven of its eighteen as `null`.
        for key in Identity.Key.allCases {
            try await expect("Dükkan (fatura)", { $0.form.identity[key] = "yeni \(key.rawValue)" },
                             sends: ["identity", key.rawValue], as: .string("yeni \(key.rawValue)"), in: store)
        }
        try await expect("Deniz Yılmaz", { $0.form.identity[.title] = "" }, sends: ["identity", "title"], as: .null,
                         in: store)
    }

    func testAnIdentitysRowsAreEveryKeyOnceInTheOrderTheDetailsRead() async throws {
        let rows = EditorForm.identityRows.joined()
        XCTAssertEqual(Set(rows), Set(Identity.Key.allCases))
        XCTAssertEqual(rows.count, Identity.Key.allCases.count)
        XCTAssertEqual(rows.map(\.label).first, "title")
        // The postcode before the town, as the details write an address.
        let places = Array(rows)
        XCTAssertLessThan(try XCTUnwrap(places.firstIndex(of: .postalCode)), try XCTUnwrap(places.firstIndex(of: .city)))
        for key in Identity.Key.allCases where key != .address1 && key != .address2 && key != .address3 {
            XCTAssertEqual(ItemDetail.linked(key.linkedID), key.label, key.rawValue)
        }

        let store = await demo()
        let (panes, editor, _) = try editing("Deniz Yılmaz", in: store)
        let words = said(in: hosted(panes).contentView)
        for key in Identity.Key.allCases {
            XCTAssertTrue(words.contains(key.label), "the form does not say \(key.label)")
        }
        XCTAssertTrue(words.contains("Şişecam"))
        for value in DemoVault.numbers {
            XCTAssertFalse(words.contains { $0.contains(value) }, "a hidden value is said while it is concealed")
        }
        XCTAssertEqual(editor.hiddenRows, [.ssn, .passportNumber, .licenseNumber].map(Editor.row(of:)))
    }

    /// Another client may have written nothing as an empty string and not
    /// as `null`. A part that was not typed into goes back as it came.
    func testAnEmptyStringThatWasNotTypedIntoGoesBackAsAnEmptyString() async throws {
        let store = await demo { item in
            switch item["name"]?.string {
            case "Dükkan (fatura)": return item.setting(["identity", "middleName"], to: .string(""))
            case "Bonus Kart": return item.setting(["card", "brand"], to: .string(""))
            case "Sunucu anahtarı": return item.setting(["sshKey", "keyFingerprint"], to: .string(""))
            default: return item
            }
        }
        try await expect("Dükkan (fatura)", { $0.form.identity[.phone] = "+90 216 000 00 00" },
                         sends: ["identity", "phone"], as: .string("+90 216 000 00 00"), in: store)
        try await expect("Bonus Kart", { $0.form.card.holder = "D. Yılmaz" }, sends: ["card", "cardholderName"],
                         as: .string("D. Yılmaz"), in: store)
        try await expect("Sunucu anahtarı", { $0.form.title = "Sunucu" }, sends: ["name"], as: .string("Sunucu"),
                         in: store)
    }

    // MARK: A note

    func testANotesWordsAreItsOneKey() async throws {
        let store = await demo()
        try await expect("Kombi servis notu", { $0.form.notes += "\nGelecek yıl 12 Ekim." }, sends: ["notes"],
                         as: .string("Servis her ekim ayında gelir.\n\(DemoVault.note) abone numarası 7741.\nGelecek yıl 12 Ekim."),
                         in: store)
        try await expect("Boş not", { $0.form.notes = "Artık boş değil." }, sends: ["notes"],
                         as: .string("Artık boş değil."), in: store)

        let (panes, editor, _) = try editing("Yazılım lisansı", in: store)
        XCTAssertEqual(editor.hiddenRows, [Editor.row(ofField: 0)])
        // Nothing of a note's own for a linked field to point at.
        XCTAssertEqual(editor.fieldKinds, [.text, .hidden, .boolean])
        editor.addField(.linked)
        XCTAssertEqual(editor.form.fields.count, 1)
        let words = said(in: hosted(panes).contentView)
        XCTAssertTrue(words.contains("notes"))
        XCTAssertTrue(words.contains("license key"))
        XCTAssertFalse(words.contains("username"))
        XCTAssertFalse(words.contains { $0.contains(DemoVault.hiddenField) })
    }

    // MARK: A key

    func testAPastedKeyReplacesThePrivateKeyAndTheTwoThingsReadOffIt() async throws {
        let store = await demo()
        let (panes, editor, item) = try editing("Sunucu anahtarı", in: store)
        XCTAssertFalse(editor.hasNewKey)
        pasteboard.clearContents()
        pasteboard.setString(DemoVault.pastedKey, forType: .string)
        XCTAssertTrue(panes.pasteKey())
        XCTAssertTrue(editor.hasNewKey)
        XCTAssertTrue(editor.isDirty)
        XCTAssertNil(editor.keyRefusal)

        await panes.saveEdit()?.value
        let sent = try XCTUnwrap(backend.lastSaved)
        let key = try PastedKey(pasted: DemoVault.pastedKey)
        XCTAssertEqual(sent, item.raw.setting(["sshKey", "privateKey"], to: .string(DemoVault.pastedKey))
            .setting(["sshKey", "publicKey"], to: .string(key.publicKey))
            .setting(["sshKey", "keyFingerprint"], to: .string(key.fingerprint)))
        XCTAssertNotEqual(sent["sshKey"]?["publicKey"], item.raw["sshKey"]?["publicKey"])
        XCTAssertEqual(panes.detail?.value(of: "fingerprint"), key.fingerprint)
    }

    func testWhatIsNotAWholeKeyLeavesTheKeyAsItWas() async throws {
        let store = await demo()
        let (panes, editor, _) = try editing("Sunucu anahtarı", in: store)
        let whole = DemoVault.pastedKey
        let refused: [(String, PastedKey.Refusal)] = [
            ("", .notAKey),
            ("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemo deniz@mac", .notAKey),
            ("-----BEGIN RSA PRIVATE KEY-----\nMIIB\n-----END RSA PRIVATE KEY-----\n", .anotherFormat),
            ("-----BEGIN PRIVATE KEY-----\nMIIB\n-----END PRIVATE KEY-----\n", .anotherFormat),
            (whole.replacingOccurrences(of: PastedKey.last, with: ""), .cutShort),
            (whole.split(separator: "\n").enumerated().filter { $0.offset != 2 }.map(\.element).joined(separator: "\n"),
             .cutShort),
            (PastedKey.first + "\n" + PastedKey.last, .cutShort),
            (DemoVault.keyFile(cipher: "aes256-ctr"), .locked),
        ]
        for (text, why) in refused {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            XCTAssertFalse(panes.pasteKey())
            XCTAssertEqual(editor.keyRefusal, why.sentence)
            XCTAssertFalse(editor.isDirty)
            XCTAssertFalse(editor.hasNewKey)
        }
        // A good one takes the sentence away.
        XCTAssertTrue(editor.replaceKey(with: whole))
        XCTAssertNil(editor.keyRefusal)
    }

    func testAKeyIsReadOffTheFileAsAPubFileWritesIt() throws {
        // Lines ended the way another system ends them, and room around.
        let pasted = "\n  " + DemoVault.pastedKey.replacingOccurrences(of: "\n", with: "\r\n") + "\n\n"
        let key = try PastedKey(pasted: pasted)
        XCTAssertEqual(key.privateKey, DemoVault.pastedKey)
        // Eleven letters of a name and thirty-two counted bytes, each
        // behind its length.
        var half = Data([0, 0, 0, 11]) + Data("ssh-ed25519".utf8) + Data([0, 0, 0, 32])
        half.append(contentsOf: 0..<32)
        XCTAssertEqual(key.publicKey, "ssh-ed25519 " + half.base64EncodedString())
        XCTAssertTrue(key.publicKey.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI"))
        XCTAssertTrue(key.fingerprint.hasPrefix("SHA256:"))
        XCTAssertEqual(key.fingerprint.count, 7 + 43)
        XCTAssertFalse(key.fingerprint.contains("="))
        // The canary is a line of the file by itself.
        XCTAssertTrue(DemoVault.pastedKey.contains("\n\(DemoVault.pasted)\n"))
        XCTAssertEqual("\(key)", "PastedKey")
    }

    func testNoPartOfAFormIsSaidByAPrintOrADump() async throws {
        let store = await demo()
        var parts: [(Any, said: String)] = []
        var hidden: [String] = []

        let card = try editing("Bonus Kart", in: store)
        hidden += [card.editor.form.card.number, card.editor.form.card.code]
        parts.append((card.editor.form.card, "CardPart"))

        let identity = try editing("Deniz Yılmaz", in: store)
        for key in [Identity.Key.ssn, .passportNumber, .licenseNumber] {
            hidden.append(try XCTUnwrap(identity.editor.form.identity[key]))
        }
        parts.append((identity.editor.form.identity, "IdentityPart"))

        let key = try editing("Sunucu anahtarı", in: store)
        hidden.append(key.editor.form.key.privateKey)
        parts.append((key.editor.form.key, "KeyPart"))

        let login = try editing("İş Bankası", in: store)
        let fields = login.editor.form.fields
        let concealed = try XCTUnwrap(fields.first { $0.kind == .hidden })
        hidden += [concealed.value, login.editor.form.password, login.editor.form.totp]
        parts.append((concealed, "CustomField(\(concealed.id))"))
        parts.append((fields, "[" + fields.map { "CustomField(\($0.id))" }.joined(separator: ", ") + "]"))
        parts.append((login.editor.form, "EditorForm"))
        parts.append((login.editor, "Editor(\(login.item.id))"))

        XCTAssertEqual(hidden.count, 9)
        for value in hidden { XCTAssertGreaterThan(value.count, 2, "a hidden value the demo does not have") }
        for (part, expected) in parts {
            XCTAssertEqual(String(describing: part), expected)
            var dumped = ""
            dump(part, to: &dumped)
            for line in [String(describing: part), String(reflecting: part), dumped] {
                for value in hidden { XCTAssertFalse(line.contains(value), "\(expected) says a hidden value") }
            }
        }
    }

    func testAKeysFormSaysThePublicHalfAndNeverThePrivateOne() async throws {
        let store = await demo()
        let (panes, editor, item) = try editing("Sunucu anahtarı", in: store)
        let window = hosted(panes)
        var words = said(in: window.contentView)
        for word in ["public key", "fingerprint", "private key", "Paste a New Key",
                     try XCTUnwrap(item.raw["sshKey"]?["keyFingerprint"]?.string)] {
            XCTAssertTrue(words.contains(word), "the form does not say \(word)")
        }
        XCTAssertFalse(words.contains { $0.contains(DemoVault.privateKey) })
        XCTAssertTrue(editor.hiddenRows.isEmpty)
        XCTAssertTrue(editor.fieldKinds == [.text, .hidden, .boolean])

        editor.replaceKey(with: DemoVault.pastedKey)
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        words = said(in: window.contentView)
        XCTAssertTrue(words.contains(try PastedKey(pasted: DemoVault.pastedKey).fingerprint))
        XCTAssertFalse(words.contains { $0.contains(DemoVault.pasted) })
    }

    // MARK: Every type

    func testALinkedFieldPointsAtSomethingOfItsOwnType() async throws {
        let store = await demo()
        let (panes, editor, item) = try editing("Bonus Kart", in: store)
        XCTAssertEqual(editor.linkable.map(\.id), [300, 304, 305, 301, 302, 303])
        for target in editor.linkable { XCTAssertEqual(ItemDetail.linked(target.id), target.name) }
        editor.addField(.linked)
        editor.form.fields[0].name = "Kod"
        XCTAssertEqual(editor.form.fields[0].linkedID, 300)
        editor.link(editor.form.fields[0].id, to: 303)
        await panes.saveEdit()?.value
        XCTAssertEqual(backend.lastSaved, item.raw.setting(["fields"], to: .array([
            .object(["name": .string("Kod"), "value": .null, "type": .int(3), "linkedId": .int(303)]),
        ])))
        XCTAssertEqual(EditorForm.linkable(in: .identity).count, Identity.Key.allCases.count)
        XCTAssertEqual(EditorForm.linkable(in: .login).map(\.id), [100, 101])
    }

    func testACardChangedUnderTheFormKeepsWhatWasTypedOverTheNewerCopy() async throws {
        let store = await demo()
        let (_, editor, item) = try editing("Bonus Kart", in: store)
        editor.form.card.code = DemoVault.typedCode
        let newer = try Item(json: item.raw.setting(["card", "cardholderName"], to: .string("Deniz Y."))
            .setting(["card", "code"], to: .string("111")))
        editor.rebase(onto: newer)
        XCTAssertEqual(editor.form.card.holder, "Deniz Y.")
        XCTAssertEqual(editor.form.card.code, DemoVault.typedCode)
        XCTAssertEqual(editor.original.patched(editor.edited),
                       newer.raw.setting(["card", "code"], to: .string(DemoVault.typedCode)))
    }
}
