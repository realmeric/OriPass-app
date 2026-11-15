import AppKit
import SwiftUI
import XCTest
@testable import OriPass

@MainActor
final class LoginDetailTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    private let british = Locale(identifier: "en_GB")

    /// A login made of what is given and nothing else.
    private func login(_ name: String = "Site", username: String? = nil, password: String? = nil,
                       addresses: [String] = [], notes: String? = nil, fields: [JSONValue] = [],
                       _ more: [String: JSONValue] = [:]) -> JSONValue {
        let common: [String: JSONValue] = [
            "object": .string("item"), "id": .string("detail-\(name)"), "type": .int(1), "name": .string(name),
            "favorite": .bool(false), "reprompt": .int(0), "notes": JSONValue(notes), "fields": .array(fields),
            "creationDate": .string("2025-01-05T09:30:00.000Z"), "revisionDate": .string("2025-03-12T16:41:03.000Z"),
            "login": .object([
                "username": JSONValue(username), "password": JSONValue(password), "totp": .null,
                "uris": .array(addresses.map { .object(["uri": .string($0), "match": .null]) }),
            ]),
        ]
        return .object(common.merging(more) { $1 })
    }

    private func field(_ name: String?, _ value: String?, _ type: Int64, linked: Int64? = nil) -> JSONValue {
        .object(["name": JSONValue(name), "value": JSONValue(value), "type": .int(type),
                 "linkedId": linked.map { .int($0) } ?? .null])
    }

    private func detail(_ json: JSONValue) throws -> ItemDetail {
        ItemDetail(item: try Item(json: json), vault: .personal, calendar: utc, locale: british)
    }

    private func store(_ items: [JSONValue], folders: [JSONValue] = []) async -> VaultStore {
        let backend = FakeBackend(items: items, folders: folders, password: DemoVault.password)
        // Synced a minute ago, so no sync is running behind the panes.
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        return store
    }

    private func demo() async -> VaultStore {
        let vault = DemoVault.objects()
        return await store(vault.items, folders: vault.folders)
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

    // MARK: The rows

    func testALoginWithNoUsernameDrawsNoUsernameRow() async throws {
        let bare = try detail(login(password: "CANARY-x"))
        XCTAssertEqual(bare.main.map(\.label), ["password"])
        XCTAssertEqual(try detail(login(username: "", password: "CANARY-x")).main.map(\.label), ["password"])
        XCTAssertEqual(try detail(login(username: "deniz", password: "CANARY-x")).main.map(\.label),
                       ["username", "password"])
        XCTAssertTrue(try detail(login()).main.isEmpty, "nothing to outline")

        let panes = Panes(store: await demo())
        let window = hosted(panes)
        try choose("Ev Wi-Fi", in: panes)
        try await turn()
        var words = said(in: window.contentView)
        XCTAssertFalse(words.contains("username"), "\(words)")
        XCTAssertFalse(words.contains("website"), "it has no address either")
        XCTAssertTrue(words.contains("password"))
        XCTAssertTrue(words.contains("network name") && words.contains("Kanarya-5G"), "\(words)")

        try choose("Spotify", in: panes)
        try await turn()
        words = said(in: window.contentView)
        XCTAssertTrue(words.contains("email"), "the demo's usernames are all addresses: \(words)")
        XCTAssertEqual(words.filter { $0 == "website" }.count, 1)
    }

    /// The row is the same row, with the same id and the same value under
    /// another word, and a linked field that points at it says that word.
    func testAUsernameThatIsAnAddressIsCalledAnEmail() async throws {
        let pointer = field("Kullanıcı", nil, 3, linked: 100)
        let plain = try detail(login(username: "deniz", password: "CANARY-x", fields: [pointer]))
        let address = try detail(login(username: "deniz@kanarya.invalid", password: "CANARY-x", fields: [pointer]))
        XCTAssertEqual(plain.main.map(\.label), ["username", "password"])
        XCTAssertEqual(address.main.map(\.label), ["email", "password"])
        XCTAssertEqual(address.main.map(\.id), plain.main.map(\.id), "the same rows")
        XCTAssertEqual(address.primaryRow, "username")
        XCTAssertEqual(address.value(of: "username"), "deniz@kanarya.invalid")
        XCTAssertEqual(plain.fields.map(\.spoken), ["the same as username"])
        XCTAssertEqual(address.fields.map(\.spoken), ["the same as email"])
        XCTAssertEqual(try detail(login(username: "deniz@kanarya", password: "CANARY-x")).main.map(\.label),
                       ["username", "password"], "no dot after the @")

        let vault = DemoVault.objects()
        let store = await store(vault.items.map {
            $0["name"]?.string == "Spotify" ? $0.setting(["login", "username"], to: .string("deniz")) : $0
        }, folders: vault.folders)
        let panes = Panes(store: store)
        let window = hosted(panes)
        try choose("Spotify", in: panes)
        try await turn()
        var words = said(in: window.contentView)
        XCTAssertTrue(words.contains("username") && words.contains("deniz"), "\(words)")
        XCTAssertFalse(words.contains("email"), "\(words)")

        try choose("GitHub", in: panes)
        try await turn()
        words = said(in: window.contentView)
        XCTAssertTrue(words.contains("email") && words.contains("deniz@kanarya.invalid"), "\(words)")
        XCTAssertFalse(words.contains("username"), "\(words)")
    }

    func testALoginWithThreeAddressesDrawsThree() async throws {
        let panes = Panes(store: await demo())
        let window = hosted(panes)
        try choose("İş Bankası", in: panes)
        let websites = try XCTUnwrap(panes.detail).websites
        XCTAssertEqual(websites.map(\.host), ["www.isbank.com.tr", "internet.isbank.com.tr", "isbank.com.tr"])
        XCTAssertEqual(websites.map(\.scheme), ["https://", "https://", "https://"])
        XCTAssertEqual(websites.map(\.rest), ["/giris", "", "/kampanya"])
        XCTAssertEqual(websites.map(\.link?.absoluteString), [
            "https://www.isbank.com.tr/giris", "https://internet.isbank.com.tr", "https://isbank.com.tr/kampanya",
        ])

        try await turn()
        let words = said(in: window.contentView)
        XCTAssertEqual(words.filter { $0 == "website" }.count, 3, "\(words)")
        for address in ["https://www.isbank.com.tr/giris", "https://internet.isbank.com.tr",
                        "https://isbank.com.tr/kampanya"] {
            XCTAssertTrue(words.contains(address), "\(address) is not in \(words)")
        }
    }

    func testOnlyAnAddressABrowserOpensIsALink() {
        func website(_ address: String) -> ItemDetail.Website { ItemDetail.Website(id: 0, address: address) }

        let typed = website("example.com/login?next=1")
        XCTAssertEqual([typed.scheme, typed.host, typed.rest], ["", "example.com", "/login?next=1"])
        XCTAssertEqual(typed.link?.absoluteString, "https://example.com/login?next=1")

        let old = website(" http://forum.example.org:8080/login ")
        XCTAssertEqual([old.scheme, old.host, old.rest], ["http://", "forum.example.org:8080", "/login"])
        XCTAssertEqual(old.link?.scheme, "http")

        for address in ["androidapp://com.example.app", "javascript:alert(1)", "file:///etc/passwd", "Kanarya-5G",
                        "ssh://sunucu.example.com"] {
            let plain = website(address)
            XCTAssertNil(plain.link, address)
            XCTAssertEqual([plain.scheme, plain.host, plain.rest], ["", "", address], "drawn as it was written")
        }
    }

    func testCustomFieldsAreShownHiddenTickedOrPointing() throws {
        let read = try detail(login(username: "deniz", fields: [
            field("Müşteri no", "48213377", 0), field("PIN", "CANARY-pin", 1), field("Kurumsal", "true", 2),
            field("Bireysel", "false", 2), field("Kullanıcı", nil, 3, linked: 100), field("Parola", nil, 3, linked: 101),
            field("Boş", "", 0), field("Boş gizli", nil, 1), field(nil, "adsız", 0),
        ]))
        XCTAssertEqual(read.fields.map(\.label),
                       ["Müşteri no", "PIN", "Kurumsal", "Bireysel", "Kullanıcı", "Parola", "field"],
                       "in the item's order, and an empty one is not drawn")
        XCTAssertEqual(read.fields.map(\.spoken), [
            "48213377", "concealed", "yes", "no", "the same as username", "the same as password", "adsız",
        ])
        XCTAssertEqual(read.fields.map(\.isHidden), [false, true, false, false, false, false, false])
        XCTAssertEqual(ItemDetail.linked(9999), "another field")
    }

    func testAPasskeyIsARowThatSaysSoAndWhenItWasMade() async throws {
        let made = try detail(login(username: "deniz", password: "CANARY-x", [:]).setting(
            ["login", "fido2Credentials"],
            to: .array([.object(["keyValue": .string("CANARY-key"), "creationDate": .string("2026-02-09T10:00:00.000Z")]),
                        .object(["keyValue": .string("CANARY-key")])])
        ))
        XCTAssertEqual(made.main.map(\.label), ["username", "password", "passkey", "passkey"])
        XCTAssertEqual(made.main.map(\.spoken).suffix(2), ["Created Monday, 9 February 2026", "Saved in this item"])

        let panes = Panes(store: await demo())
        try choose("GitHub", in: panes)
        XCTAssertEqual(try XCTUnwrap(panes.detail).main.map(\.label),
                       ["email", "password", "passkey", "one-time code"])
        try choose("Spotify", in: panes)
        XCTAssertEqual(try XCTUnwrap(panes.detail).main.map(\.label), ["email", "password"])
    }

    // MARK: Notes

    func testANoteWithAMarkdownLinkDrawsALink() async throws {
        let note = NoteText(markdown: "Limit için [yardım sayfası](https://example.com/yardim) var.")
        XCTAssertEqual(note.links.map(\.absoluteString), ["https://example.com/yardim"])
        XCTAssertEqual(note.plain, "Limit için yardım sayfası var.", "the address is behind the words")

        // What a click on one may not open is drawn as words.
        let unsafe = NoteText(markdown: "[bir](javascript:alert(1)) [iki](file:///etc/passwd) [üç](ssh://example.com)")
        XCTAssertTrue(unsafe.links.isEmpty, "\(unsafe.links)")
        XCTAssertEqual(unsafe.plain, "bir iki üç")

        let panes = Panes(store: await demo())
        let window = hosted(panes)
        try choose("İş Bankası", in: panes)
        XCTAssertEqual(try XCTUnwrap(panes.detail?.note).links.map(\.absoluteString), ["https://example.com/yardim"])
        try await turn()
        let words = said(in: window.contentView)
        XCTAssertTrue(words.contains { $0.contains("yardım sayfası") }, "\(words)")
        XCTAssertFalse(words.contains { $0.contains("](https://") }, "the Markdown is read and not shown")
    }

    func testANoteWithAScriptDrawsItsText() async throws {
        let script = "<script>alert('x')</script>"
        let note = NoteText(markdown: "Önce\n\n\(script)\n\nsonra <script>alert(2)</script> ve <b>kalın</b>.")
        XCTAssertTrue(note.plain.contains(script), note.plain)
        XCTAssertTrue(note.plain.contains("sonra <script>alert(2)</script> ve <b>kalın</b>."), note.plain)
        XCTAssertTrue(note.links.isEmpty)

        let panes = Panes(store: await store([login("Betik", username: "deniz", notes: "Not: \(script)")]))
        let window = hosted(panes)
        try choose("Betik", in: panes)
        try await turn()
        let words = said(in: window.contentView)
        XCTAssertTrue(words.contains { $0.contains(script) }, "\(words)")
    }

    func testANoteIsTakenApartIntoHeadingsListsAndAQuotation() {
        let note = NoteText(markdown: """
        # Başlık

        Bir **kalın** satır
        ve ikincisi.

        - bir
        - iki
            - iç

        1. ilk

        > alıntı

        ```
        kod
        ```
        """)
        XCTAssertEqual(note.blocks.map(\.kind), [
            .heading(1), .paragraph, .bullet(depth: 1), .bullet(depth: 1), .bullet(depth: 2),
            .numbered(1, depth: 1), .quote, .code,
        ])
        XCTAssertEqual(String(note.blocks[1].text.characters), "Bir kalın satır\nve ikincisi.",
                       "a line that ends in the note ends on the screen")
        XCTAssertTrue(note.blocks[1].text.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
        XCTAssertEqual(String(note.blocks[7].text.characters), "kod")

        XCTAssertTrue(NoteText(markdown: " \n\n ").isEmpty)
        XCTAssertNil(try detail(login(notes: "  \n")).note, "an empty note draws no outline")
    }

    // MARK: The dates and the vault

    func testLastEditedIsWrittenOutAndOpensOntoTheDateItWasCreated() async throws {
        let read = try detail(login())
        XCTAssertEqual(ItemDetail.written(try XCTUnwrap(read.edited), calendar: utc, locale: british),
                       "Wednesday, 12 March 2025 at 16:41:03")
        XCTAssertEqual(ItemDetail.written(try XCTUnwrap(read.created), calendar: utc, locale: british),
                       "Sunday, 5 January 2025 at 9:30:00")

        let panes = Panes(store: await store([login("Bir", username: "a"), login("İki", username: "b")]))
        let window = hosted(panes)
        try choose("Bir", in: panes)
        try await turn()
        var words = said(in: window.contentView)
        XCTAssertTrue(words.contains { $0.hasPrefix("Last edited ") && $0.contains("2025") }, "\(words)")
        XCTAssertFalse(words.contains { $0.hasPrefix("Created ") }, "shut until it is opened")

        panes.toggleCreated()
        try await turn()
        words = said(in: window.contentView)
        XCTAssertTrue(words.contains { $0.hasPrefix("Created ") && $0.contains("2025") }, "\(words)")

        try choose("İki", in: panes)
        XCTAssertFalse(panes.showsCreated, "another item starts shut")
    }

    func testTheTopRowNamesTheVaultTheItemIsIn() async throws {
        let panes = Panes(store: await demo())
        let window = hosted(panes)
        try choose("İş Bankası", in: panes)
        XCTAssertEqual(panes.detail?.vault.name, "İş")
        try choose("Spotify", in: panes)
        XCTAssertEqual(panes.detail?.vault.name, "Personal")
        try await turn()
        let words = said(in: window.contentView)
        for word in ["Vault", "Edit", "More", "Spotify"] {
            XCTAssertTrue(words.contains(word), "\(word) is not in \(words)")
        }
        XCTAssertFalse(words.contains("No item selected"))

        panes.select(item: nil)
        XCTAssertNil(panes.detail)
        try await turn()
        XCTAssertTrue(said(in: window.contentView).contains("No item selected"))
    }

    // MARK: What is hidden

    func testNothingHiddenIsInTheAccessibilityTreeWhileConcealed() async throws {
        let panes = Panes(store: await demo())
        let window = hosted(panes)
        // A username and a note are shown where they are, so the two
        // canaries that stand for those are not in this list.
        let hidden = DemoVault.canaries.filter { $0 != DemoVault.usernameDomain && $0 != DemoVault.note }
        var read = 0
        var concealed = 0
        for row in [SidebarRow.allItems, .archive, .trash] {
            panes.select(row)
            for entry in panes.list.entries where entry.item.type == .login {
                panes.select(item: entry.id)
                panes.toggleCreated()
                try await turn(0.02)
                let words = said(in: window.contentView)
                XCTAssertTrue(words.contains(entry.item.name), "\(entry.id) is not drawn")
                for secret in hidden {
                    XCTAssertFalse(words.contains { $0.contains(secret) }, "\(entry.id) says a hidden value")
                }
                if entry.item.login?.password?.isEmpty == false {
                    XCTAssertTrue(words.contains("password"), "\(entry.id) has no password row")
                    XCTAssertTrue(words.contains(ItemDetail.concealed), "\(entry.id) does not say it is concealed: \(words.suffix(30))")
                    concealed += 1
                }
                read += 1
            }
        }
        XCTAssertEqual(read, 30, "every login in the demo, the archived and the deleted one too")
        XCTAssertEqual(concealed, 30)
        XCTAssertEqual(ItemDetail.concealed, "concealed")

        // The hidden custom field as well, by its own name.
        panes.select(.allItems)
        try choose("İş Bankası", in: panes)
        try await turn()
        let words = said(in: window.contentView)
        XCTAssertTrue(words.contains("PIN"), "\(words)")
        XCTAssertEqual(words.filter { $0 == ItemDetail.concealed }.count, 2, "the password and the PIN")
        XCTAssertFalse(words.contains { $0.contains("•") && $0.count == ItemDetail.dots.count },
                       "the dots are for the eye")
    }

    func testAModelOfTheDetailsSaysNothingOfWhatItHolds() throws {
        let read = try detail(login(username: "deniz", password: "CANARY-printed", notes: "CANARY-printed",
                                    fields: [field("PIN", "CANARY-printed", 1)]))
        var out = ""
        dump(read, to: &out)
        dump(read.main, to: &out)
        dump(read.fields, to: &out)
        dump(read.note, to: &out)
        out += "\(read) \(read.main) \(read.fields) \(String(describing: read.note))"
        XCTAssertFalse(out.contains("CANARY"), out)
    }

    func testNoValueCanBeSelectedAsText() throws {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Detail")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThanOrEqual(files.count, 3)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains(".textSelection("), "\(file.lastPathComponent) lets a value be selected")
            XCTAssertFalse(text.contains("NSTextView") || text.contains("NSTextField"), file.lastPathComponent)
        }
    }

    // MARK: Links

    func testAClickedLinkGoesToTheBrowserOnlyWhenABrowserOpensIt() async throws {
        var opened: [URL] = []
        let panes = Panes(store: await demo(), open: { opened.append($0) })
        XCTAssertTrue(panes.follow(try XCTUnwrap(URL(string: "https://example.com/yardim"))))
        XCTAssertFalse(panes.follow(try XCTUnwrap(URL(string: "javascript:alert(1)"))))
        XCTAssertFalse(panes.follow(try XCTUnwrap(URL(string: "file:///etc/passwd"))))
        XCTAssertFalse(panes.follow(try XCTUnwrap(URL(string: "x-apple.systempreferences:com.apple.preference"))))
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com/yardim"])
    }

    func testTheDetailsAreWorkedOutOncePerChoiceAndGoWithTheItem() async throws {
        let backend = FakeBackend(items: [login("Bir", username: "a")], folders: [], password: DemoVault.password)
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        let panes = Panes(store: store)
        XCTAssertNil(panes.detail, "nothing is chosen when the window opens")
        try choose("Bir", in: panes)
        XCTAssertEqual(panes.detail?.title, "Bir")

        await store.lock()
        XCTAssertNil(panes.detail, "a locked store has no item to read")
    }
}
