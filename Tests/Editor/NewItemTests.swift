import AppKit
import SwiftUI
import XCTest
@testable import OriPass

/// ⌘N, the sheet of the five kinds, an empty form and what Save sends for
/// it, over the fake engine and once over the stand-in.
@MainActor
final class NewItemTests: XCTestCase {
    private var backend: FakeBackend!
    private var kept: [StandIn] = []

    override func tearDown() {
        backend = nil
        kept = []
    }

    private func demo() async -> VaultStore {
        let vault = DemoVault.objects()
        backend = FakeBackend(items: vault.items, folders: vault.folders, password: DemoVault.password)
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        return store
    }

    /// ⌘N and a tile, and the form that comes of it.
    private func form(of type: ItemType, in panes: Panes, line: UInt = #line) async throws -> Editor {
        XCTAssertTrue(panes.beginNew(), line: line)
        await panes.make(type)?.value
        XCTAssertNil(panes.choosing, line: line)
        return try XCTUnwrap(panes.editor, "no form for type \(type.rawValue)", line: line)
    }

    /// Every string anywhere in `value`.
    private func strings(in value: JSONValue) -> [String] {
        switch value {
        case .string(let string): return [string]
        case .array(let members): return members.flatMap(strings)
        case .object(let members): return members.values.flatMap(strings)
        case .null, .bool, .int, .double: return []
        }
    }

    // MARK: What is sent

    func testEachTypeCreatesWithTheTemplatesShape() async throws {
        let store = await demo()
        let panes = Panes(store: store)
        let template = try XCTUnwrap(FakeBackend.templates["item"]?.object)
        for type in NewItemChoice.kinds {
            let key = try XCTUnwrap(type.payloadKey)
            // 2026.9.1 has no template for a key, and the app's own three
            // keys stand in for it.
            let part = try XCTUnwrap((FakeBackend.templates[try XCTUnwrap(type.templateName)] ?? Item.keyPart).object)
            let editor = try await form(of: type, in: panes)
            XCTAssertTrue(editor.isNew)
            XCTAssertFalse(editor.isDirty, key)
            XCTAssertFalse(editor.canSave, "\(key) has no name yet")
            editor.form.title = "Yeni \(key)"
            var typed = ["Yeni \(key)"]
            if type == .sshKey {
                XCTAssertFalse(editor.canSave, "a key that is being made needs a key")
                XCTAssertTrue(editor.replaceKey(with: DemoVault.pastedKey))
                typed += [editor.form.key.privateKey, editor.form.key.publicKey, editor.form.key.fingerprint]
            }
            XCTAssertTrue(editor.canSave, key)
            let before = (creates: backend.count(of: "create"), items: store.shelves.all.count)
            await panes.saveEdit()?.value

            XCTAssertEqual(backend.count(of: "create"), before.creates + 1, key)
            XCTAssertEqual(backend.count(of: "save"), 0, key)
            let sent = try XCTUnwrap(backend.lastCreated?.object, key)
            XCTAssertEqual(Set(sent.keys), Set(template.keys).union(["folderId", key]), key)
            XCTAssertEqual(sent["type"], .int(Int64(type.rawValue)), key)
            XCTAssertEqual(sent["name"], .string("Yeni \(key)"))
            XCTAssertEqual(Set((sent[key]?.object ?? [:]).keys), Set(part.keys), key)
            for other in NewItemChoice.kinds.compactMap(\.payloadKey) where other != key {
                XCTAssertNil(sent[other], "\(other) in a new \(key)")
            }
            // The template's own examples went nowhere: what was typed is
            // every string there is.
            XCTAssertEqual(strings(in: .object(sent)).sorted(), typed.sorted(), key)
            XCTAssertEqual(sent["notes"], .null, key)
            XCTAssertEqual(sent["favorite"], .bool(false), key)
            XCTAssertEqual(sent["reprompt"], .int(0), key)

            XCTAssertNil(panes.editor, key)
            XCTAssertNil(panes.refused, key)
            XCTAssertEqual(store.shelves.all.count, before.items + 1, key)
            XCTAssertEqual(panes.selectedItem?.item.name, "Yeni \(key)")
            XCTAssertEqual(panes.selectedItem?.item.type, type)
        }
        XCTAssertEqual(backend.lastCreated?["sshKey"]?["privateKey"]?.string, DemoVault.pastedKey)
        XCTAssertEqual(FakeBackend.templates["item.securenote"], .object(["type": .int(0)]))
    }

