import AppKit
import SwiftUI
import XCTest
@testable import OriPass

/// The form over the fake engine: what a save sends, what Esc asks, and
/// what becomes of the form when the item is changed under it or the vault
/// is locked over it.
@MainActor
final class EditorTests: XCTestCase {
    private var backend: FakeBackend!

    override func tearDown() {
        backend = nil
    }

    /// The demo vault, with a key at the top of GitHub's object and one
    /// inside its login that this app has never heard of.
    private func demo(_ change: (inout [JSONValue]) -> Void = { _ in }) async -> VaultStore {
        var vault = DemoVault.objects()
        vault.items = vault.items.map { item in
            guard item["name"]?.string == "GitHub" else { return item }
            return item.setting(["newerThanThisApp"], to: .object(["kept": .bool(true), "count": .int(3)]))
                .setting(["login", "uriChecksumOfSorts"], to: .string("as it came"))
        }
        change(&vault.items)
        backend = FakeBackend(items: vault.items, folders: vault.folders, password: DemoVault.password)
        // Synced a minute ago, so no sync is running behind the panes.
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        return store
    }

    /// Panes with the form open on the item called `title`.
    private func editing(_ title: String, in store: VaultStore) throws -> (panes: Panes, editor: Editor, item: Item) {
        let panes = Panes(store: store)
        let entry = try XCTUnwrap(panes.list.entries.first { $0.item.name == title }, "no \(title)")
        panes.select(item: entry.id)
        XCTAssertTrue(panes.canEdit)
        XCTAssertTrue(panes.beginEdit())
        return (panes, try XCTUnwrap(panes.editor), entry.item)
    }

    /// Saves, and gives back what the engine was asked meanwhile.
    private func save(_ panes: Panes) async -> [String] {
        let before = backend.calls.count
        await panes.saveEdit()?.value
        return Array(backend.calls[before...])
    }