    func testWhatIsTypedIntoALoginGoesUnderItsOwnKeysAndTheRestStaysNull() async throws {
        let store = await demo()
        let panes = Panes(store: store)
        let editor = try await form(of: .login, in: panes)
        editor.form.title = "Kanarya Kitabevi"
        editor.form.password = DemoVault.made
        editor.addAddress()
        editor.form.addresses[0].uri = "https://kitabevi.\(DemoVault.usernameDomain)"
        editor.addField(.hidden)
        editor.form.fields[0].name = "PIN"
        editor.form.fields[0].value = DemoVault.hiddenField
        editor.form.notes = "Bir not."
        editor.form.isFavourite = true
        await panes.saveEdit()?.value

        let login = try XCTUnwrap(backend.lastCreated?["login"])
        XCTAssertEqual(login["password"], .string(DemoVault.made))
        XCTAssertEqual(login["username"], .null, "a username that was never typed is none, not an empty one")
        XCTAssertEqual(login["totp"], .null)
        XCTAssertEqual(login["fido2Credentials"], .array([]))
        XCTAssertEqual(login["uris"], .array([.object([
            "uri": .string("https://kitabevi.\(DemoVault.usernameDomain)"), "match": .null,
        ])]))
        XCTAssertEqual(backend.lastCreated?["fields"], .array([.object([
            "name": .string("PIN"), "value": .string(DemoVault.hiddenField), "type": .int(1), "linkedId": .null,
        ])]))
        XCTAssertEqual(backend.lastCreated?["notes"], .string("Bir not."))
        XCTAssertEqual(backend.lastCreated?["favorite"], .bool(true))
        XCTAssertEqual(backend.lastCreated?["passwordHistory"], .array([]))
        XCTAssertNil(backend.lastCreated?["id"])
        XCTAssertEqual(panes.selectedItem?.item.login?.password, DemoVault.made)
    }

    func testALoginMadeWithAVaultSelectedCarriesThatFoldersID() async throws {
        let store = await demo()
        backend.collections = [.object(["id": .string("shared-1"), "name": .string("Ortak")])]
        await store.sync()
        let panes = Panes(store: store)
        let vault = try XCTUnwrap(panes.vaults.first { $0.name == DemoVault.folderNames[0] })
        guard case .folder(let folder) = vault.id else { return XCTFail("the first folder is no folder") }

        panes.select(.vault(vault.id))
        var editor = try await form(of: .login, in: panes)
        XCTAssertEqual(editor.form.folderID, folder)
        editor.form.title = "Dükkandaki"
        await panes.saveEdit()?.value
        XCTAssertEqual(backend.lastCreated?["folderId"], .string(folder))
        XCTAssertEqual(panes.selection, .vault(vault.id), "the list stayed on the vault it was made in")
        XCTAssertEqual(panes.selectedItem?.item.name, "Dükkandaki")
        XCTAssertEqual(panes.selectedItem?.item.folderID, folder)

        // Personal under every row that is no vault, and under a
        // collection, which takes nothing.
        for row in [SidebarRow.allItems, .favorites, .vault(.personal), .vault(.collection("shared-1")), .trash] {
            panes.select(row)
            XCTAssertEqual(panes.selection, row)
            editor = try await form(of: .login, in: panes)
            XCTAssertNil(editor.form.folderID, "\(row)")
            editor.form.title = "Kişisel"
            await panes.saveEdit()?.value
            XCTAssertEqual(backend.lastCreated?["folderId"], .null, "\(row)")
            XCTAssertEqual(panes.selectedItem?.item.name, "Kişisel", "\(row)")
        }

        // The vault's name is a menu in the form, and what it says is sent.
        panes.select(.allItems)
        editor = try await form(of: .secureNote, in: panes)
        editor.form.title = "Taşınan"
        editor.form.folderID = folder
        await panes.saveEdit()?.value
        XCTAssertEqual(backend.lastCreated?["folderId"], .string(folder))
    }

    func testTheNewItemIsSelectedWhateverTheListWasNarrowedTo() async throws {
        let store = await demo()
        let panes = Panes(store: store)
        panes.choose(.card)
        var editor = try await form(of: .login, in: panes)
        editor.form.title = "Kartların arasında"
        await panes.saveEdit()?.value
        XCTAssertEqual(panes.selectedItem?.item.name, "Kartların arasında")
        XCTAssertEqual(panes.category, .all)

        panes.query = "spotify"
        editor = try await form(of: .secureNote, in: panes)
        editor.form.title = "Aramanın dışında"
        await panes.saveEdit()?.value
        XCTAssertEqual(panes.selectedItem?.item.name, "Aramanın dışında")
        XCTAssertFalse(panes.isSearching)
    }

    func testAKeyIsMadeFromThisAppsThreeKeysWhenTheEngineHasNoTemplateForOne() async throws {
        let store = await demo()
        XCTAssertNil(backend.templates["item.sshkey"], "the real one has none")
        let blank = try await store.blank(.sshKey)
        XCTAssertEqual(blank.raw["sshKey"], Item.keyPart)
        XCTAssertEqual(blank.type, .sshKey)

        // Any other type's refusal is the engine's to say.
        backend.templates["item.card"] = nil
        let panes = Panes(store: store)
        XCTAssertTrue(panes.beginNew())
        await panes.make(.card)?.value
        XCTAssertNil(panes.editor)
        XCTAssertEqual(panes.refused, FakeBackend.noTemplate)
    }

    func testAKeysTemplateRefusedForAnyOtherReasonIsTheEnginesToSay() async throws {
        let store = await demo()
        let panes = Panes(store: store)
        for refusal in [VaultError.refused(FakeBackend.offline), .locked, .transport] {
            backend.refuse("item.sshkey", with: refusal)
            do {
                _ = try await store.blank(.sshKey)
                XCTFail("a key made of this app's own keys after \(refusal)")
            } catch {
                XCTAssertEqual(error as? VaultError, refusal)
            }
        }
        backend.refuse("item.sshkey", with: .refused(FakeBackend.offline))
        XCTAssertTrue(panes.beginNew())
        await panes.make(.sshKey)?.value
        XCTAssertNil(panes.editor, "no form over a refusal")
        XCTAssertEqual(panes.refused, FakeBackend.offline)

        XCTAssertEqual(FakeBackend.noTemplate, "Unknown template object.")
        XCTAssertTrue(VaultStore.isNoTemplate(FakeBackend.noTemplate))
        XCTAssertTrue(VaultStore.isNoTemplate("No template available for this object."))
        XCTAssertFalse(VaultStore.isNoTemplate(FakeBackend.offline))
    }

    func testARefusedCreateLeavesTheFormAsItWasTyped() async throws {
        let store = await demo()
        let panes = Panes(store: store)
        let editor = try await form(of: .login, in: panes)
        editor.form.title = "Kanarya Kitabevi"
        editor.form.password = DemoVault.made
        let count = store.shelves.all.count
        backend.isOffline = true
        await panes.saveEdit()?.value
        XCTAssertTrue(panes.editor === editor)
        XCTAssertFalse(editor.isSaving)
        XCTAssertEqual(editor.form.password, DemoVault.made)
        XCTAssertEqual(panes.refused, FakeBackend.offline)
        XCTAssertEqual(store.shelves.all.count, count)

        backend.isOffline = false
        await panes.saveEdit()?.value
        XCTAssertNil(panes.editor)
        XCTAssertNil(panes.refused)
        XCTAssertEqual(store.shelves.all.count, count + 1)
    }

    // MARK: Over a socket

    /// The fake's templates are the fixtures', so what is shown of one is
    /// shown of the other.
    func testTheFakesTemplatesAreTheRecordedOnes() throws {
        XCTAssertEqual(FakeBackend.templates.count, NewItemChoice.kinds.count)
        for (name, template) in FakeBackend.templates {
            XCTAssertEqual(try Fixture.json("template-\(name)")["data"]?["template"], template, name)
        }
    }