    private func hosted(_ panes: Panes) -> NSWindow {
        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: PanesView(panes: panes))
        window.setContentSize(Metrics.windowSize)
        window.layoutIfNeeded()
        return window
    }

    /// The keys of `sent` whose values are not `original`'s.
    private func changed(_ sent: JSONValue?, from original: JSONValue) -> Set<String> {
        let now = sent?.object ?? [:]
        let was = original.object ?? [:]
        return Set(now.keys).union(was.keys).filter { now[$0] != was[$0] }
    }

    // MARK: What is typed is what is kept

    private func views<V: NSView>(_ type: V.Type, in view: NSView?) -> [V] {
        guard let view else { return [] }
        return (view as? V).map { [$0] } ?? [] + view.subviews.flatMap { views(type, in: $0) }
    }

    /// The system's smart quotes, smart dashes, corrections and text
    /// replacements are for prose. A recovery code, a command kept in a
    /// note and a password typed with its eye open are kept as the keys
    /// that were pressed.
    func testNothingTypedIntoTheFormIsRewrittenByTheSystem() async throws {
        let store = await demo()
        let (panes, editor, _) = try editing("Spotify", in: store)
        editor.toggleRevealed(ItemDetail.passwordRow)
        let window = hosted(panes)
        try await Task.sleep(nanoseconds: 100_000_000)
        window.layoutIfNeeded()
        let typed = #"sudo rm --force "a b" 'c' (c) teh"#

        func isPlain(_ text: NSTextView, _ what: String) {
            XCTAssertFalse(text.isAutomaticQuoteSubstitutionEnabled, "smart quotes, \(what)")
            XCTAssertFalse(text.isAutomaticDashSubstitutionEnabled, "smart dashes, \(what)")
            XCTAssertFalse(text.isAutomaticTextReplacementEnabled, "text replacement, \(what)")
            XCTAssertFalse(text.isAutomaticSpellingCorrectionEnabled, "autocorrection, \(what)")
            XCTAssertFalse(text.isAutomaticTextCompletionEnabled, "completion, \(what)")
            XCTAssertFalse(text.isContinuousSpellCheckingEnabled, "spelling, \(what)")
        }

        // The notes, which are a text view of their own.
        let notes = try XCTUnwrap(views(NSTextView.self, in: window.contentView).first { !$0.isFieldEditor },
                                  "no text view for the notes")
        XCTAssertTrue(window.makeFirstResponder(notes))
        isPlain(notes, "the notes")
        notes.selectAll(nil)
        notes.insertText(typed, replacementRange: notes.selectedRange())
        for character in #" "q" --x"# { notes.insertText(String(character), replacementRange: notes.selectedRange()) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(editor.form.notes, typed + #" "q" --x"#)

        // Every plain field is typed into through the window's one editor:
        // the username, and the password while its eye is open.
        let fields = views(NSTextField.self, in: window.contentView).filter { $0.isEditable && !($0 is NSSecureTextField) }
        XCTAssertGreaterThan(fields.count, 2)
        for field in fields {
            XCTAssertTrue(window.makeFirstResponder(field))
            let text = try XCTUnwrap(window.firstResponder as? NSTextView, "no editor for a field")
            isPlain(text, field.accessibilityLabel() ?? "a field")
        }
        let password = try XCTUnwrap(fields.first { $0.stringValue == editor.form.password }, "no revealed password")
        XCTAssertTrue(window.makeFirstResponder(password))
        let text = try XCTUnwrap(window.firstResponder as? NSTextView)
        text.selectAll(nil)
        for character in #"a"b'c--d"# { text.insertText(String(character), replacementRange: text.selectedRange()) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(editor.form.password, #"a"b'c--d"#)
    }

    // MARK: The details after a change

    /// A search's list, and a Password Health card's, are made behind each
    /// change and off the main thread, and the one before answers until
    /// then with the entries it was made from. The details are the item as
    /// the store has it, at once and afterwards.
    func testTheDetailsAreTheItemAsItNowIsAfterASaveDuringASearch() async throws {
        let store = await demo()
        await store.indexing?.value
        let panes = Panes(store: store)
        panes.query = "spotify"
        let found = try XCTUnwrap(panes.list.entries.first { $0.item.name == "Spotify" })
        panes.select(item: found.id)
        let old = try XCTUnwrap(panes.detail?.value(of: ItemDetail.passwordRow))
        XCTAssertTrue(panes.beginEdit())
        let editor = try XCTUnwrap(panes.editor)
        editor.form.password = "CANARY-yeni-parola"
        await panes.saveEdit()?.value
        XCTAssertNil(panes.editor)

        // As the window draws it in the turn the save comes back.
        XCTAssertEqual(panes.detail?.value(of: ItemDetail.passwordRow), "CANARY-yeni-parola")
        await store.indexing?.value
        XCTAssertEqual(panes.list.entries.first?.item.login?.password, "CANARY-yeni-parola", "the new index is in")
        XCTAssertEqual(panes.detail?.value(of: ItemDetail.passwordRow), "CANARY-yeni-parola",
                       "the details kept the item as it was, and a copy would give \(old)")

        // A second edit straight after is made from the item as it is.
        XCTAssertTrue(panes.beginEdit())
        XCTAssertEqual(panes.editor?.form.password, "CANARY-yeni-parola")
        panes.editor = nil

        // The same for a change a sync brings while the search stands.
        var vault = DemoVault.objects()
        vault.items = vault.items.map {
            $0["id"]?.string == found.id ? $0.setting(["login", "password"], to: .string("CANARY-telefondan")) : $0
        }
        backend.incoming = vault
        await store.sync()
        XCTAssertEqual(panes.detail?.value(of: ItemDetail.passwordRow), "CANARY-telefondan")
        await store.indexing?.value
        XCTAssertEqual(panes.detail?.value(of: ItemDetail.passwordRow), "CANARY-telefondan")
    }

    // MARK: What a save sends

    func testChangingOnlyTheTitleSendsTheObjectItReadWithAnotherName() async throws {
        let store = await demo()
        let (panes, editor, item) = try editing("Spotify", in: store)
        XCTAssertFalse(editor.isDirty)
        editor.form.title = "Spotify Aile"
        XCTAssertTrue(editor.isDirty)

        let asked = await save(panes)
        XCTAssertEqual(asked, ["save"])
        XCTAssertEqual(backend.lastSaved, item.raw.setting(["name"], to: .string("Spotify Aile")))
        XCTAssertNil(panes.editor)
        XCTAssertNil(panes.refused)
        XCTAssertEqual(store.entry(id: item.id)?.item.name, "Spotify Aile")
        XCTAssertEqual(panes.detail?.title, "Spotify Aile")
    }

    func testALoginWithAPasskeyAndAKeyThisAppDoesNotModelKeepsBoth() async throws {
        let store = await demo()
        let (panes, editor, item) = try editing("GitHub", in: store)
        let passkeys = try XCTUnwrap(item.raw["login"]?["fido2Credentials"])
        XCTAssertEqual(passkeys.array?.count, 1)
        XCTAssertEqual(passkeys.array?.first?["keyValue"]?.string, DemoVault.passkey)
        editor.form.title = "GitHub (iş)"

        let asked = await save(panes)
        XCTAssertEqual(asked, ["save"])
        let sent = try XCTUnwrap(backend.lastSaved)
        XCTAssertEqual(sent, item.raw.setting(["name"], to: .string("GitHub (iş)")))
        XCTAssertEqual(sent["login"]?["fido2Credentials"], passkeys)
        XCTAssertEqual(sent["newerThanThisApp"], .object(["kept": .bool(true), "count": .int(3)]))
        XCTAssertEqual(sent["login"]?["uriChecksumOfSorts"], .string("as it came"))

        // And after a sync, which reads the item back from the engine.
        await store.sync()
        let kept = try XCTUnwrap(store.entry(id: item.id)?.item)
        XCTAssertEqual(kept.name, "GitHub (iş)")
        XCTAssertEqual(kept.raw["login"]?["fido2Credentials"], passkeys)
        XCTAssertEqual(kept.raw["newerThanThisApp"]?["count"], .int(3))
    }

    func testAFormInWhichNothingWasChangedSendsNothing() async throws {
        let store = await demo()
        let (panes, editor, _) = try editing("İş Bankası", in: store)
        // Typed and taken back is not changed.
        editor.form.username += "x"
        editor.form.username.removeLast()
        let asked = await save(panes)
        XCTAssertEqual(asked, [])
        XCTAssertNil(panes.editor)
    }

    /// Ev Wi-Fi has no username, no address, no code and no notes, each of
    /// them `null` in its object. A form that was opened and had its title
    /// changed must not send any of them back as an empty string.
    func testWhatWasNullAndWasNotTypedIntoGoesBackNull() async throws {
        let store = await demo()
        let (panes, editor, item) = try editing("Ev Wi-Fi", in: store)
        XCTAssertEqual(item.raw["login"]?["username"], .null)
        XCTAssertEqual(item.raw["notes"], .null)
        editor.form.title = "Ev Wi-Fi 5G"
        editor.addAddress()
        editor.form.notes = "x"
        editor.form.notes = ""
        _ = await save(panes)
        XCTAssertEqual(backend.lastSaved, item.raw.setting(["name"], to: .string("Ev Wi-Fi 5G")))
    }

    func testEachPartOfTheFormChangesItsOwnKeyAndNoOther() async throws {
        let store = await demo()
        let folder = try XCTUnwrap(store.shelves.vaults.first { $0.name == "Dükkan" })
        guard case .folder(let shop) = folder.id else { return XCTFail("Dükkan is no folder") }

        let changes: [(key: String, change: (Editor) -> Void)] = [
            ("login", { $0.form.username = "deniz@yeni.invalid" }),
            ("login", { $0.form.totp = "" }),
            ("login", { $0.match($0.form.addresses[0].id, by: .exact) }),
            ("login", { $0.removeAddress($0.form.addresses[1].id) }),
            ("fields", { $0.form.fields[0].name = "Müşteri numarası" }),
            ("fields", { $0.moveField($0.form.fields[0].id, by: 1) }),
            ("fields", { $0.removeField($0.form.fields[3].id) }),
            ("fields", { $0.addField(.boolean) }),
            ("notes", { $0.form.notes = "yeni not" }),
            ("favorite", { $0.form.isFavourite = false }),
            ("folderId", { $0.form.folderID = shop }),
        ]
        for (key, change) in changes {
            let (panes, editor, item) = try editing("İş Bankası", in: store)
            change(editor)
            let asked = await save(panes)
            XCTAssertEqual(asked, ["save"], key)
            XCTAssertEqual(changed(backend.lastSaved, from: item.raw), [key], key)
        }
    }

    func testTheAddressesAndTheirRulesAreSentAsTheFormHasThem() async throws {
        let store = await demo()
        let (panes, editor, item) = try editing("İş Bankası", in: store)
        let was = try XCTUnwrap(item.raw["login"]?["uris"]?.array)
        XCTAssertEqual(was.count, 3)
        editor.match(editor.form.addresses[0].id, by: .startsWith)
        editor.removeAddress(editor.form.addresses[2].id)
        editor.addAddress()
        editor.form.addresses[2].uri = "  https://mobil.isbank.com.tr "
        // One added and left empty is not an address.
        editor.addAddress()
        _ = await save(panes)

        let sent = try XCTUnwrap(backend.lastSaved?["login"]?["uris"]?.array)
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(sent[0], .object(["uri": .string("https://www.isbank.com.tr/giris"), "match": .int(2)]))
        XCTAssertEqual(sent[1], was[1])
        XCTAssertEqual(sent[2], .object(["uri": .string("https://mobil.isbank.com.tr"), "match": .null]))
        // Everything else under `login` is what it was.
        let login = try XCTUnwrap(backend.lastSaved?["login"])
        XCTAssertEqual(changed(login, from: item.raw["login"] ?? .null), ["uris"])
    }

    func testCustomFieldsAreAddedRenamedReorderedAndRemoved() async throws {
        let store = await demo()
        let (panes, editor, item) = try editing("İş Bankası", in: store)
        let was = try XCTUnwrap(item.raw["fields"]?.array)
        XCTAssertEqual(was.count, 4)

        for kind in Field.Kind.allCases { editor.addField(kind) }
        XCTAssertEqual(editor.form.fields.count, 8)
        editor.form.fields[4].name = "Şube"
        editor.form.fields[4].value = "Kadıköy"
        editor.form.fields[5].name = "Telefon şifresi"
        editor.form.fields[5].value = DemoVault.hiddenField
        editor.form.fields[6].name = "Ortak hesap"
        editor.form.fields[6].isOn = true
        editor.form.fields[7].name = "Parola"
        editor.link(editor.form.fields[7].id, to: 101)
        // The PIN is renamed, the tick box goes, and the linked one that was
        // last of the four is first.
        editor.form.fields[1].name = "Kart PIN"
        editor.removeField(editor.form.fields[2].id)
        let linked = editor.form.fields[2].id
        editor.moveField(linked, by: -1)
        editor.moveField(linked, by: -1)
        // At the top it stays at the top.
        editor.moveField(linked, by: -1)
        XCTAssertEqual(editor.form.fields.first?.id, linked)

        _ = await save(panes)
        let sent = try XCTUnwrap(backend.lastSaved?["fields"]?.array)
        func field(_ name: String, _ value: JSONValue, _ type: Int64, _ linked: JSONValue = .null) -> JSONValue {
            .object(["name": .string(name), "value": value, "type": .int(type), "linkedId": linked])
        }
        XCTAssertEqual(sent, [
            was[3],
            was[0],
            field("Kart PIN", .string(DemoVault.hiddenField), 1),
            field("Şube", .string("Kadıköy"), 0),
            field("Telefon şifresi", .string(DemoVault.hiddenField), 1),
            field("Ortak hesap", .string("true"), 2),
            field("Parola", .null, 3, .int(101)),
        ])
        XCTAssertEqual(changed(backend.lastSaved, from: item.raw), ["fields"])
        // And the details read them back in that order.
        XCTAssertEqual(panes.detail?.fields.map(\.label),
                       ["Kullanıcı", "Müşteri no", "Kart PIN", "Şube", "Telefon şifresi", "Ortak hesap", "Parola"])
    }

    // MARK: The password that was

    /// Whichever side keeps the old password, it is first among the earlier
    /// ones afterwards, once, and no more than five are kept.
    func testChangingThePasswordLeavesTheOldOneFirstInItsHistory() async throws {
        let habits: [(FakeBackend.HistoryHabit, calls: [String])] = [
            (.asSent, ["save"]), (.itsOwn, ["save"]), (.onTop, ["save", "save"]),
        ]
        for (habit, expected) in habits {
            let store = await demo()
            backend.historyHabit = habit
            let (panes, editor, item) = try editing("İş Bankası", in: store)
            let old = try XCTUnwrap(item.login?.password)
            XCTAssertEqual(item.passwordHistory.map(\.password), DemoVault.old)
            editor.form.password = "yeni-parola-7Qx"
            XCTAssertNotNil(editor.strength)

            let asked = await save(panes)
            XCTAssertEqual(asked, expected, "\(habit)")
            let saved = try XCTUnwrap(store.entry(id: item.id)?.item)
            XCTAssertEqual(saved.login?.password, "yeni-parola-7Qx")
            XCTAssertEqual(saved.passwordHistory.map(\.password), [old] + DemoVault.old, "\(habit)")
            XCTAssertNotNil(saved.passwordHistory.first?.lastUsed)
            // The three it had are the entries they were, dates and all.
            XCTAssertEqual(Array(saved.passwordHistory.dropFirst()), item.passwordHistory)

            // What the engine holds says the same after a sync.
            await store.sync()
            XCTAssertEqual(store.entry(id: item.id)?.item.passwordHistory.map(\.password), [old] + DemoVault.old)
        }
    }

    func testNoMoreThanFiveEarlierPasswordsAreKept() async throws {
        let store = await demo()
        let (panes, _, item) = try editing("İş Bankası", in: store)
        panes.discardEdit()
        var last = try XCTUnwrap(item.login?.password)
        for round in 1...4 {
            XCTAssertTrue(panes.beginEdit())
            panes.editor?.form.password = "tur-\(round)-parola"
            _ = await save(panes)
            let history = try XCTUnwrap(store.entry(id: item.id)?.item.passwordHistory.map(\.password))
            XCTAssertEqual(history.first, last)
            XCTAssertLessThanOrEqual(history.count, Item.historyKept)
            last = "tur-\(round)-parola"
        }
        XCTAssertEqual(store.entry(id: item.id)?.item.passwordHistory.count, Item.historyKept)
    }

    func testAnEditThatLeavesThePasswordAloneLeavesItsHistoryAlone() async throws {
        let store = await demo()
        backend.historyHabit = .onTop
        let (panes, editor, item) = try editing("İş Bankası", in: store)
        editor.form.username = "baska@\(DemoVault.usernameDomain)"
        let asked = await save(panes)
        XCTAssertEqual(asked, ["save"])
        XCTAssertEqual(backend.lastSaved?["passwordHistory"], item.raw["passwordHistory"])
    }

    // MARK: Esc

    func testEscPutsAnUnchangedFormAwayAndAsksAboutAChangedOne() async throws {
        let store = await demo()
        let (panes, editor, item) = try editing("Spotify", in: store)
        XCTAssertTrue(panes.press(.escape))
        XCTAssertNil(panes.editor)
        XCTAssertFalse(panes.isAskingToDiscard)

        XCTAssertTrue(panes.beginEdit())
        let second = try XCTUnwrap(panes.editor)
        XCTAssertFalse(second === editor)
        second.form.title = "Spotify Aile"
        panes.press(.escape)
        XCTAssertTrue(panes.isAskingToDiscard)
        XCTAssertTrue(panes.editor === second)
        // Esc again is "Keep Editing", and what was typed is still there.
        panes.press(.escape)
        XCTAssertFalse(panes.isAskingToDiscard)
        XCTAssertEqual(panes.editor?.form.title, "Spotify Aile")

        panes.cancelEdit()
        XCTAssertTrue(panes.isAskingToDiscard)
        panes.discardEdit()
        XCTAssertNil(panes.editor)
        XCTAssertFalse(panes.isAskingToDiscard)
        XCTAssertEqual(store.entry(id: item.id)?.item, item)
        XCTAssertEqual(backend.count(of: "save"), 0)
    }

    func testAnotherItemIsNoWayOutOfAChangedForm() async throws {
        let store = await demo()
        let (panes, editor, item) = try editing("Spotify", in: store)
        // An unchanged form is simply left.
        panes.moveSelection(by: 1)
        XCTAssertNil(panes.editor)
        XCTAssertNotEqual(panes.selectedItem?.id, item.id)

        panes.select(item: item.id)
        XCTAssertTrue(panes.beginEdit())
        let form = try XCTUnwrap(panes.editor)
        XCTAssertFalse(form === editor)
        form.form.notes = "bir not"
        panes.moveSelection(by: 1)
        XCTAssertEqual(panes.selectedItem?.id, item.id)
        XCTAssertTrue(panes.isAskingToDiscard)
        panes.isAskingToDiscard = false
        panes.select(.favorites)
        XCTAssertEqual(panes.selection, .allItems)
        XCTAssertTrue(panes.isAskingToDiscard)
        panes.isAskingToDiscard = false
        XCTAssertFalse(panes.show(item: try XCTUnwrap(panes.list.entries.first?.id)))
        XCTAssertTrue(panes.editor === form)

        // A search hides the item from the list and not the form from him.
        panes.isAskingToDiscard = false
        panes.query = "github"
        await store.indexing?.value
        XCTAssertNil(panes.selectedItem)
        XCTAssertTrue(panes.editor === form)
        XCTAssertEqual(form.form.notes, "bir not")
        // Esc clears the search before it comes to the form.
        panes.press(.escape)
        XCTAssertTrue(panes.query.isEmpty)
        XCTAssertFalse(panes.isAskingToDiscard)
    }

    // MARK: Changed somewhere else

    /// The server's copy, renamed and with another username, arrives in a
    /// sync while the form is open with a new password typed into it.
    func testAnItemChangedUnderTheFormIsNotOverwritten() async throws {
        let store = await demo()
        let (panes, editor, item) = try editing("Spotify", in: store)
        editor.form.password = "benim-yeni-parolam-4Zt"
        editor.form.notes = "benim notum"

        var vault = DemoVault.objects()
        vault.items = vault.items.map {
            $0["id"]?.string == item.id
                ? $0.setting(["name"], to: .string("Spotify (telefondan)"))
                    .setting(["login", "username"], to: .string("telefon@\(DemoVault.usernameDomain)"))
                    .setting(["revisionDate"], to: .string(VaultDate.string(Date())))
                : $0
        }
        backend.incoming = vault
        await store.sync()
        let newer = try XCTUnwrap(store.entry(id: item.id)?.item)
        XCTAssertEqual(newer.name, "Spotify (telefondan)")

        // Nothing is sent: what would be sent was made from the old object.
        var asked = await save(panes)
        XCTAssertEqual(asked, [])
        XCTAssertTrue(panes.editor === editor)
        XCTAssertEqual(editor.notice, Editor.changedElsewhere)
        XCTAssertFalse(editor.isSaving)
        // The server's item is in the form, and what he typed is over it.
        XCTAssertEqual(editor.form.title, "Spotify (telefondan)")
        XCTAssertEqual(editor.form.username, "telefon@\(DemoVault.usernameDomain)")
        XCTAssertEqual(editor.form.password, "benim-yeni-parolam-4Zt")
        XCTAssertEqual(editor.form.notes, "benim notum")
        XCTAssertTrue(editor.isDirty)
        let window = hosted(panes)
        XCTAssertTrue(said(in: window.contentView).contains(Editor.changedElsewhere))

        // Saved again, his two changes go over the newer copy and nothing
        // else of it is touched.
        asked = await save(panes)
        XCTAssertEqual(asked, ["save"])
        XCTAssertEqual(changed(backend.lastSaved, from: newer.raw), ["login", "notes", "passwordHistory"])
        XCTAssertEqual(backend.lastSaved?["name"], .string("Spotify (telefondan)"))
        XCTAssertEqual(backend.lastSaved?["login"]?["username"], .string("telefon@\(DemoVault.usernameDomain)"))
        XCTAssertNil(panes.editor)
    }

    /// The same, when the engine has not synced and is told by the server
    /// that its copy is old, in the sentence 2026.9.1 said it in.
    func testASaveTheServerCallsOutOfDateBringsTheNewerCopyUnderTheForm() async throws {
        let store = await demo()
        let (panes, editor, item) = try editing("Spotify", in: store)
        editor.form.title = "Spotify Aile"
        var vault = DemoVault.objects()
        vault.items = vault.items.map {
            $0["id"]?.string == item.id ? $0.setting(["notes"], to: .string("telefondan yazıldı")) : $0
        }
        backend.incoming = vault

        let asked = await save(panes)
        XCTAssertEqual(asked.first, "save")
        XCTAssertTrue(asked.contains("sync"), "\(asked)")
        XCTAssertEqual(asked.filter { $0 == "save" }.count, 1)
        XCTAssertTrue(panes.editor === editor)
        XCTAssertEqual(editor.notice, Editor.changedElsewhere)
        XCTAssertEqual(editor.form.title, "Spotify Aile")
        XCTAssertEqual(editor.form.notes, "telefondan yazıldı")
        XCTAssertEqual(store.entry(id: item.id)?.item.name, "Spotify")
        XCTAssertNil(panes.refused)

        let again = await save(panes)
        XCTAssertEqual(again, ["save"])
        XCTAssertEqual(store.entry(id: item.id)?.item.name, "Spotify Aile")
        XCTAssertEqual(store.entry(id: item.id)?.item.notes, "telefondan yazıldı")
    }

    /// Told its copy is old, with a sync that then brings nothing: the form
    /// stays as typed, and what the foot of the window says is this app's
    /// sentence and never the server's answer as it came.
    func testAnOutOfDateSaveWithNoNewerCopyToFetchSaysSoInItsOwnWords() async throws {
        let store = await demo()
        let (panes, editor, item) = try editing("Spotify", in: store)
        let window = hosted(panes)
        editor.form.title = "Spotify Aile"
        backend.refusal = .refused(FakeBackend.outOfDate)

        _ = await save(panes)
        XCTAssertTrue(panes.editor === editor)
        XCTAssertFalse(editor.isSaving)
        XCTAssertNil(editor.notice)
        XCTAssertEqual(editor.form.title, "Spotify Aile")
        XCTAssertEqual(panes.refused, Editor.behind)
        XCTAssertEqual(store.entry(id: item.id)?.item.name, "Spotify")
        try await Task.sleep(nanoseconds: 50_000_000)
        let words = said(in: window.contentView)
        XCTAssertTrue(words.contains(Editor.behind), "\(words)")
        XCTAssertFalse(words.contains { $0.contains("EditCipherError") || $0.contains("validationErrors") })

        // A favourite sent from an old copy is answered the same way, and
        // a sync is asked for behind it.
        panes.discardEdit()
        let before = backend.count(of: "sync")
        panes.perform(.favourite)
        await panes.writing?.value
        XCTAssertEqual(panes.refused, Editor.behind)
        XCTAssertEqual(backend.count(of: "sync"), before + 1)
    }

    func testAnItemASyncTookAwayIsNotSavedAndTheFormStays() async throws {
        let store = await demo()
        let (panes, editor, item) = try editing("Spotify", in: store)
        editor.form.title = "Spotify Aile"
        var vault = DemoVault.objects()
        vault.items.removeAll { $0["id"]?.string == item.id }
        backend.incoming = vault
        await store.sync()
        XCTAssertNil(store.entry(id: item.id))

        let asked = await save(panes)
        XCTAssertEqual(asked, [])
        XCTAssertEqual(panes.refused, Editor.gone)
        XCTAssertTrue(panes.editor === editor)
        XCTAssertEqual(editor.form.title, "Spotify Aile")
    }

    func testARefusedSaveLeavesTheFormAsItWasTyped() async throws {
        let store = await demo()
        let (panes, editor, item) = try editing("Spotify", in: store)
        editor.form.title = "Spotify Aile"
        backend.isOffline = true
        _ = await save(panes)
        XCTAssertTrue(panes.editor === editor)
        XCTAssertEqual(editor.form.title, "Spotify Aile")
        XCTAssertFalse(editor.isSaving)
        XCTAssertNil(editor.notice)
        XCTAssertEqual(panes.refused, FakeBackend.offline)
        XCTAssertEqual(store.entry(id: item.id)?.item, item)

        backend.isOffline = false
        _ = await save(panes)
        XCTAssertNil(panes.editor)
        XCTAssertNil(panes.refused)
        XCTAssertEqual(store.entry(id: item.id)?.item.name, "Spotify Aile")
    }

    // MARK: The lock

    func testTheLockDropsTheFormAndWhatWasTypedIntoIt() async throws {
        let store = await demo()
        let door = Door(store: store)
        let panes = try XCTUnwrap(door.panes)
        panes.select(item: try XCTUnwrap(panes.list.entries.first { $0.item.name == "Spotify" }).id)
        XCTAssertTrue(panes.beginEdit())
        weak var form = panes.editor
        form?.form.password = "hiç-kaydedilmedi-9Kp"
        panes.cancelEdit()
        XCTAssertTrue(panes.isAskingToDiscard)

        await store.lock()
        XCTAssertNil(door.panes)
        XCTAssertNil(panes.editor)
        XCTAssertFalse(panes.isAskingToDiscard)
        XCTAssertNil(form, "the form outlived the lock")
        XCTAssertEqual(backend.count(of: "save"), 0)
    }

    func testASaveTheLockOvertakesChangesNothingWhenItComesBack() async throws {
        let store = await demo()
        let door = Door(store: store)
        let panes = try XCTUnwrap(door.panes)
        panes.select(item: try XCTUnwrap(panes.list.entries.first { $0.item.name == "Spotify" }).id)
        XCTAssertTrue(panes.beginEdit())
        panes.editor?.form.title = "Spotify Aile"
        backend.delay = 0.3
        let saving = try XCTUnwrap(panes.saveEdit())
        await store.lock()
        await saving.value
        XCTAssertNil(panes.editor)
        XCTAssertNil(panes.refused)
        XCTAssertEqual(store.state, .locked)
    }

    // MARK: What is drawn, and the keys

    /// The word over the field follows what is in the field, a letter at a
    /// time, and so does a linked field that points at it. What is saved
    /// is `login.username` and nothing beside it.
    func testTheUsernamesFieldIsCalledAnEmailWhileItHoldsOne() async throws {
        let store = await demo()
        let (panes, editor, item) = try editing("İş Bankası", in: store)
        let window = hosted(panes)
        func words() async throws -> [String] {
            window.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
            return said(in: window.contentView)
        }
        XCTAssertEqual(editor.form.usernameWord, "email", "the demo's are all addresses")
        var now = try await words()
        XCTAssertTrue(now.contains("email"), "\(now)")
        XCTAssertFalse(now.contains("username"), "the field and the linked field's button both say email")

        editor.form.username = "meric"
        XCTAssertEqual(editor.form.usernameWord, "username")
        XCTAssertEqual(editor.linkable.map(\.name), ["username", "password"])
        now = try await words()
        XCTAssertTrue(now.contains("username"), "\(now)")
        XCTAssertFalse(now.contains("email"), "\(now)")

        for (typed, word) in [("meric@", "username"), ("meric@kanarya", "username"), ("meric@kanarya.", "username"),
                              ("meric@kanarya.i", "email"), ("meric@kanarya.invalid", "email")] {
            editor.form.username = typed
            XCTAssertEqual(editor.form.usernameWord, word, typed)
        }
        XCTAssertEqual(editor.linkable.map(\.name), ["email", "password"])
        now = try await words()
        XCTAssertTrue(now.contains("email"), "\(now)")
        XCTAssertFalse(now.contains("username"), "\(now)")

        let asked = await save(panes)
        XCTAssertEqual(asked, ["save"])
        XCTAssertEqual(changed(backend.lastSaved, from: item.raw), ["login"])
        XCTAssertEqual(backend.lastSaved?["login"],
                       item.raw["login"]?.setting(["username"], to: .string("meric@kanarya.invalid")),
                       "one value, where it always was")
        XCTAssertEqual(backend.lastSaved?["fields"], item.raw["fields"], "and no custom field for it")
    }

    func testTheFormSaysItsFieldsAndNotWhatTheyHide() async throws {
        let store = await demo()
        let (panes, editor, item) = try editing("İş Bankası", in: store)
        let window = hosted(panes)
        var words = said(in: window.contentView)
        for word in ["Vault", "Cancel", "Save", "title", "email", "password", "one-time code", "website",
                     "Match", "notes", "Favourite", "Generate Password", "add a website", "add more",
                     "Müşteri no", "Kullanıcı"] {
            XCTAssertTrue(words.contains(word), "the form does not say \(word)")
        }
        XCTAssertTrue(words.contains("İş Bankası"))
        XCTAssertFalse(words.contains("Edit"))
        let password = try XCTUnwrap(item.login?.password)
        let hidden = [password, DemoVault.totpSecrets[0], DemoVault.hiddenField]
        for value in hidden {
            XCTAssertFalse(words.contains { $0.contains(value) }, "a hidden value is said while it is concealed")
        }

        // ⌘R shows them, as it does in the details, and again hides them.
        XCTAssertTrue(panes.canReveal)
        panes.toggleRevealed()
        XCTAssertTrue(editor.isAllRevealed)
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        words = said(in: window.contentView)
        XCTAssertTrue(words.contains(password), "⌘R did not show the password")
        panes.toggleRevealed()
        XCTAssertTrue(editor.revealed.isEmpty)
        // The details under the form had nothing revealed by it.
        XCTAssertTrue(panes.reading.revealed.isEmpty)
    }

    func testAnItemOfAKnownTypeThatIsNotDeletedHasAForm() async throws {
        let store = await demo()
        let panes = Panes(store: store)
        for (title, row, can) in [("Spotify", SidebarRow.allItems, true), ("Bonus Kart", .allItems, true),
                                  ("Ehliyet", .allItems, false), ("Kombi servis notu", .allItems, true),
                                  ("Deniz Yılmaz", .allItems, true), ("Sunucu anahtarı", .allItems, true),
                                  ("Arşiv: üniversite", .archive, true), ("Kapanan hesap", .trash, false)] {
            panes.select(row)
            panes.select(item: try XCTUnwrap(panes.list.entries.first { $0.item.name == title }, title).id)
            XCTAssertEqual(panes.canEdit, can, title)
            XCTAssertEqual(panes.beginEdit(), can, title)
            panes.discardEdit()
        }
    }

    func testCommandEAndCommandSAreTheItemMenus() async throws {
        let store = await demo()
        let door = Door(store: store)
        let commands = ItemCommands(door: door, isTyping: { false })
        let menu = commands.menu()
        let edit = try XCTUnwrap(KeyTable.item(.edit, in: menu))
        let save = try XCTUnwrap(KeyTable.item(.save, in: menu))
        XCTAssertEqual(edit.keyEquivalent, "e")
        XCTAssertEqual(save.keyEquivalent, "s")
        XCTAssertEqual(edit.keyEquivalentModifierMask, .command)
        XCTAssertEqual(save.keyEquivalentModifierMask, .command)
        // Nothing chosen: neither has anything to do.
        XCTAssertFalse(commands.validateMenuItem(edit))
        XCTAssertFalse(commands.validateMenuItem(save))

        let panes = try XCTUnwrap(door.panes)
        let entry = try XCTUnwrap(panes.list.entries.first { $0.item.name == "Spotify" })
        panes.select(item: entry.id)
        XCTAssertTrue(commands.validateMenuItem(edit))
        XCTAssertFalse(commands.validateMenuItem(save))
        XCTAssertTrue(commands.edit())
        XCTAssertFalse(commands.validateMenuItem(edit))
        XCTAssertTrue(commands.validateMenuItem(save))

        // An item has to have a name.
        panes.editor?.form.title = "  "
        XCTAssertFalse(commands.validateMenuItem(save))
        XCTAssertNil(commands.save())
        panes.editor?.form.title = "Spotify Aile"
        await commands.save()?.value
        XCTAssertNil(panes.editor)
        XCTAssertEqual(store.entry(id: entry.id)?.item.name, "Spotify Aile")
        XCTAssertEqual(backend.count(of: "save"), 1)
    }

    func testAWindowOfOneItemEditsItToo() async throws {
        let store = await demo()
        let panes = Panes(store: store)
        let entry = try XCTUnwrap(panes.list.entries.first { $0.item.name == "Spotify" })
        let pinned = panes.pinned(to: entry.id)
        XCTAssertTrue(pinned.beginEdit())
        let window = ItemWindows.frame()
        window.contentView = NSHostingView(rootView: ItemWindowView(panes: pinned))
        window.layoutIfNeeded()
        XCTAssertTrue(said(in: window.contentView).contains("Save"))
        pinned.editor?.form.title = "Spotify Aile"
        await pinned.saveEdit()?.value
        XCTAssertNil(pinned.editor)
        XCTAssertEqual(pinned.detail?.title, "Spotify Aile")
        // Ended as its window's closing ends it, the form goes.
        XCTAssertTrue(pinned.beginEdit())
        pinned.end()
        XCTAssertNil(pinned.editor)
    }
}