    func testTheEngineIsAskedForBothTemplatesAndSentTheirShape() async throws {
        let standIn = try StandIn(["password": "demo"])
        kept.append(standIn)
        let serve = ServeBackend(preferredPath: standIn.binary.path, runDirectory: standIn.run,
                                 dataDirectory: standIn.data)
        let store = VaultStore(backend: serve)
        await store.unlock(password: SecretBytes("demo"))
        XCTAssertEqual(store.state, .unlocked)

        let blank = try await store.blank(.card, in: .folder("a-folder"))
        // The sync an unlock starts is still asking for its lists.
        let asked = standIn.requests.filter { $0.contains("/template/") }
        XCTAssertEqual(asked, ["GET /object/template/item ", "GET /object/template/item.card "])

        var form = EditorForm(item: blank)
        form.title = "Yeni kart"
        form.card.code = DemoVault.typedCode
        try await store.create(form.applied(to: blank), from: blank)
        let line = try XCTUnwrap(standIn.requests.last { $0.hasPrefix("POST /object/item {") }, "nothing was created")
        let sent = try JSONValue(data: Data(line.dropFirst("POST /object/item ".count).utf8))
        let template = try XCTUnwrap(Fixture.json("template-item")["data"]?["template"]?.object)
        let part = try XCTUnwrap(Fixture.json("template-item.card")["data"]?["template"]?.object)
        XCTAssertEqual(Set((sent.object ?? [:]).keys), Set(template.keys).union(["folderId", "card"]))
        XCTAssertEqual(Set((sent["card"]?.object ?? [:]).keys), Set(part.keys))
        XCTAssertEqual(strings(in: sent).sorted(), ["Yeni kart", "a-folder", DemoVault.typedCode].sorted())
        XCTAssertEqual(sent["type"], .int(3))

        // A name the stand-in has no fixture for is refused, as a key's
        // may be, and a key is still made.
        do {
            _ = try await serve.template("item.nothing")
            XCTFail("a template nobody recorded")
        } catch {
            XCTAssertEqual(error as? VaultError, .refused(FakeBackend.noTemplate))
        }
        await store.lock()
    }

    // MARK: The sheet

    func testTheSheetNarrowsToWhatIsTypedAndReturnTakesTheLitTile() async throws {
        var choice = NewItemChoice()
        XCTAssertEqual(choice.kinds, [.login, .secureNote, .card, .identity, .sshKey])
        XCTAssertEqual(choice.lit, .login)
        choice.move(by: 1)
        choice.move(by: 1)
        XCTAssertEqual(choice.lit, .card)
        choice.move(by: 9)
        XCTAssertEqual(choice.lit, .sshKey)
        choice.move(by: -9)
        XCTAssertEqual(choice.lit, .login)

        choice.move(by: 3)
        choice.query = "KEY"
        XCTAssertEqual(choice.kinds, [.sshKey])
        XCTAssertEqual(choice.lit, .sshKey, "the first of what is left is lit")
        // A Turkish keyboard's capital I is this one.
        choice.query = "IDENT"
        XCTAssertEqual(choice.kinds, [.identity])
        choice.query = "ıdent"
        XCTAssertEqual(choice.kinds, [.identity])
        choice.query = "c"
        XCTAssertEqual(choice.kinds, [.secureNote, .card])
        choice.query = "passport"
        XCTAssertEqual(choice.kinds, [])
        XCTAssertNil(choice.lit)
        choice.move(by: 1)
        XCTAssertNil(choice.lit)
        choice.query = "  "
        XCTAssertEqual(choice.kinds.count, 5)
    }

    func testTheSheetSaysItsFiveKindsAndEscPutsItAway() async throws {
        let store = await demo()
        let panes = Panes(store: store)
        XCTAssertTrue(panes.beginNew())
        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: PanesView(panes: panes))
        window.setContentSize(Metrics.windowSize)
        window.layoutIfNeeded()
        let words = said(in: window.contentView)
        for kind in ["Login", "Secure Note", "Credit Card", "Identity", "SSH Key", "Kind of item"] {
            XCTAssertTrue(words.contains(kind), "the sheet does not say \(kind)")
        }

        // The arrows are the sheet's while it is up, and not the list's.
        let selected = panes.selectedItem?.id
        XCTAssertTrue(panes.press(.down))
        XCTAssertEqual(panes.selectedItem?.id, selected)
        XCTAssertNotNil(panes.choosing)
        XCTAssertTrue(panes.press(.escape))
        XCTAssertNil(panes.choosing)
        XCTAssertNil(panes.editor)
        XCTAssertEqual(backend.count(of: "template"), 0)

        XCTAssertTrue(panes.beginNew())
        XCTAssertTrue(panes.dismiss())
        XCTAssertNil(panes.choosing)
        XCTAssertNil(panes.make(.login), "a tile of a sheet that has gone")
    }

    func testAnEmptyFormSaysItsRowsAndIsLeftWithoutAQuestion() async throws {
        let store = await demo()
        let panes = Panes(store: store)
        let first = try XCTUnwrap(panes.list.entries.first)
        panes.select(item: first.id)
        let editor = try await form(of: .login, in: panes)
        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: PanesView(panes: panes))
        window.setContentSize(Metrics.windowSize)
        window.layoutIfNeeded()
        let words = said(in: window.contentView)
        for word in ["title", "username", "password", "one-time code", "Vault", "Personal", "Save", "Cancel"] {
            XCTAssertTrue(words.contains(word), "the empty form does not say \(word)")
        }
        XCTAssertFalse(words.contains("jdoe"), "the template's example is in the form")

        // Nothing typed: Esc has nothing to ask, and nothing was made.
        XCTAssertTrue(panes.dismiss())
        XCTAssertNil(panes.editor)
        XCTAssertFalse(panes.isAskingToDiscard)
        XCTAssertEqual(panes.selectedItem?.id, first.id, "the item that was in the details is in them again")
        XCTAssertEqual(backend.count(of: "create"), 0)
        XCTAssertFalse(editor.isDirty)
    }

    func testAChangedFormAsksBeforeItIsLeftForAnotherNewItem() async throws {
        let store = await demo()
        let panes = Panes(store: store)
        let editor = try await form(of: .login, in: panes)
        editor.form.password = DemoVault.made
        XCTAssertTrue(editor.isDirty)

        XCTAssertFalse(panes.beginNew())
        XCTAssertNil(panes.choosing)
        XCTAssertTrue(panes.isAskingToDiscard)
        XCTAssertTrue(panes.editor === editor)
        panes.isAskingToDiscard = false

        // Another item is no way out of it either.
        panes.moveSelection(by: 1)
        XCTAssertTrue(panes.editor === editor)
        XCTAssertTrue(panes.isAskingToDiscard)
        panes.discardEdit()
        XCTAssertNil(panes.editor)
        XCTAssertEqual(backend.count(of: "create"), 0)

        // There is no item to edit while a new one's form is open.
        _ = try await form(of: .card, in: panes)
        XCTAssertFalse(panes.canEdit)
        XCTAssertFalse(panes.beginEdit())
    }

    func testTheLockTakesTheSheetTheFormAndAnAnswerStillOnItsWay() async throws {
        let store = await demo()
        let door = Door(store: store)
        var panes = try XCTUnwrap(door.panes)
        let editor = try await form(of: .login, in: panes)
        editor.form.title = "Kanarya Kitabevi"
        editor.form.password = DemoVault.made
        await store.lock()
        XCTAssertNil(panes.editor)
        XCTAssertNil(door.panes)
        XCTAssertEqual(backend.count(of: "create"), 0)

        // The sheet, and a tile whose template had not come.
        await store.unlock(password: SecretBytes(DemoVault.password))
        panes = try XCTUnwrap(door.panes)
        XCTAssertTrue(panes.beginNew())
        backend.delay = 0.3
        let asking = try XCTUnwrap(panes.make(.identity))
        XCTAssertTrue(panes.beginNew())
        await store.lock()
        await asking.value
        XCTAssertNil(panes.choosing)
        XCTAssertNil(panes.editor)
        XCTAssertNil(panes.refused)

        // A create the lock overtakes puts nothing anywhere.
        backend.delay = 0
        await store.unlock(password: SecretBytes(DemoVault.password))
        panes = try XCTUnwrap(door.panes)
        let late = try await self.form(of: .secureNote, in: panes)
        late.form.title = "Geç kalan"
        backend.delay = 0.3
        let saving = try XCTUnwrap(panes.saveEdit())
        await store.lock()
        await saving.value
        XCTAssertNil(panes.editor)
        XCTAssertNil(panes.refused)
        XCTAssertEqual(store.state, .locked)
        XCTAssertTrue(store.shelves.all.isEmpty)
    }

    // MARK: The key and the button

    func testCommandNIsTheItemMenusAndAWindowOfOneItemHasNone() async throws {
        let store = await demo()
        let door = Door(store: store)
        let commands = ItemCommands(door: door, isTyping: { false })
        let new = try XCTUnwrap(KeyTable.item(.newItem, in: commands.menu()))
        XCTAssertEqual(new.keyEquivalent, "n")
        XCTAssertEqual(new.keyEquivalentModifierMask, .command)
        XCTAssertNil(KeyTable[.newItem].waits)
        XCTAssertTrue(commands.validateMenuItem(new))
        let panes = try XCTUnwrap(door.panes)
        XCTAssertTrue(commands.newItem())
        XCTAssertEqual(panes.choosing, NewItemChoice())

        let pinned = panes.pinned(to: try XCTUnwrap(panes.list.entries.first).id)
        XCTAssertFalse(pinned.canMakeNew)
        XCTAssertFalse(pinned.beginNew())

        await store.lock()
        XCTAssertFalse(commands.validateMenuItem(new))
        XCTAssertFalse(commands.newItem())
    }
}
