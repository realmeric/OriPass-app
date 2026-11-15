import CryptoKit
import AppKit
import Carbon.HIToolbox
import Foundation

/// A vault of invented items, for looking at a surface without anybody's real
/// one. `OP_DEMO=1` puts the demo vault behind the lock screen, and every card
/// that needs more than that adds its own choice here.
enum Demo {
    /// Read once: a run is a demo or it is not, for its whole life.
    private static let setting = ProcessInfo.processInfo.environment["OP_DEMO"]

    static var isOn: Bool { setting != nil }

    /// What `OP_DEMO` asked for, for the runs that do more than unlock.
    static var choice: String { setting ?? "" }

    /// To standard output, at once: a script is reading it line by line, and
    /// `print` into a pipe would sit in a buffer until the app quit.
    /// The demo's own defaults, so an answer given to the demo is not an
    /// answer given to the app.
    static let defaults = UserDefaults(suiteName: "\(AppInfo.bundleID).demo") ?? .standard

    static func say(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

/// What `make canary` watches (`scripts/canary.sh`): `OP_DEMO=tour` unlocks
/// the demo vault, does to it what a person would, and locks. The script then
/// searches the Mac for every string in `DemoVault.canaries`, with the app
/// still running and locked (D6).
///
/// A card that adds a surface holding a secret adds that surface here in the
/// same commit, or the search is looking at less than the app does.
@MainActor
enum DemoTour {
    /// Where the tour's seal is written: in the temporary directory, which
    /// the search reads, and never where the real seal is.
    static let sealDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("oripass-tour-seal")

    private static let suiteName = "\(AppInfo.bundleID).tour"

    /// The tour's own defaults, which are emptied each time it starts and
    /// are where it writes the switches it turns.
    static let defaults = UserDefaults(suiteName: suiteName) ?? .standard

    /// Before the settings are read, so the tour starts from the defaults
    /// whatever the last one left.
    static func forgetChoices() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// A door whose finger is a fake enclave, since nobody is at the sensor.
    /// It is never in front, so no sheet raises itself and the tour says when
    /// the finger comes down. A window of one item is put on the screen
    /// and not given the keys, which stay with the main window's item.
    static func door(over store: VaultStore, preferences: Preferences) -> Door {
        try? FileManager.default.removeItem(at: sealDirectory)
        try? FileManager.default.removeItem(at: recents)
        // The real check over the tour's enclave, so an item that asks is
        // answered for by the finger no session has. There is no panel for
        // a password: with the seal gone the answer would be no.
        let seal = PasswordSeal(directory: sealDirectory, enclave: enclave)
        return Door(store: store, seal: seal,
                    defaults: defaults, preferences: preferences,
                    clipboard: Clipboard(pasteboard: .general), stage: panel,
                    present: { $0.orderFront(nil) },
                    desk: AttachmentDesk(copies: OpenCopies(directory: attachments), stage: preview),
                    reprompt: Reprompt(store: store, authoriser: OwnerCheck(store: store, seal: seal, stage: nil)),
                    armedFill: ArmedFill(sites: sites),
                    isInFront: { false })
    }

    /// How the tour's Quick Access is put on the screen: in front and
    /// without the keys, as the door's windows are. A panel that has the
    /// keys is put away when they go elsewhere, which is right for a hand
    /// and failed one tour in six, on the runs where another app was in
    /// front and took them back (`docs/notes.md`, "A panel that takes the
    /// keys").
    static let present: (QuickPanel) -> Void = { $0.orderFront(nil) }

    /// Kept so the tour can count the sheets it would have raised.
    private static let enclave = FakeEnclave()

    /// Where the tour's copy of an attachment is written: in the temporary
    /// directory, which the search reads. Not emptied here: the app empties
    /// it at launch, and the tour says whether it did.
    static let attachments = FileManager.default.temporaryDirectory
        .appendingPathComponent("oripass-tour-attachments")

    /// Quick Look as the app puts it up, behind whatever is on the screen.
    private static let preview: QuickLookPanel = {
        let panel = QuickLookPanel()
        panel.takesKeys = false
        return panel
    }()

    /// Large Type as the app puts it up, kept here so the tour can say
    /// whether it is still standing after the lock.
    private static let panel = LargeTypePanel()

    /// The four hot keys as the tour takes them: from the real Carbon, the
    /// way the app does, on ⌃⌥⇧⌘ with F16 to F19, which no keyboard on
    /// this desk has. The app's own would be taken from every other app for
    /// as long as the canary runs, and ⇧⌘L pressed in one of them would lock
    /// the tour's vault in the middle of it.
    static let keys: [HotKeyAction: HotKey] = {
        let every = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        return [.quickAccess: HotKey(key: UInt32(kVK_F17), carbon: every),
                .lock: HotKey(key: UInt32(kVK_F18), carbon: every),
                .showApp: HotKey(key: UInt32(kVK_F19), carbon: every),
                .fill: HotKey(key: UInt32(kVK_F16), carbon: every)]
    }()

    /// What the tour types with: a sink that posts no key and keeps what
    /// it was sent, a screen and a grant that are as the tour says, and no
    /// waiting between keys.
    static let sink = FakeSink()
    static let ground = FakeForeground()
    static let access = FakeAccessibility(isTrusted: false)
    /// Open & Fill's browser, which opens nothing and keeps the address.
    static let sites = FakeSites()
    static let typist = Typist(access: access, ground: ground, sink: sink, pause: { _ in await Task.yield() })

    /// The ids of the items the tour used through Quick Access, in the
    /// temporary directory with the seal, for the search to read.
    static let recents = FileManager.default.temporaryDirectory
        .appendingPathComponent("oripass-tour-recents.json")

    /// What the tour's Quick Access is told is in front, and the page its
    /// browser is on. No app is looked at and no browser is asked.
    static var front: FrontApp?
    static var page: String?

    struct Tab: TabAsker {
        func address(of app: FrontApp) async -> String? { await DemoTour.page }
    }

    /// What `Instruments` holds, by name, for the script to hold the app to.
    private static var watching: String {
        let live = Instruments.live.map { "\($0.owner)/\($0.name)" }
        return live.isEmpty ? "nothing" : live.joined(separator: " ")
    }

    /// The file at the real path, which a build without the group would not
    /// have been able to make.
    private static var doorIsThere: Bool {
        AppPaths.bridge.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// What the app made of the mark and of the Dock, for the tour to use as
    /// a hand would.
    struct Bar {
        let menu: MarkMenu
        let mark: StatusItem
        let presence: Presence
        let window: NSWindow
        let settings: SettingsCommands
    }

    static func run(door: Door, quick: QuickAccess, hotKeys: HotKeys, bar: Bar, agent: SSHAgent, browser: BrowserDoor?) async {
        let store = door.store
        let left = door.desk?.copies.held.count ?? -1
        Demo.say("tour: attachments: \(left == 0 ? "nothing left of the last run" : "\(left) files left of the last run")")
        Demo.say("tour: hot keys \(hotKeys.bound.count) taken and \(hotKeys.refused.count) refused")

        // A wrong password first, and then the right one, both through the
        // door as Return reaches it.
        await door.unlock(with: SecretBytes("not-the-password")).value
        Demo.say("tour: \(store.refusal == nil ? "not refused" : "refused")")
        await door.unlock(with: SecretBytes(DemoVault.tourPassword)).value
        Demo.say("tour: unlocked \(store.shelves.all.count) items")
        Demo.say("tour: watching while open: \(watching)")
        Demo.say("tour: the door is \(doorIsThere ? "open" : "not there") with the vault open")

        // Yes to the question, a lock by the menu's item, and back in with a
        // finger. The seal stays on disk for the search, which looks in
        // its two files for the password it holds.
        door.answerFingerOffer(true)
        Demo.say("tour: \(door.hasSeal ? "sealed" : "not sealed")")
        // Quick Access up by its key, as Carbon would say it had been
        // pressed, with a word in it, for the lock to take down.
        let pressed = HotKeys.press(.quickAccess) == noErr && quick.isUp
        Demo.say("tour: the hot key \(pressed ? "raised quick access" : "raised nothing")")
        quick.query = "banka"
        let wasUp = quick.isUp && quick.panel.isVisible
        Demo.say("tour: menu \(await lockFromMenu(store) ? "locked" : "did not lock")")
        let isGone = !quick.isUp && !quick.panel.isVisible && quick.query.isEmpty
        Demo.say("tour: quick access \(!wasUp ? "never came up" : isGone ? "closed by the lock" : "still up")")
        Demo.say("tour: \(await quickAccess(quick, door))")
        Demo.say("tour: \(await inFront(quick, door))")
        Demo.say("tour: finger opened \(store.shelves.all.count) items")
        // Before anything else touches the one item that asks: once it has
        // been answered for, the rest of the tour finds it like any other.
        Demo.say("tour: \(await guarded(door))")
        Demo.say("tour: \(await fill(quick, door))")
        Demo.say("tour: \(await openAndFill(quick, door))")
        Demo.say("tour: sidebar \(foldFromMenu(door) ? "folded" : "did not fold")")
        Demo.say("tour: sidebar listed \(walkSidebar(door)) items")
        Demo.say("tour: list drew \(walkList(door)) rows")

        let read = await walkDetails(door)
        Demo.say("tour: details read \(read.logins) logins and \(read.others) others")
        // Every password has been read once more, for its level, and the
        // search that follows looks for what that left behind.
        await store.scoring?.value
        Demo.say("tour: scored \(store.scorings) passwords")
        Demo.say("tour: \(await passwordHealth(door))")
        Demo.say("tour: \(await breaches(door))")
        Demo.say("tour: \(await twoFactor(door))")
        // After those two, which count one unlock's requests: this holds an
        // unlock open for as long as a count takes.
        Demo.say("tour: \(await askAsAHost(door, browser))")
        Demo.say("tour: \(await signInWithAPasskey(browser))")
        Demo.say("tour: \(await askForACode(browser, door.store))")
        Demo.say("tour: \(await askWithNothingNamed(browser, door.store))")
        Demo.say("tour: \(await makeAPasskey(browser))")
        Demo.say("tour: \(await saveWhatAPageTook(door))")
        Demo.say("tour: \(await offerToAField(door))")
        Demo.say("tour: \(await signInForAPage(door))")
        Demo.say("tour: \(await signIn())")
        Demo.say("tour: \(await openEngine())")
        Demo.say("tour: \(keys(door))")
        Demo.say("tour: \(await settings(bar.settings))")
        Demo.say("tour: \(reveal(door))")
        Demo.say("tour: \(await copyAndWait(door))")
        Demo.say("tour: \(copyCode(door))")
        Demo.say("tour: \(await menuBar(bar, door, quick))")
        // Before Large Type goes up, which choosing an item would take down.
        Demo.say("tour: \(await change(door))")
        Demo.say("tour: \(await edit(door))")
        Demo.say("tour: \(await editOthers(door))")
        Demo.say("tour: \(await makeNew(door))")
        Demo.say("tour: \(await generate(door))")
        Demo.say("tour: \(await history(door))")
        Demo.say("tour: \(await attachment(door))")
        Demo.say("tour: \(copyAndShowLarge(door))")
        // A form with a password typed into it and never saved, left open
        // for the lock. The search after it reads the list under the form.
        let leaving = leaveEditing(door)
        Demo.say("tour: \(leaving)")
        Demo.say("tour: \(await search(door))")
        // The wand on that form, and a password made and not used, which is
        // on the card when the lock comes.
        door.panes?.toggleFieldGenerator()
        await door.panes?.generator?.asking?.value
        weak var card = door.panes?.generator
        let hadCard = card?.password.isEmpty == false
        // And the earlier passwords of the item behind the form, one of them
        // spelled out, which is on the sheet when the lock comes. The panes'
        // reading may outlive the lock a while in the window's hands, empty;
        // what is looked at is the sheet it held.
        door.panes?.showHistory()
        door.panes?.toggleRevealed(historyEntry: 0)
        weak var reading = door.panes?.reading
        let hadHistory = reading?.history?.revealed.isEmpty == false
        // And an attachment's copy on disk under a preview, from a window
        // of the item's own, since the main one is held by the form.
        let hadCopy = await leaveAttachment(door)
        let windows = door.panes?.windows?.windows ?? []
        weak var index = store.searchIndex
        weak var form = door.panes?.editor
        let hadForm = form?.isDirty == true
        leakOnPurpose()

        // What the store's lock does to its own engine, done to the one the
        // tour opened beside it: the script looks for its child afterwards.
        await engine?.close()
        engine = nil
        Demo.say("tour: engine: shut")
        await store.lock()
        Demo.say("tour: search index \(index == nil ? "dropped by the lock" : "outlived the lock")")
        Demo.say("tour: password health: \(store.watch == nil ? "nothing counted after the lock" : "the counts outlived the lock")")
        let answers = await store.breaches?.held ?? -1
        Demo.say("tour: breaches: \(answers == 0 ? "no answer held after the lock" : "\(answers) answers held after the lock")")
        let listed = await store.twoFactor?.held
        Demo.say("tour: two-factor: \(listed == nil ? "no list held after the lock" : "the list outlived the lock")")
        // The panes let go of it at the lock, and the window's view of it
        // goes when the window is next drawn, as the lock screen.
        var turns = 0
        while form != nil || card != nil, turns < 200 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            turns += 1
        }
        Demo.say("tour: the form's window let go of it after \(turns) turns")
        Demo.say("tour: the form \(!hadForm ? "was not open" : form == nil ? "dropped by the lock" : "outlived the lock")")
        Demo.say("tour: the history \(!hadHistory ? "was not up" : reading?.history == nil ? "dropped by the lock" : "outlived the lock")")
        Demo.say("tour: the generator \(!hadCard ? "was not up" : card == nil ? "dropped by the lock" : "outlived the lock")")
        // The lock took the copy off the pasteboard and Large Type off the
        // screen, and the search that follows reads the pasteboard itself.
        Demo.say("tour: pasteboard \(door.clipboard.isHolding ? "still holds the copy" : "cleared by the lock")")
        Demo.say("tour: large type \(panel.isUp ? "still up" : "closed by the lock")")
        let copies = door.desk?.copies.held.count ?? -1
        Demo.say("tour: the attachment's copy \(!hadCopy ? "was not there" : preview.isUp ? "is still under a preview" : copies == 0 && !FileManager.default.fileExists(atPath: attachments.path) ? "removed by the lock" : "outlived the lock, \(copies) files")")
        let standing = windows.filter { $0.isVisible || $0.contentView != nil || !$0.title.isEmpty }.count
        Demo.say("tour: item windows \(standing == 0 ? "closed by the lock" : "left standing, \(standing)")")
        // Locked, the app keeps its hot keys and nothing else: no timer,
        // and no other listener (D18).
        let answered = door.reprompt?.count ?? -1
        Demo.say("tour: guarded: \(answered == 0 ? "forgotten by the lock" : "\(answered) answers outlived the lock")")
        Demo.say("tour: open and fill: \(door.armedFill?.armed == nil ? "the page it opened is forgotten by the lock" : "still armed after the lock")")
        Demo.say("tour: watching while locked: \(watching)")
        Demo.say("tour: the door \(doorIsThere ? "outlived the lock" : "went with the lock")")
        let afterTheLock = await asAHost(["type": "hello"]).flatMap { BridgeWire.kind(of: $0) } ?? "nothing"
        Demo.say("tour: host: \(afterTheLock == "locked" ? "after the lock it found no door" : "after the lock it said \(afterTheLock)")")
        await walk(agent, door)
        Demo.say("tour: \(store.state == .locked ? "locked" : "not locked")")
    }

    /// One message through the door from a process of its own, as Orion
    /// sends one: a copy of the host `scripts/canary.sh` signed, the same
    /// binary with this app where Orion is, since the real one says nothing
    /// to a parent that is no browser. Nil if it said nothing.
    private static func asAHost(_ message: [String: Any]) async -> Data? {
        guard let path = ProcessInfo.processInfo.environment["OP_TOUR_HOST"],
              let body = try? JSONSerialization.data(withJSONObject: message.merging(["v": BridgeWire.version]) { $1 })
        else { return nil }
        return await Task.detached {
            let run = Process(), sent = Pipe(), said = Pipe()
            run.executableURL = URL(fileURLWithPath: path)
            run.arguments = ["chrome-extension://canary/"]
            run.standardInput = sent
            run.standardOutput = said
            run.standardError = FileHandle.nullDevice
            // In the pipe before it starts, so a host that goes at once
            // leaves no write to be signalled for. Its input stays open
            // until it has answered, as the spike saw Orion leave it.
            guard (try? BridgeWire.write(body, to: sent.fileHandleForWriting.fileDescriptor)) != nil,
                  (try? run.run()) != nil else { return nil }
            let answer = try? BridgeWire.read(from: said.fileHandleForReading.fileDescriptor)
            try? sent.fileHandleForWriting.close()
            run.waitUntilExit()
            return answer
        }.value
    }

    /// The whole way an extension in Orion comes: the switch off and nobody
    /// let in, the switch on and the real card raised and answered, a list
    /// that holds no password and a fill that holds the login's, which is a
    /// canary, from a process that is not this one over the file at the
    /// real path. The search that follows looks for it everywhere else.
    private static func askAsAHost(_ door: Door, _ browser: BrowserDoor?) async -> String {
        guard let browser else { return "host: there is no door" }
        func kind(_ answer: Data?) -> String? { answer.flatMap { BridgeWire.kind(of: $0) } }

        let off = kind(await asAHost(["type": "hello"]))
        guard off == "unknown", browser.question == nil else { return "host: with the switch off it heard \(off ?? "nothing")" }
        door.preferences.settings.browser.inOrion = true
        let unseen = kind(await asAHost(["type": "hello"]))
        guard unseen == "unknown", let question = browser.question else {
            return "host: an unseen origin heard \(unseen ?? "nothing") and raised \(browser.question == nil ? "no card" : "a card")"
        }
        question.allow()
        let allowed = kind(await asAHost(["type": "hello"]))
        guard allowed == "ready" else { return "host: let in, it heard \(allowed ?? "nothing")" }

        let chosen = door.store.shelves.all.lazy.compactMap { entry -> (id: String, url: String, password: String)? in
            guard !entry.item.reprompt, let login = entry.item.login, let password = login.password,
                  let url = login.uris.first(where: { $0.uri.hasPrefix("https:") })?.uri else { return nil }
            return (entry.item.id, url, password)
        }.first
        guard let chosen else { return "host: found no login with an address" }
        guard DemoVault.canaries.contains(chosen.password) else { return "host: the login's password is no canary" }

        var listed = await asAHost(["type": "logins", "url": chosen.url]) ?? Data()
        var filled = await asAHost(["type": "fill", "id": chosen.id, "url": chosen.url]) ?? Data()
        defer {
            listed.resetBytes(in: 0..<listed.count)
            filled.resetBytes(in: 0..<filled.count)
        }
        guard BridgeWire.kind(of: listed) == "logins", String(decoding: listed, as: UTF8.self).contains(chosen.id) else {
            return "host: the list did not hold the login"
        }
        guard !String(decoding: listed, as: UTF8.self).contains(chosen.password) else { return "host: a password in the list" }
        let answer = try? JSONSerialization.jsonObject(with: filled) as? [String: Any]
        guard answer?["password"] as? String == chosen.password else { return "host: the fill did not hold the password" }
        return "host: turned away with the switch off, let in on the card, listed a login with no password and was given it"
    }

    /// One connection to the door as the provider. A Debug build holds no
    /// provider and a peer check would close on anything else, so the tour
    /// is the caller over a socketpair, on the door's own wire and through
    /// its own answer. `talk` is handed a way to say one message.
    private static func asTheProvider(_ browser: BrowserDoor?, called name: String,
                                      _ talk: (@escaping ([String: Any]) async -> Data?) async -> String) async -> String {
        guard let browser else { return "\(name): there is no door" }
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return "\(name): no socketpair" }
        let end = pair[1]
        var wait = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(end, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        let connection = BridgeConnection(descriptor: pair[0], caller: .autofill) { await browser.answer($0, from: $1) }
        connection.start()
        defer {
            connection.cut()
            close(end)
        }
        func ask(_ message: [String: Any]) async -> Data? {
            await Task.detached {
                let body = try? JSONSerialization.data(withJSONObject: message.merging(["v": BridgeWire.version]) { $1 })
                guard let body, (try? BridgeWire.write(body, to: end)) != nil else { return nil }
                return try? BridgeWire.read(from: end)
            }.value
        }
        guard await ask(["type": "hello"]).flatMap({ BridgeWire.kind(of: $0) }) == "ready" else { return "\(name): not let in" }
        return await talk(ask)
    }

    /// What the provider asks of the door, with the demo's GitHub passkey,
    /// whose key is a canary: a list with no key in it, and a signature a
    /// verifier takes, after a finger.
    private static func signInWithAPasskey(_ browser: BrowserDoor?) async -> String {
        await asTheProvider(browser, called: "passkey") { ask in
            let hash = Data(SHA256.hash(data: Data("tour".utf8)))
            var listed = await ask(["type": "passkeys", "rp": "github.com", "allowed": []]) ?? Data()
            defer { listed.resetBytes(in: 0..<listed.count) }
            let logins = (try? JSONSerialization.jsonObject(with: listed) as? [String: Any])?["logins"] as? [[String: Any]]
            guard logins?.count == 1, let id = logins?.first?["id"] as? String else { return "passkey: the list did not hold one" }
            guard !String(decoding: listed, as: UTF8.self).contains(DemoVault.passkey) else { return "passkey: the key in the list" }

            let sheets = enclave.asked.count
            var said = await ask(["type": "assert", "id": id, "rp": "github.com", "allowed": [],
                                  "hash": hash.base64EncodedString()]) ?? Data()
            defer { said.resetBytes(in: 0..<said.count) }
            guard BridgeWire.kind(of: said) == "asserted" else { return "passkey: it said \(BridgeWire.kind(of: said) ?? "nothing")" }
            guard enclave.asked.count == sheets + 1, enclave.asked.last == GuardedAct.passkey.reason else {
                return "passkey: \(enclave.asked.count - sheets) fingers for one signature"
            }
            guard !String(decoding: said, as: UTF8.self).contains(DemoVault.passkey) else { return "passkey: the key in the answer" }
            let answer = (try? JSONSerialization.jsonObject(with: said) as? [String: Any])?["assertion"] as? [String: String]
            guard let data = answer?["authenticatorData"].flatMap({ Data(base64Encoded: $0) }),
                  let signature = answer?["signature"].flatMap({ Data(base64Encoded: $0) }),
                  let signed = try? P256.Signing.ECDSASignature(derRepresentation: signature),
                  let key = try? P256.Signing.PrivateKey(rawRepresentation: Data(DemoVault.passkeySeed.utf8)),
                  key.publicKey.isValidSignature(signed, for: data + hash)
            else { return "passkey: the signature did not verify" }
            return "passkey: listed one with no key, and after one finger signed so that its public key verified it"
        }
    }

    /// The provider asking for a code, for the bank's page, whose secret is a
    /// canary: a list without it, and the code and nothing else.
    private static func askForACode(_ browser: BrowserDoor?, _ store: VaultStore) async -> String {
        await asTheProvider(browser, called: "code") { ask in
            let page = "https://www.isbank.com.tr/giris"
            var listed = await ask(["type": "codes", "url": page]) ?? Data()
            defer { listed.resetBytes(in: 0..<listed.count) }
            let logins = (try? JSONSerialization.jsonObject(with: listed) as? [String: Any])?["logins"] as? [[String: Any]]
            guard logins?.count == 1, let id = logins?.first?["id"] as? String else { return "code: the list did not hold one" }
            var said = await ask(["type": "code", "id": id, "url": page]) ?? Data()
            defer { said.resetBytes(in: 0..<said.count) }
            guard BridgeWire.kind(of: said) == "code" else { return "code: it said \(BridgeWire.kind(of: said) ?? "nothing")" }
            let text = String(decoding: listed + said, as: UTF8.self)
            guard !DemoVault.totpSecrets.contains(where: text.contains) else { return "code: the secret went through the door" }
            let answer = try? JSONSerialization.jsonObject(with: said) as? [String: Any]
            guard let code = answer?["code"] as? String, let totp = store.entry(id: id)?.item.oneTimeCode,
                  [store.now(), store.now().addingTimeInterval(-1)].contains(where: { totp.code(at: $0) == code })
            else { return "code: it was not the login's" }
            return "code: listed one with no secret, and handed over the code alone"
        }
    }

    /// The provider when the system names nothing (OP-80): told Orion is in
    /// front on the bank's page, it lists that page's login with no password
    /// and fills it for the address the app used, then finds a login by a
    /// word and is handed it on one finger. Both passwords are canaries.
    private static func askWithNothingNamed(_ browser: BrowserDoor?, _ store: VaultStore) async -> String {
        let (wasInFront, wasOn) = (front, page)
        defer { (front, page) = (wasInFront, wasOn) }
        front = FrontApp(pid: 1, bundleID: Browser.orion.bundleID, name: Browser.orion.name)
        page = "https://www.isbank.com.tr/giris"
        return await asTheProvider(browser, called: "sheet") { ask in
            func logins(in said: Data) -> [[String: Any]]? {
                (try? JSONSerialization.jsonObject(with: said) as? [String: Any])?["logins"] as? [[String: Any]]
            }
            @MainActor func holdsAPassword(_ said: Data) -> Bool {
                let text = String(decoding: said, as: UTF8.self)
                return store.shelves.all.contains { $0.item.login?.password.map(text.contains) == true }
            }
            func password(in said: Data) -> String? {
                (try? JSONSerialization.jsonObject(with: said) as? [String: Any])?["password"] as? String
            }

            var inFront = await ask(["type": "front"]) ?? Data()
            defer { inFront.resetBytes(in: 0..<inFront.count) }
            let said = try? JSONSerialization.jsonObject(with: inFront) as? [String: Any]
            guard BridgeWire.kind(of: inFront) == "front", let id = logins(in: inFront)?.first?["id"] as? String,
                  let url = said?["url"] as? String, url == page
            else { return "sheet: nothing listed for the page in front" }
            guard !holdsAPassword(inFront) else { return "sheet: a password in what is in front" }
            var filled = await ask(["type": "fill", "id": id, "url": url]) ?? Data()
            defer { filled.resetBytes(in: 0..<filled.count) }
            guard let shown = password(in: filled), shown == store.entry(id: id)?.item.login?.password else {
                return "sheet: the fill did not hold the password"
            }

            var none = await ask(["type": "find", "word": ""]) ?? Data()
            var found = await ask(["type": "find", "word": "github"]) ?? Data()
            defer {
                none.resetBytes(in: 0..<none.count)
                found.resetBytes(in: 0..<found.count)
            }
            guard logins(in: none)?.isEmpty == true else { return "sheet: no word listed something" }
            guard let chosen = logins(in: found)?.first?["id"] as? String else { return "sheet: the word found nothing" }
            guard !holdsAPassword(found) else { return "sheet: a password in what a word found" }

            let sheets = enclave.asked.count
            var picked = await ask(["type": "pick", "id": chosen]) ?? Data()
            defer { picked.resetBytes(in: 0..<picked.count) }
            guard enclave.asked.count == sheets + 1, enclave.asked.last == GuardedAct.pick.reason else {
                return "sheet: \(enclave.asked.count - sheets) fingers for one pick"
            }
            guard let handed = password(in: picked), handed == store.entry(id: chosen)?.item.login?.password,
                  DemoVault.canaries.contains(handed)
            else { return "sheet: the pick did not hold the password" }
            return "sheet: listed the page in front with no password and filled it, no word found nothing, and a word's login took one finger"
        }
    }

    /// What a toast sends, through a host at the real door: a canary a page
    /// took, asked about by a mark and then saved, the same one known again,
    /// a second canary over it under one finger, and a host told never to ask.
    /// What the canary then searches for is these two, everywhere but here.
    /// What a field with no login is offered, asked as a page's caller asks:
    /// the words and not one password of any login, and a password the engine
    /// made, which is the tour's own canary and goes no further than this.
    private static func offerToAField(_ door: Door) async -> String {
        let url = "https://hic.example.test/kayit"
        guard let words = await asAHost(["type": "usernames", "url": url]),
              let said = try? JSONSerialization.jsonObject(with: words) as? [String: Any],
              said["type"] as? String == "usernames", let usernames = said["usernames"] as? [String], !usernames.isEmpty
        else { return "offered: the usernames did not come" }
        let text = String(decoding: words, as: UTF8.self)
        let passwords = (door.store.shelves.byType[.login] ?? []).compactMap(\.item.login?.password)
        guard !passwords.isEmpty, !passwords.contains(where: text.contains) else { return "offered: a password in the usernames" }
        guard let made = await asAHost(["type": "generate", "url": url]),
              let answer = try? JSONSerialization.jsonObject(with: made) as? [String: Any],
              answer["type"] as? String == "generated", (answer["password"] as? String)?.isEmpty == false
        else { return "offered: the engine made no password" }
        return "offered: the usernames with no password, and a password the engine made"
    }

    private static func saveWhatAPageTook(_ door: Door) async -> String {
        let store = door.store
        let url = "https://kayit.example.test/giris?token=1"
        func said(_ answer: Data?) -> [String: Any] {
            answer.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        }
        func known(_ password: String) async -> (answer: [String: Any], holds: Bool) {
            let key = SymmetricKey(size: .bits256)
            let mark = Data(HMAC<SHA256>.authenticationCode(for: Data(password.utf8), using: key))
            let keyBytes = key.withUnsafeBytes { Data($0) }
            let answer = await asAHost(["type": "known", "url": url, "username": DemoVault.usernameDomain,
                                        "key": keyBytes.base64EncodedString(), "mark": mark.base64EncodedString()])
            return (said(answer), answer.map { String(decoding: $0, as: UTF8.self).contains(password) } ?? true)
        }
        func saving(_ password: String, as id: String?) async -> [String: Any] {
            var message: [String: Any] = ["type": "save", "url": url, "username": DemoVault.usernameDomain,
                                          "password": Data(password.utf8).base64EncodedString()]
            if let id { message["id"] = id }
            return said(await asAHost(message))
        }

        let new = await known(DemoVault.pageTook)
        guard new.answer["state"] as? String == "new", !new.holds else { return "saved: the first it heard \(new.answer["state"] ?? "nothing")" }
        guard let id = await saving(DemoVault.pageTook, as: nil)["id"] as? String,
              let login = store.entry(id: id)?.item.login, login.password == DemoVault.pageTook,
              login.uris.map(\.uri) == ["https://kayit.example.test"]
        else { return "saved: the new login is not in the store at the page's origin" }
        guard await known(DemoVault.pageTook).answer["state"] as? String == "same" else { return "saved: the same password asked again" }

        let changed = await known(DemoVault.pageChanged)
        guard changed.answer["state"] as? String == "update", !changed.holds else { return "saved: a changed password heard \(changed.answer["state"] ?? "nothing")" }
        let sheets = enclave.asked.count
        let update = await saving(DemoVault.pageChanged, as: id)
        guard update["type"] as? String == "saved" else { return "saved: the update heard \(update["reason"] ?? "nothing")" }
        guard enclave.asked.count == sheets + 1, enclave.asked.last == GuardedAct.overwrite.reason else {
            return "saved: \(enclave.asked.count - sheets) fingers for one update"
        }
        guard let item = store.entry(id: id)?.item, item.login?.password == DemoVault.pageChanged,
              item.passwordHistory.first?.password == DemoVault.pageTook
        else { return "saved: the update did not keep the old password in the history" }

        guard said(await asAHost(["type": "never", "url": url]))["state"] as? String == "never",
              door.preferences.settings.browser.neverSave == ["kayit.example.test"],
              await known(DemoVault.pageTook).answer["state"] as? String == "never"
        else { return "saved: a host told never to ask asked" }
        return "saved: asked by a mark, made a login at the page's origin, stayed quiet for the same password, changed it under one finger and kept the old one, and never asked again"
    }

    /// What a toast's Sign In sends, through a host at the real door: a list
    /// for the page's own relying party with no key in it, a signature its
    /// public key verifies after one finger, and another site's relying party
    /// turned away with nobody asked.
    private static func signInForAPage(_ door: Door) async -> String {
        let page = "https://github.com/login?return=tour"
        let hash = Data(SHA256.hash(data: Data("page".utf8)))
        var listed = await asAHost(["type": "passkeys", "rp": "github.com", "url": page, "allowed": []]) ?? Data()
        defer { listed.resetBytes(in: 0..<listed.count) }
        let logins = (try? JSONSerialization.jsonObject(with: listed) as? [String: Any])?["logins"] as? [[String: Any]]
        guard logins?.count == 1, let id = logins?.first?["id"] as? String else { return "page's passkey: the list did not hold one" }
        guard !String(decoding: listed, as: UTF8.self).contains(DemoVault.passkey) else { return "page's passkey: the key in the list" }

        let sheets = enclave.asked.count
        let refused = await asAHost(["type": "assert", "id": id, "rp": "github.com", "url": "https://example.test/",
                                     "allowed": [], "hash": hash.base64EncodedString()])
        guard refused.flatMap({ BridgeWire.kind(of: $0) }) == "refused", enclave.asked.count == sheets else {
            return "page's passkey: another site's page was answered"
        }
        var said = await asAHost(["type": "assert", "id": id, "rp": "github.com", "url": page, "allowed": [],
                                  "hash": hash.base64EncodedString()]) ?? Data()
        defer { said.resetBytes(in: 0..<said.count) }
        guard BridgeWire.kind(of: said) == "asserted" else { return "page's passkey: it said \(BridgeWire.kind(of: said) ?? "nothing")" }
        guard enclave.asked.count == sheets + 1, enclave.asked.last == GuardedAct.passkey.reason else {
            return "page's passkey: \(enclave.asked.count - sheets) fingers for one signature"
        }
        guard !String(decoding: said, as: UTF8.self).contains(DemoVault.passkey) else { return "page's passkey: the key in the answer" }
        let answer = (try? JSONSerialization.jsonObject(with: said) as? [String: Any])?["assertion"] as? [String: String]
        guard let data = answer?["authenticatorData"].flatMap({ Data(base64Encoded: $0) }),
              let signature = answer?["signature"].flatMap({ Data(base64Encoded: $0) }),
              let signed = try? P256.Signing.ECDSASignature(derRepresentation: signature),
              let key = try? P256.Signing.PrivateKey(rawRepresentation: Data(DemoVault.passkeySeed.utf8)),
              key.publicKey.isValidSignature(signed, for: data + hash)
        else { return "page's passkey: the signature did not verify" }
        return "page's passkey: listed for the page's relying party with no key, another site turned away unasked, and after one finger signed so that its public key verified it"
    }

    /// What the provider will ask once a page can reach it (OP-76): a new
    /// login under one finger, with a key that is a canary because a demo's
    /// generator makes it one, and then a signature with that key, on a
    /// second finger, that the public key in the registration verifies.
    private static func makeAPasskey(_ browser: BrowserDoor?) async -> String {
        await asTheProvider(browser, called: "made passkey") { ask in
            let site = "made.oripass.invalid"
            let hash = Data(SHA256.hash(data: Data("tour made".utf8)))
            let sheets = enclave.asked.count
            var made = await ask(["type": "make", "rp": site, "user": "tour", "handle": Data("tour".utf8).base64EncodedString(),
                                       "hash": hash.base64EncodedString(), "algorithms": [PasskeyOrder.es256]]) ?? Data()
            defer { made.resetBytes(in: 0..<made.count) }
            guard BridgeWire.kind(of: made) == "made" else { return "made passkey: it said \(BridgeWire.kind(of: made) ?? "nothing")" }
            guard enclave.asked.count == sheets + 1, enclave.asked.last == GuardedAct.makePasskey.reason else {
                return "made passkey: \(enclave.asked.count - sheets) fingers for one"
            }
            guard !String(decoding: made, as: UTF8.self).contains(DemoVault.newPasskey) else { return "made passkey: the key in the answer" }
            let answer = (try? JSONSerialization.jsonObject(with: made) as? [String: Any])?["registration"] as? [String: String]
            guard let id = answer?["credential"], answer?["attestation"].flatMap({ Data(base64Encoded: $0) }) != nil else {
                return "made passkey: no registration"
            }

            var said = await ask(["type": "assert", "id": id, "rp": site, "allowed": [], "hash": hash.base64EncodedString()]) ?? Data()
            defer { said.resetBytes(in: 0..<said.count) }
            let assertion = (try? JSONSerialization.jsonObject(with: said) as? [String: Any])?["assertion"] as? [String: String]
            guard let data = assertion?["authenticatorData"].flatMap({ Data(base64Encoded: $0) }),
                  let signature = assertion?["signature"].flatMap({ Data(base64Encoded: $0) }),
                  let signed = try? P256.Signing.ECDSASignature(derRepresentation: signature),
                  DemoVault.newPasskeyKey().publicKey.isValidSignature(signed, for: data + hash)
            else { return "made passkey: the signature did not verify" }
            return "made passkey: one finger, no key in the answer, and it then signed so that its public key verified it"
        }
    }

    /// The agent's switch on over the shut vault, so the script can count
    /// it, and a caller on its socket as `ssh` would be: a list, which opens
    /// the vault, and a signature, on the one finger. The lock cuts the
    /// caller and leaves the socket. Its key is a canary, in the vault and
    /// out of it for one signature, and is searched for below with the rest.
    /// It is the demo's path and never the real one, which the tour does not
    /// touch.
    private static func walk(_ agent: SSHAgent, _ door: Door) async {
        door.preferences.settings.ssh.isOn = true
        Demo.say("tour: watching with the agent on: \(watching)")
        let sheets = enclave.asked.count
        Demo.say("tour: agent: \(await callAgent(over: door, sheets: sheets))")
        Demo.say("tour: pass: \(await askThroughAPass(agent, door))")
        Demo.say("tour: watching with no pass: \(watching)")
        door.preferences.settings.ssh.isOn = false
        Demo.say("tour: watching with the agent off: \(watching)")
        let isThere = FileManager.default.fileExists(atPath: AppPaths.demoAgent.path)
        Demo.say("tour: the agent's file \(isThere ? "outlived its switch" : "went with its switch")")
    }

    /// What the walk found, in one line for the script.
    private static func callAgent(over door: Door, sheets: Int) async -> String {
        guard let end = agentEnd() else { return "nothing at the socket" }
        defer { close(end) }
        func ask(_ body: Data) async -> Data? {
            await Task.detached {
                try? AgentWire.write(body, to: end)
                return try? AgentWire.read(from: end)
            }.value
        }
        guard let listed = await ask(Data([11])), door.store.state == .unlocked else { return "the list did not open the vault" }
        let blobs = listed.withUnsafeBytes { bytes -> [Data] in
            var reader = SSHReader(bytes)
            guard reader.byte() == 12, let count = reader.number() else { return [] }
            return (0..<count).compactMap { _ in
                let blob = reader.data()
                return reader.string() == nil ? nil : blob
            }
        }
        guard let key = blobs.first, blobs.count == 1 else { return "\(blobs.count) keys listed" }
        let data = Data("what the tour signs".utf8)
        var request = Data([13])
        request.appendCounted(key)
        request.appendCounted(data)
        request.appendNumber(0)
        let answer = await ask(request)
        let signature = answer?.withUnsafeBytes { bytes -> Data? in
            var reader = SSHReader(bytes)
            return reader.byte() == 14 ? reader.data() : nil
        }
        guard let signature, SSHVerifies(signature, over: data, by: key) else { return "no signature came back" }
        guard enclave.asked.count == sheets + 1 else { return "\(enclave.asked.count - sheets) sheets for one list and one signature" }
        await door.store.lock()
        guard await ask(Data([11])) == nil else { return "a caller outlived the lock" }
        return "one key listed and a signature a verifier took on one finger, and the lock cut the caller"
    }

    /// The whole of a pass. The vault opened by a finger, a pass given to
    /// this app with one more, and the lock: a pass is what stands after
    /// it, one timer with the agent. Then a caller as `ssh` is, which binds a
    /// session to a host and asks to sign a login on it, and one as `git` is,
    /// which asks to sign a commit, over the shut vault with no finger. Its
    /// key is the canary the walk above signed with, and the search looks for
    /// it after this.
    private static func askThroughAPass(_ agent: SSHAgent, _ door: Door) async -> String {
        await door.askForFinger().value
        guard door.store.state == .unlocked, let key = agent.passKeys.first else { return "the vault did not open for it" }
        guard let signer = AppSigner.of(getpid()) else { return "this build has no signature to hold a pass to" }
        // A host the tour has seen, which a demo's file never says.
        let host = Curve25519.Signing.PrivateKey()
        var hostKey = Data()
        hostKey.appendCounted(Data(AgentKeyKind.ed25519.rawValue.utf8))
        hostKey.appendCounted(host.publicKey.rawRepresentation)
        door.passes.knownHosts = { [hostKey] }
        guard await agent.give(to: PassApp(name: AppInfo.name, signer: signer), for: .oneHour) else { return "no pass was given" }
        // Handed in and not found on the socket: at the top of a real
        // connection is whoever ran the canary, and that is not who this
        // pass is for. Reading a real peer is the OpenSSH tests'.
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return "no socket for it" }
        let end = pair[0]
        defer { close(end) }
        var wait = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(end, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        await door.store.lock()
        guard door.store.state == .locked, door.passes.standing.count == 1 else { return "the lock took the pass" }
        Demo.say("tour: watching with a pass: \(watching)")
        door.preferences.settings.ssh.phone = SSHPhone(name: "tour", publicKey: Data(count: 65))
        Demo.say("tour: watching with a pass and a phone: \(watching)")
        door.preferences.settings.ssh.phone = nil
        let sheets = enclave.asked.count

        // After the lock, which cuts whoever is on the socket.
        agent.adopt(pair[1], peer: AgentPeer(names: [AppInfo.name], app: Bundle.main.bundlePath, signer: signer))
        func ask(_ body: Data) async -> Data? {
            await Task.detached {
                try? AgentWire.write(body, to: end)
                return try? AgentWire.read(from: end)
            }.value
        }
        let session = Data("the session the tour's host signed".utf8)
        guard let said = try? host.signature(for: session) else { return "the host would not sign" }
        var signature = Data()
        signature.appendCounted(Data(AgentKeyKind.ed25519.rawValue.utf8))
        signature.appendCounted(said)
        var bind = Data([27])
        bind.appendCounted(Data(AgentRequest.bindName.utf8))
        bind.appendCounted(hostKey)
        bind.appendCounted(session)
        bind.appendCounted(signature)
        bind.append(0)
        guard await ask(bind) == Data([6]) else { return "the bind was refused" }

        var login = Data()
        login.appendCounted(session)
        login.append(50)
        login.appendCounted(Data("tour".utf8))
        login.appendCounted(Data("ssh-connection".utf8))
        login.appendCounted(Data("publickey".utf8))
        login.append(1)
        login.appendCounted(Data(key.kind.rawValue.utf8))
        login.appendCounted(key.blob)
        var request = Data([13])
        request.appendCounted(key.blob)
        request.appendCounted(login)
        request.appendNumber(0)
        let listed = await ask(Data([11]))
        guard let listed, listed.first == 12, door.store.state == .locked else { return "the list asked for a finger" }
        func signed(in answer: Data?) -> Data? {
            answer?.withUnsafeBytes { bytes -> Data? in
                var reader = SSHReader(bytes)
                return reader.byte() == 14 ? reader.data() : nil
            }
        }
        guard let made = signed(in: await ask(request)), SSHVerifies(made, over: login, by: key.blob)
        else { return "no signature came back" }

        var commit = Data("SSHSIG".utf8)
        commit.appendCounted(Data("git".utf8))
        commit.appendCounted(Data())
        commit.appendCounted(Data("sha512".utf8))
        commit.appendCounted(Data(SHA512.hash(data: Data("the tour's commit".utf8))))
        var signing = Data([13])
        signing.appendCounted(key.blob)
        signing.appendCounted(commit)
        signing.appendNumber(0)
        guard let madeForGit = signed(in: await ask(signing)), SSHVerifies(madeForGit, over: commit, by: key.blob)
        else { return "no signature came back for the commit" }
        guard door.store.state == .locked, enclave.asked.count == sheets else { return "a finger was asked for" }
        let pass = door.passes.standing.first
        guard pass?.logins == 1, pass?.commits == 1 else { return "the signatures were not counted" }

        let held = pass?.heldBytes ?? []
        door.passes.standing.forEach(door.passes.end)
        guard !held.isEmpty, held.allSatisfy(\.isWiped), door.passes.standing.isEmpty else { return "revoking left a key in memory" }
        return "given with one finger, signed a login and a commit over the shut vault with none, and revoked to zeros"
    }

    /// A connection to the demo's socket, as `ssh`'s. A lock may cut it, and
    /// a write after that must be an error here and not a signal that kills
    /// the tour.
    private static func agentEnd() -> Int32? {
        let end = socket(AF_UNIX, SOCK_STREAM, 0)
        var wait = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(end, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(end, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(AppPaths.demoAgent.path.utf8CString).map { UInt8(bitPattern: $0) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(end, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(end)
            return nil
        }
        return end
    }

    /// ⇧⌘C on the item that asks: nothing is copied until the finger has
    /// answered, the sheet's sentence names no item, and a second copy and
    /// a reveal of the same item ask nothing more.
    private static func guarded(_ door: Door) async -> String {
        guard let panes = door.panes, let reprompt = door.reprompt,
              let entry = door.store.shelves.all.first(where: { $0.item.reprompt }) else {
            return "guarded: no item asks"
        }
        let before = enclave.asked.count
        // Quick Access left a copy there.
        door.clipboard.clear()
        panes.select(item: entry.id)
        guard panes.copyPassword(), !door.clipboard.isHolding else { return "guarded: copied without asking" }
        await reprompt.asking?.value
        guard door.clipboard.isHolding, enclave.asked.last == GuardedAct.copy.reason else {
            return "guarded: the finger did not let the copy through"
        }
        door.clipboard.clear()
        panes.copyPassword()
        panes.toggleRevealed()
        let asked = enclave.asked.count - before
        guard door.clipboard.isHolding, panes.isAllRevealed, asked == 1 else {
            return "guarded: asked \(asked) times for one item"
        }
        door.clipboard.clear()
        panes.select(item: nil)
        return "guarded: the finger was asked once, and a second copy and a reveal asked nothing"
    }

    /// The fill's key over Spotify's app, which the vault has one login for.
    /// Before macOS allows the typing the password is copied and the panel
    /// says so; allowed, the login goes to the sink key by key, to that app
    /// and no other, and the pasteboard's count does not move. With another
    /// app in front by then, no key goes at all.
    private static func fill(_ quick: QuickAccess, _ door: Door) async -> String {
        defer {
            front = nil
            ground.frontPID = nil
            sink.forget()
            door.clipboard.clear()
        }
        await door.store.indexing?.value
        let app = FrontApp(pid: 4747, bundleID: "com.spotify.client", name: "Spotify")
        front = app
        ground.frontPID = app.pid
        door.clipboard.clear()
        guard HotKeys.press(.fill) == noErr, quick.isUp, quick.notice != nil, door.clipboard.isHolding,
              sink.keys.isEmpty else { return "fill: not allowed, it did not copy and say so" }
        quick.allowTyping()
        guard !quick.isUp, access.asked == 1 else { return "fill: the notice's button did not ask" }
        door.clipboard.clear()

        access.isTrusted = true
        let board = NSPasteboard.general
        let count = board.changeCount
        guard HotKeys.press(.fill) == noErr, !quick.isUp, let typing = typist.typing else {
            return "fill: allowed, the key typed nothing"
        }
        let outcome = await typing.value
        guard let login = door.store.shelves.all.first(where: { $0.item.name == "Spotify" })?.item.login,
              let username = login.username, let password = login.password,
              sink.typed == username + "\t" + password, sink.pids == [app.pid],
              outcome == .typed(sink.keys.count) else { return "fill: what was typed is not the login" }
        guard board.changeCount == count, !door.clipboard.isHolding else {
            return "fill: the pasteboard was written during a fill"
        }
        let typed = sink.keys.count
        sink.forget()

        // The key over Spotify, and something else in front by the time
        // the typing would start.
        ground.frontPID = app.pid + 1
        guard HotKeys.press(.fill) == noErr, let late = typist.typing else { return "fill: the key did nothing" }
        guard await late.value == .notInFront(0), sink.keys.isEmpty, board.changeCount == count else {
            return "fill: typed into an app that was not the one in front"
        }
        return "fill: copied and said so until it was allowed, then typed \(typed) keys into the app in front "
            + "with the pasteboard untouched, and none into another"
    }

    /// Open & Fill on Spotify's login: the address goes to a browser that
    /// opens nothing, and ⌘\ in that browser then types the login with no
    /// panel, once. Another browser in front gets nothing from it. It is
    /// armed again at the end and left so, for the lock to forget.
    private static func openAndFill(_ quick: QuickAccess, _ door: Door) async -> String {
        defer {
            front = nil
            ground.frontPID = nil
            sink.forget()
            sites.forget()
            door.clipboard.clear()
        }
        guard let panes = door.panes, let armed = door.armedFill,
              let entry = door.store.shelves.all.first(where: { $0.item.name == "Spotify" }),
              let login = entry.item.login, let username = login.username, let password = login.password else {
            return "open and fill: there is no login to open"
        }
        let orion = FrontApp(pid: 4748, bundleID: "com.kagi.kagimacOS", name: "Orion")
        let other = FrontApp(pid: 4749, bundleID: "com.apple.Safari", name: "Safari")
        panes.select(item: entry.id)
        defer { panes.select(item: nil) }
        access.isTrusted = true
        let board = NSPasteboard.general
        let count = board.changeCount

        guard panes.openAndFill(), sites.opened.count == 1, armed.armed != nil else {
            return "open and fill: the key opened nothing or armed nothing"
        }
        // Another browser in front: the page is still waiting.
        front = other
        ground.frontPID = other.pid
        guard HotKeys.press(.fill) == noErr, sink.keys.isEmpty, armed.armed != nil else {
            return "open and fill: a page for one browser was used by another"
        }
        quick.close()
        // The browser it was opened in, on another site's page: nothing
        // of Spotify's is typed there and the page is still waiting.
        front = orion
        ground.frontPID = orion.pid
        page = "https://posta.kanarya.invalid/yeni"
        defer { page = nil }
        guard HotKeys.press(.fill) == noErr else { return "open and fill: the key was not heard" }
        await quick.askingArmed?.value
        await quick.askingTab?.value
        guard sink.keys.isEmpty, armed.armed != nil else {
            return "open and fill: the login went into a page that is not its own"
        }
        quick.close()
        page = "https://accounts.spotify.com/en/login"
        guard HotKeys.press(.fill) == noErr else { return "open and fill: the key was not heard" }
        await quick.askingArmed?.value
        guard !quick.isUp, let typing = typist.typing else {
            return "open and fill: the key typed nothing"
        }
        let outcome = await typing.value
        guard sink.typed == username + "\t" + password, sink.pids == [orion.pid], outcome == .typed(sink.keys.count),
              armed.armed == nil else { return "open and fill: what was typed is not the login, or the page stayed armed" }
        guard board.changeCount == count, !door.clipboard.isHolding else {
            return "open and fill: the pasteboard was written during a fill"
        }
        // Used once: the next key is the ordinary one, which for a browser
        // that will not say its page lists nothing and types nothing.
        sink.forget()
        page = nil
        guard HotKeys.press(.fill) == noErr, sink.keys.isEmpty else { return "open and fill: it filled twice" }
        quick.close()
        guard panes.openAndFill(), armed.armed != nil else { return "open and fill: it could not be armed again" }
        // Left armed, for the lock.
        return "open and fill: opened the address, typed the login once into the page it opened and not into another page or another browser, with the pasteboard untouched"
    }

    /// Quick Access raised over a browser on GitHub's sign-in page, and then
    /// over Spotify's app: each time the login for it is the first row,
    /// under the site's name and the app's. The panel is put away with
    /// nothing copied, and what it listed goes with the lock like the rest.
    private static func inFront(_ quick: QuickAccess, _ door: Door) async -> String {
        defer { front = nil; page = nil }
        await door.store.indexing?.value
        front = FrontApp(pid: 0, bundleID: "com.apple.Safari", name: "Safari")
        page = "https://github.com/login"
        quick.show()
        await quick.askingTab?.value
        let onPage = quick.headings[0] == "github.com" && quick.rows.first?.item.name == "GitHub"
        quick.close()
        front = FrontApp(pid: 0, bundleID: "com.spotify.client", name: "Spotify")
        page = nil
        quick.show()
        let inApp = quick.headings[0] == "Spotify" && quick.rows.first?.item.name == "Spotify"
        quick.close()
        guard onPage, inApp else { return "what is in front led nothing (page \(onPage), app \(inApp))" }
        return "what is in front: the page's login led the panel, and then the app's"
    }

    /// Quick Access raised by its key over the vault the menu has just
    /// shut: it is the lock, the finger is asked for by the panel itself,
    /// and the word typed before the finger came down is what it lists when
    /// the vault opens. Then the first of them opened and shut again, and
    /// its password copied with Return, which puts the panel away and
    /// writes the item's id to the file the search reads.
    private static func quickAccess(_ quick: QuickAccess, _ door: Door) async -> String {
        guard HotKeys.press(.quickAccess) == noErr, quick.isUp, !quick.isOpen else {
            return "quick access did not come up as the lock"
        }
        quick.query = "banka"
        await quick.asking?.value
        guard door.store.state == .unlocked else { return "quick access's finger did not open the vault" }
        await door.store.indexing?.value
        let found = quick.rows.count
        // Three ways to fail, and each says which. The first is not the
        // app's: without the keys, only a click in another app puts the
        // panel away, and that is a hand on this Mac during the tour.
        guard quick.isUp else { return "quick access was put away while the vault opened under it" }
        guard quick.query == "banka" else { return "quick access lost what was typed" }
        guard found > 0 else { return "quick access kept what was typed and found nothing for it" }
        guard quick.openSelected(), let actions = quick.opened?.actions.count, quick.back() else {
            return "quick access opened no item"
        }
        quick.pressReturn()
        guard !quick.isUp, door.clipboard.isHolding else { return "quick access copied nothing" }
        return "quick access kept what was typed, found \(found), opened \(actions) actions, "
            + "copied a password and closed, with \(quick.recents.ids.count) id kept"
    }

    /// The sign-in sheet's model over the engine that is `bw`, with the
    /// stand-in `scripts/canary.sh` names in `OP_TOUR_BW` in the real one's
    /// place: an account with two ways of a second step, so the password
    /// rides in two children's environments and the code goes down a pipe.
    /// What the search then looks for is both of them, anywhere.
    private static func signIn() async -> String {
        guard let path = ProcessInfo.processInfo.environment["OP_TOUR_BW"] else {
            return "no stand-in to sign in to"
        }
        let directory = engineDirectory
        try? FileManager.default.removeItem(at: directory)
        let engine = BwSignIn(preferredPath: path, runDirectory: directory.appendingPathComponent("run"),
                              dataDirectory: directory.appendingPathComponent("data"))
        var signedIn = false
        let sheet = SignIn(engine: engine) { password in
            signedIn = password != nil
            password?.wipe()
        }
        await sheet.signIn(server: .eu, email: "both@oripass.invalid",
                           password: SecretBytes(DemoVault.signInPassword))?.value
        guard case .method(let offered) = sheet.step, offered.contains(.authenticator) else {
            return "sign-in was not asked which second step"
        }
        await sheet.choose(.authenticator)?.value
        guard case .code = sheet.step else { return "sign-in was not asked for a code" }
        await sheet.enter(code: DemoVault.signInCode)?.value
        return signedIn ? "signed in" : "not signed in"
    }

    /// Where the tour signs in and where its engine runs: in the temporary
    /// directory, whose `run` the script watches for a socket file.
    private static let engineDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("oripass-tour-login")
    private static var engine: ServeBackend?
    /// The seal of the password that engine is opened with.
    static let engineSeal = engineDirectory.appendingPathComponent("seal")

    /// The engine that is `bw` over the same stand-in, now that it has an
    /// account: a child born holding one end of a socketpair, opened as a
    /// finger opens the real one, by a password that was sealed, unsealed
    /// and sent down the connection, asked for its items and left open
    /// until the lock. The demo vault has no child, so this is the one the
    /// script holds to D5 and D7: no socket file under its run directory at
    /// any moment it is open or after, nothing that opens a vault in its
    /// environment or its arguments while it is open, and no child after
    /// the lock. Its seal stays on disk beside the door's for the search.
    private static func openEngine() async -> String {
        guard let path = ProcessInfo.processInfo.environment["OP_TOUR_BW"] else {
            return "engine: no stand-in to start"
        }
        let run = engineDirectory.appendingPathComponent("run")
        let backend = ServeBackend(preferredPath: path, runDirectory: run,
                                   dataDirectory: engineDirectory.appendingPathComponent("data"))
        do {
            let seal = PasswordSeal(directory: engineSeal, enclave: FakeEnclave())
            let typed = SecretBytes(DemoVault.signInPassword)
            try seal.seal(typed)
            typed.wipe()
            try await backend.unlock(password: try seal.unseal())
            let items = try await backend.items()
            engine = backend
            leakASocket(in: run)
            return "engine: a child on a connected socket listed \(items.count) items"
        } catch {
            await backend.close()
            return "engine: the child did not open"
        }
    }

    /// `OP_LEAK=socket`: a socket file where the engine's would have been
    /// before D5 was rewritten, there while the engine is open and after
    /// the lock, so the script can be seen to find it both times. Debug
    /// builds only.
    private static func leakASocket(in run: URL) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["OP_LEAK"] == "socket" else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: run.appendingPathComponent("leaked-on-purpose.sock").path.utf8.prefix(buffer.count - 1))
        }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #endif
    }

    /// A menu item found by its key, with ⇧⌘ unless told otherwise, and sent
    /// its action if the menu would let it through, so a menu SwiftUI rebuilt
    /// without it would show here.
    private static func press(_ key: String,
                              with modifiers: NSEvent.ModifierFlags = [.command, .shift]) -> Bool {
        let items = (NSApp.mainMenu?.items ?? []).compactMap { $0.submenu?.items }.joined()
        guard let item = items.first(where: {
            $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers
        }), let action = item.action else { return false }
        if let validator = item.target as? NSMenuItemValidation, !validator.validateMenuItem(item) {
            return false
        }
        return NSApp.sendAction(action, to: item.target, from: item)
    }

    /// A row of the key table by its item in the menu bar, whatever key the
    /// keyboard in use has moved it to.
    private static func press(_ id: KeyCommand.ID, stroke: Int = 0) -> Bool {
        guard let item = KeyTable.item(id, stroke: stroke, in: NSApp.mainMenu), let action = item.action else {
            return false
        }
        if let validator = item.target as? NSMenuItemValidation, !validator.validateMenuItem(item) {
            return false
        }
        return NSApp.sendAction(action, to: item.target, from: item)
    }

    /// ⇧⌘L as the menu bar has it. If the item is not there the tour locks
    /// the store itself and says so.
    private static func lockFromMenu(_ store: VaultStore) async -> Bool {
        guard press("l") else {
            await store.lock()
            return false
        }
        for _ in 0..<300 where store.state != .locked {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return store.state == .locked
    }

    /// ⇧⌘D the same way: the sidebar goes and comes back.
    private static func foldFromMenu(_ door: Door) -> Bool {
        guard door.panes?.wantsSidebar == true, press("d"), door.panes?.wantsSidebar == false else {
            return false
        }
        return press("d") && door.panes?.wantsSidebar == true
    }

    /// Every row of the sidebar selected in turn, the vaults by their keys,
    /// and the section folded shut and opened, which is the one thing the
    /// sidebar writes down. What comes back is how many items the rows
    /// listed between them.
    private static func walkSidebar(_ door: Door) -> Int {
        guard let panes = door.panes else { return 0 }
        var listed = 0
        for row in panes.upperRows + panes.lowerRows {
            panes.select(row)
            listed += panes.listed.count
        }
        for key in 2...9 where press(String(key), with: .command) {
            listed += panes.listed.count
        }
        panes.toggleVaults()
        panes.toggleVaults()
        _ = press("1", with: .command)
        return panes.selection == .allItems ? listed : 0
    }

    /// The item list as a hand would leave it: every order both ways and
    /// every category, which are the three things it writes down, then the
    /// filter by its key with a username typed into it, a row chosen by the
    /// arrows and by a letter, and its grey line read. What comes back is how
    /// many rows the list held between them.
    private static func walkList(_ door: Door) -> Int {
        guard let panes = door.panes else { return 0 }
        var rows = 0
        for key in ItemList.Key.allCases {
            panes.order(by: key)
            panes.order(reversed: true)
            rows += panes.list.entries.count
        }
        for category in ItemList.Category.allCases {
            panes.choose(category)
            rows += panes.list.entries.count
        }
        panes.choose(.all)
        guard press("f", with: [.command, .option]), panes.isFiltering else { return 0 }
        panes.filter = DemoVault.usernameDomain
        rows += panes.list.entries.count
        panes.moveSelection(by: 1)
        panes.type("g")
        guard panes.selectedItem?.item.secondLine != nil else { return 0 }
        panes.toggle(.sort)
        panes.dismiss()
        panes.dismiss()
        panes.order(by: .title)
        return panes.isFiltering ? 0 : rows
    }

    /// Every row of the list chosen in turn and left on screen for a moment,
    /// so the details are drawn for each: the password and the hidden fields
    /// held under their dots, the notes read as Markdown, and "Last edited"
    /// opened. What comes back is how many logins and how many items of
    /// another type had a hidden row, or nothing if choosing another item
    /// left the dates open.
    private static func walkDetails(_ door: Door) async -> (logins: Int, others: Int) {
        guard let panes = door.panes else { return (0, 0) }
        var logins = 0
        var others = 0
        for entry in panes.list.entries {
            panes.select(item: entry.id)
            guard let detail = panes.detail, detail.id == entry.id, !panes.showsCreated else { return (0, 0) }
            panes.toggleCreated()
            if (detail.main + detail.fields).contains(where: \.isHidden) {
                if entry.item.type == .login { logins += 1 } else { others += 1 }
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        panes.select(item: nil)
        return (logins, others)
    }

    /// Password Health's page drawn over the counted vault, and a card's "Show
    /// Items" followed to its list, one of them read, and left for All
    /// Items again.
    private static func passwordHealth(_ door: Door) async -> String {
        guard let panes = door.panes else { return "password health: no panes" }
        await panes.store.counting?.value
        panes.select(.passwordHealth)
        try? await Task.sleep(nanoseconds: 20_000_000)
        let page = panes.dashboard
        let reused = page.cards.first { $0.kind == .reused }?.count ?? 0
        guard panes.showsDashboard, page.cards.allSatisfy({ $0.count != nil }) else {
            return "password health: the page was not counted"
        }
        panes.show(.reused)
        let shown = panes.list.entries.count
        panes.select(item: panes.list.entries.first?.id)
        try? await Task.sleep(nanoseconds: 20_000_000)
        guard shown > 0, shown == reused, panes.detail != nil else {
            return "password health: Show Items listed \(shown) of \(reused)"
        }
        panes.select(.allItems)
        guard panes.watched == nil else { return "password health: the card was still shown under All Items" }
        return "password health: \(page.cards.count) cards over \(page.passwords) passwords, and Show Items listed \(shown)"
    }

    /// The breach check (OP-53), switched on over a fetcher that answers
    /// from memory: every password hashed, five characters of each asked
    /// about, the three the demo calls seen put on their card, and one of
    /// them told so. The hashes are searched for with the canaries.
    private static func breaches(_ door: Door) async -> String {
        guard let panes = door.panes, let checker = panes.store.breaches else { return "breaches: no checker" }
        await panes.store.counting?.value
        let requests = await checker.requests
        let held = await checker.held
        let seen = panes.store.watch?.vulnerable ?? []
        guard requests > 0, held >= requests, seen.count == DemoBreaches.seen.count else {
            return "breaches: \(seen.count) seen in \(requests) requests"
        }
        panes.select(.passwordHealth)
        panes.show(.vulnerable)
        let shown = panes.list.entries.count
        panes.select(item: panes.list.entries.first?.id)
        try? await Task.sleep(nanoseconds: 20_000_000)
        let told = panes.banners.contains { $0.card == .vulnerable }
        panes.select(.allItems)
        guard shown == seen.count, told else { return "breaches: Show Items listed \(shown), and the item was \(told ? "told" : "not told")" }
        return "breaches: \(held) passwords asked about in \(requests) requests, \(seen.count) seen, listed and told"
    }

    /// The list of sites that take a one-time code (OP-54), switched on over
    /// a source that answers from memory: fetched once, compared with every
    /// login, the ones without a code put on their card, and one of them
    /// told so. Neither list holds a value of an item.
    private static func twoFactor(_ door: Door) async -> String {
        guard let panes = door.panes, let check = panes.store.twoFactor else { return "two-factor: no check" }
        await panes.store.counting?.value
        let requests = await check.requests
        let inactive = panes.store.watch?.twoFactor ?? []
        guard requests == 1, await check.held != nil, !inactive.isEmpty else {
            return "two-factor: \(inactive.count) logins without a code in \(requests) requests"
        }
        panes.select(.passwordHealth)
        panes.show(.twoFactor)
        let shown = panes.list.entries.count
        panes.select(item: panes.list.entries.first?.id)
        try? await Task.sleep(nanoseconds: 20_000_000)
        let told = panes.banners.contains { $0.card == .twoFactor }
        panes.select(.allItems)
        guard shown == inactive.count, told else {
            return "two-factor: Show Items listed \(shown), and the item was \(told ? "told" : "not told")"
        }
        return "two-factor: \(inactive.count) logins without a code in \(requests) request, listed and told"
    }

    /// The first login with a password and a hidden field of its own.
    private static func choose(_ door: Door) -> ItemDetail? {
        guard let panes = door.panes else { return nil }
        for entry in panes.list.entries where entry.item.type == .login {
            panes.select(item: entry.id)
            if let detail = panes.detail, detail.passwordRowID != nil, detail.hiddenRows.count > 1 { return detail }
        }
        return nil
    }

    /// ⌘R by its key shows every hidden field of an item, and choosing the
    /// next item hides them all again.
    private static func reveal(_ door: Door) -> String {
        guard let panes = door.panes, let detail = choose(door) else { return "found no login to reveal" }
        guard press("r", with: .command), detail.hiddenRows.allSatisfy(panes.reading.shows) else {
            return "⌘R revealed nothing"
        }
        let shown = panes.reading.revealed.count
        panes.moveSelection(by: 1)
        guard panes.detail?.id != detail.id, panes.reading.revealed.isEmpty else {
            return "the next item left \(panes.reading.revealed.count) fields revealed"
        }
        return "revealed \(shown) fields, and the next item concealed them"
    }

    /// ⇧⌘C by its key puts a password on the general pasteboard with the
    /// marker, and the wait, cut short for the tour, takes it off again.
    private static func copyAndWait(_ door: Door) async -> String {
        guard let detail = choose(door), let password = detail.value(of: ItemDetail.passwordRow) else {
            return "found no password to copy"
        }
        door.clipboard.delay = 0.4
        defer { door.clipboard.delay = nil }
        guard press("c"), door.clipboard.isHolding, NSPasteboard.general.string(forType: .string) == password,
              NSPasteboard.general.types?.contains(Clipboard.concealed) == true else {
            return "⇧⌘C did not copy the password with its marker"
        }
        await door.clipboard.clearing?.value
        guard !door.clipboard.isHolding, NSPasteboard.general.string(forType: .string) == nil else {
            return "the copy was still there after the delay"
        }
        return "copied a password, and the delay cleared it"
    }

    /// ⌥⌘C by its key puts a login's one-time code on the general
    /// pasteboard with the marker: the digits that stand now, made from a
    /// secret that is a canary and is itself put nowhere. The copy is taken
    /// off again, since the steps that follow start from nothing copied.
    private static func copyCode(_ door: Door) -> String {
        guard let panes = door.panes else { return "code: no panes" }
        for entry in panes.list.entries where entry.item.login?.totp != nil && !entry.item.reprompt {
            panes.select(item: entry.id)
            guard let secret = entry.item.login?.totp, let totp = Totp(secret) else { continue }
            let before = totp.code(at: door.store.now())
            guard press(.copyCode), door.clipboard.isHolding, panes.reading.copied == ItemDetail.codeRow,
                  let copied = NSPasteboard.general.string(forType: .string),
                  NSPasteboard.general.types?.contains(Clipboard.concealed) == true else {
                return "code: ⌥⌘C did not copy a code with its marker"
            }
            // The half minute may have turned between the two.
            guard copied == before || copied == totp.code(at: door.store.now()) else {
                return "code: ⌥⌘C copied something that is not the code"
            }
            door.clipboard.clear()
            panes.select(item: nil)
            return "code: ⌥⌘C copied the \(copied.count) digits that stand now"
        }
        return "code: found no login with a one-time code"
    }

    /// ⌘C and then ⇧⌘C again with the ninety seconds ahead of them, and the
    /// password up in Large Type: what the lock that follows has to undo.
    private static func copyAndShowLarge(_ door: Door) -> String {
        guard let panes = door.panes, choose(door) != nil else { return "found no login to copy from" }
        guard press("c", with: .command), panes.reading.copied == "username" else { return "⌘C copied no username" }
        guard press("c"), door.clipboard.isHolding else { return "⇧⌘C copied no password" }
        panes.showLargeType(of: ItemDetail.passwordRow)
        return panel.isUp ? "copied again, and large type is up" : "large type did not come up"
    }

    /// ⌘2 and then ⌘[ and ⌘] by their items in the menu bar, the table of
    /// keys up and down again on ⌘/, and a size larger and back on ⌘+ and
    /// ⌘0. It leaves the window on All Items at the actual size.
    private static func keys(_ door: Door) -> String {
        guard let panes = door.panes else { return "no panes for the keys" }
        _ = press(.allItems)
        guard press(.vaults), panes.selection != .allItems else { return "⌘2 chose no vault" }
        let vault = panes.selection
        guard press(.back), panes.selection == .allItems else { return "⌘[ did not go back" }
        guard press(.forward), panes.selection == vault else { return "⌘] did not go forward" }
        _ = press(.allItems)
        guard press(.shortcuts), panes.showsKeys else { return "⌘/ raised no sheet" }
        // The sheet has each key where the menu bar has it.
        let bar = NSApp.mainMenu
        guard panes.keyCommands.allSatisfy({ command in
            command.bound != .menu || command.strokes.indices.allSatisfy {
                KeyTable.item(command.id, stroke: $0, in: bar)?.keyEquivalent == command.strokes[$0].key
            }
        }) else { return "the sheet has a key the menu bar does not" }
        let moved = panes.keyCommands.filter { $0.strokes != KeyTable[$0.id].strokes }.count
        guard press(.shortcuts), !panes.showsKeys else { return "⌘/ did not put the sheet away" }
        guard press(.zoomIn), door.zoom == .large else { return "⌘+ did not zoom in" }
        guard press(.actualSize), door.zoom == .actual else { return "⌘0 did not zoom back" }
        return "keys: back, forward, the sheet and the sizes, \(moved) moved by the keyboard"
    }

    /// ⌘F by its key, a title typed without its dots and cedillas, and then
    /// a password typed whole, which finds nothing because no password is in
    /// the index. The query is cleared the way Esc clears it.
    private static func search(_ door: Door) async -> String {
        guard let panes = door.panes else { return "no panes to search" }
        await door.store.indexing?.value
        let asked = panes.keysToSearch
        guard press("f", with: .command), panes.keysToSearch == asked + 1 else {
            return "⌘F did not reach the search field"
        }
        panes.query = "is bankasi"
        let found = panes.list.entries.count
        guard found > 0 else { return "search found no title" }
        panes.query = DemoVault.shared
        guard panes.list.isEmpty else { return "search found a password" }
        guard panes.dismiss(), panes.query.isEmpty, !panes.list.isEmpty else { return "Esc did not clear the search" }
        return "searched, found \(found) by a title and nothing by a password"
    }

    /// The mark's menu, a click on the mark, and the app with no window: the
    /// Dock switch is turned off, the main window and a window of one item
    /// are closed in turn, and the app is still there. The key raises Quick
    /// Access over nothing, and Open from the mark's menu brings the window
    /// and the Dock icon back.
    private static func menuBar(_ bar: Bar, _ door: Door, _ quick: QuickAccess) async -> String {
        guard bar.mark.isShowing else { return "the mark is not in the menu bar" }
        let menu = bar.menu.menu()
        let titles = menu.items.map(\.title)
        guard titles == ["Open \(AppInfo.name)", "Open Quick Access", "", "Lock", "Settings", "Quit"],
              bar.menu.rows()[1].caps == keys[.quickAccess]?.caps, menu.items[3].isEnabled, menu.items[4].isEnabled,
              menu.items[5].action == #selector(NSApplication.terminate(_:)) else {
            return "the mark's menu has \(titles), quick access on \(bar.menu.rows()[1].caps), lock "
                + "\(menu.items[3].isEnabled), settings \(menu.items[4].isEnabled)"
        }
        bar.mark.performClick()
        let raised = quick.isUp
        bar.mark.performClick()
        guard raised, !quick.isUp else { return "a click on the mark did not raise and put away Quick Access" }

        guard let panes = door.panes, choose(door) != nil, press("o", with: .command),
              let item = panes.windows?.windows.first else { return "no window of one item to close" }
        door.preferences.settings.menuBar.keepsDock = false
        let asked = bar.presence.lastWindowClosings
        bar.window.close()
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard NSApp.activationPolicy() == .regular, bar.presence.lastWindowClosings == asked else {
            return "the Dock icon went, or AppKit asked to quit, with a window of one item still open"
        }
        item.performClose(nil)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let closings = bar.presence.lastWindowClosings - asked
        guard closings > 0, !Presence.appHasWindow(), NSApp.activationPolicy() == .accessory else {
            return "with every window closed AppKit asked \(closings) times and the policy is "
                + "\(NSApp.activationPolicy().rawValue)"
        }
        let pressed = HotKeys.press(.quickAccess) == noErr && quick.isUp && quick.panel.isVisible
        quick.close()
        guard pressed else { return "the hot key raised nothing with every window closed" }

        menu.performActionForItem(at: 0)
        guard bar.window.isVisible, NSApp.activationPolicy() == .regular else {
            return "Open \(AppInfo.name) brought back no window, or no Dock icon"
        }
        door.preferences.settings.menuBar.keepsDock = true
        return "the mark: \(titles.count - 1) rows, a click raised quick access; with every window closed AppKit "
            + "asked \(closings) times and the Dock icon went, the hot key raised quick access, and "
            + "Open \(AppInfo.name) brought the window and the Dock icon back"
    }

    /// ⌘, by the one item of the menu bar that is on it, which is the
    /// scene's and ends at the delegate. The window comes up, every room is
    /// drawn in it, and it is put away.
    private static func settings(_ settings: SettingsCommands) async -> String {
        // By its name: on a keyboard that is not American AppKit moves the
        // key, as it does ⌘[, and on this Mac's it is drawn as ⌘Ö.
        let app = NSApp.mainMenu?.items.first?.submenu?.items ?? []
        let named = app.filter { $0.title == "Settings…" }
        guard named.count == 1, let item = named.first, let action = item.action,
              !item.keyEquivalent.isEmpty, item.keyEquivalentModifierMask == .command else {
            return "settings: \(named.count) items of the app's menu are Settings, on ⌘\(named.first?.keyEquivalent ?? "")"
        }
        if let validator = item.target as? NSMenuItemValidation, !validator.validateMenuItem(item) {
            return "settings: the menu's item is grey"
        }
        guard NSApp.sendAction(action, to: item.target, from: item), let window = settings.window,
              window.isVisible else {
            return "settings: ⌘, raised no window"
        }
        var drawn = 0
        for room in Room.allCases {
            settings.rooms.room = room
            try? await Task.sleep(nanoseconds: 50_000_000)
            await settings.rooms.looking?.value
            window.displayIfNeeded()
            if settings.rooms.room == room { drawn += 1 }
        }
        settings.rooms.room = .general
        window.performClose(nil)
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard !window.isVisible else { return "settings: the window did not close" }
        return "settings: ⌘, raised the window, \(drawn) rooms were drawn and it was put away"
    }

    /// A login in a window of its own by ⌘O, a copy of it made and opened in
    /// a second, and the copy deleted by ⌘Delete: two windows with a
    /// password under their dots and one more item holding it, which is
    /// what the lock that follows has to put away.
    private static func change(_ door: Door) async -> String {
        guard let panes = door.panes, let detail = choose(door) else { return "found no login to change" }
        guard press("o", with: .command), panes.windows?.windows.count == 1 else { return "⌘O opened no window" }
        panes.perform(.duplicate)
        await panes.writing?.value
        guard let copy = panes.selectedItem?.item, copy.id != detail.id,
              copy.login?.password == detail.value(of: ItemDetail.passwordRow) else {
            return "the copy was not made and chosen"
        }
        guard press("o", with: .command), panes.windows?.windows.count == 2 else {
            return "⌘O opened no window on the copy"
        }
        guard press("\u{8}", with: .command) else { return "⌘Delete was not in the menu" }
        await (panes.windows?.inFront ?? panes).writing?.value
        guard door.store.shelves.trash.contains(where: { $0.id == copy.id }) else {
            return "⌘Delete did not delete the copy"
        }
        return "changed: a copy made and deleted, and 2 windows are up"
    }

    /// `OP_LEAK` puts one canary where it must never be, so the search can be
    /// seen to find it. Debug builds only.
    /// ⌘E on a login, a password typed over its own, and ⌘S: the engine has
    /// the new one, and the old one first among the earlier ones. Then ⌘E
    /// again and Esc, which has nothing to ask about.
    private static func edit(_ door: Door) async -> String {
        guard let panes = door.panes, let detail = choose(door),
              let old = detail.value(of: ItemDetail.passwordRow) else { return "found no login to edit" }
        guard press(.edit), let editor = panes.editor else { return "⌘E opened no form" }
        editor.form.password = DemoVault.typed
        guard press(.save) else { return "⌘S was not in the menu" }
        await panes.writing?.value
        guard panes.editor == nil, let saved = door.store.entry(id: detail.id)?.item,
              saved.login?.password == DemoVault.typed, saved.passwordHistory.first?.password == old else {
            return "⌘S did not save the password and keep the old one"
        }
        guard press(.edit), panes.editor != nil, panes.dismiss(), panes.editor == nil else {
            return "Esc did not put an unchanged form away"
        }
        return "edited: a password saved, the old one kept, and an unchanged form put away"
    }

    /// ⌘E and ⌘S on one item of each of the other four types: a code
    /// typed into a card, an address into an identity, a line into a note,
    /// and a whole key pasted over a key's.
    private static func editOthers(_ door: Door) async -> String {
        guard let panes = door.panes else { return "no panes to edit in" }
        let changes: [(ItemType, (Editor) -> Void, (Item) -> Bool)] = [
            (.card, { $0.form.card.code = DemoVault.typedCode }, { item in
                if case .card(let card) = item.payload { return card.code == DemoVault.typedCode }
                return false
            }),
            (.identity, { $0.form.identity[.email] = "tour@\(DemoVault.usernameDomain)" }, { item in
                if case .identity(let identity) = item.payload {
                    return identity[.email] == "tour@\(DemoVault.usernameDomain)"
                }
                return false
            }),
            (.secureNote, { $0.form.notes += "\n\(DemoVault.note) tur." }, { $0.notes?.hasSuffix("tur.") == true }),
            (.sshKey, { $0.replaceKey(with: DemoVault.pastedKey) }, { item in
                if case .sshKey(let key) = item.payload { return key.privateKey == DemoVault.pastedKey }
                return false
            }),
        ]
        for (type, change, isSaved) in changes {
            // Not the key the agent signs with later on, which an invented
            // file pasted over it would leave with nothing to sign.
            guard let entry = panes.list.entries.first(where: { $0.item.type == type && $0.item.name != DemoVault.agentKeyName }) else {
                return "found no item of type \(type.rawValue) to edit"
            }
            panes.select(item: entry.id)
            guard press(.edit), let editor = panes.editor else { return "⌘E opened no form for type \(type.rawValue)" }
            change(editor)
            guard press(.save) else { return "⌘S was not in the menu for type \(type.rawValue)" }
            await panes.writing?.value
            guard panes.editor == nil, let saved = door.store.entry(id: entry.id)?.item, isSaved(saved) else {
                return "⌘S did not save type \(type.rawValue)"
            }
        }
        return "edited the others: a card, an identity, a note and a key saved"
    }

    /// ⌘N, the login's tile, a title and a password typed into the empty
    /// form, and ⌘S: the engine has one item more, and the list is on it.
    private static func makeNew(_ door: Door) async -> String {
        guard let panes = door.panes else { return "no panes to make an item in" }
        guard press(.newItem), panes.choosing != nil else { return "⌘N raised no sheet" }
        await panes.make(.login)?.value
        guard let editor = panes.editor, editor.isNew else { return "the login's tile opened no form" }
        editor.form.title = "Kanarya Kitabevi"
        editor.form.password = DemoVault.made
        let count = door.store.shelves.all.count
        guard press(.save) else { return "⌘S was not in the menu for a new item" }
        await panes.writing?.value
        guard panes.editor == nil, door.store.shelves.all.count == count + 1,
              panes.selectedItem?.item.login?.password == DemoVault.made else {
            return "⌘S did not make the login"
        }
        return "made: a new login saved, and the list is on it"
    }

    /// Password Generator in the Item menu: a password of each kind made,
    /// the PIN at its longest, none of them put in a field or copied, and
    /// Esc. The controls are left as they first stood.
    private static func generate(_ door: Door) async -> String {
        let items = (NSApp.mainMenu?.items ?? []).compactMap { $0.submenu?.items }.joined()
        guard let panes = door.panes, let item = items.first(where: { $0.title == "Password Generator…" }),
              let action = item.action, NSApp.sendAction(action, to: item.target, from: item),
              let generator = panes.generator else { return "the menu raised no generator" }
        let first = generator.settings
        var changes = [first, first, first, first]
        changes[1].kind = .memorable
        changes[1].capitals = true
        changes[2].kind = .memorable
        changes[3].kind = .pin
        changes[3].pinDigits = GeneratorSettings.pinLengths.upperBound
        for settings in changes + [first] {
            if generator.settings != settings { generator.settings = settings }
            await generator.asking?.value
            guard generator.password == DemoVault.generated(settings.recipe), generator.strength != nil else {
                return "the generator made no \(settings.kind.rawValue) password"
            }
        }
        guard panes.dismiss(), panes.generator == nil, generator.password.isEmpty else {
            return "Esc did not put the generator away"
        }
        return "generated: a password of each kind made, none used, and the card put away"
    }

    /// The password row's menu on a login with earlier passwords: View
    /// password history, one of the three spelled out and one copied with its
    /// marker, and Esc. The copy is cleared by the delay, cut short.
    private static func history(_ door: Door) async -> String {
        guard let panes = door.panes, let detail = choose(door), detail.item.passwordHistory.count > 1 else {
            return "found no login with earlier passwords"
        }
        panes.toggleMenu(for: ItemDetail.passwordRow)
        guard panes.reading.menu?.actions.contains(.history) == true else { return "the password's menu had no history" }
        panes.perform(.history, on: ItemDetail.passwordRow)
        guard let sheet = panes.reading.history, sheet.entries.count == detail.item.passwordHistory.count else {
            return "the menu raised no sheet"
        }
        panes.toggleRevealed(historyEntry: 1)
        door.clipboard.delay = 0.4
        defer { door.clipboard.delay = nil }
        guard panes.copy(historyEntry: 0), NSPasteboard.general.string(forType: .string) == sheet.entries[0].password,
              NSPasteboard.general.types?.contains(Clipboard.concealed) == true else {
            return "a copy from the sheet was not marked"
        }
        await door.clipboard.clearing?.value
        guard !door.clipboard.isHolding, NSPasteboard.general.string(forType: .string) == nil else {
            return "the copy from the sheet was still there after the delay"
        }
        guard panes.dismiss(), panes.reading.history == nil else { return "Esc did not put the sheet away" }
        return "history: \(sheet.entries.count) earlier passwords, one shown and one copied, and the sheet put away"
    }

    /// The note with a file: its row clicked, the engine's copy read from
    /// the private directory under Quick Look, and the preview closed, which
    /// deletes it.
    private static func attachment(_ door: Door) async -> String {
        guard let panes = door.panes, let desk = door.desk,
              let entry = panes.list.entries.first(where: { !$0.item.attachments.isEmpty }) else {
            return "found no item with an attachment"
        }
        panes.select(item: entry.id)
        guard let row = panes.detail?.attachments.first?.id, panes.actions(for: row) == [.quickLook, .saveAs] else {
            return "the attachment had no row"
        }
        await panes.openAttachment(row)?.value
        guard let copy = preview.showing, preview.isUp, preview.isPreviewing(copy),
              desk.copies.held.map(\.lastPathComponent) == [copy.lastPathComponent],
              (try? Data(contentsOf: copy)) == DemoVault.attachmentBodies[entry.item.attachments[0].id],
              (try? String(contentsOf: copy, encoding: .utf8))?.contains(DemoVault.attached) == true else {
            return "the attachment was not fetched and shown (\(desk.copies.held.count) files, up \(preview.isUp))"
        }
        let mode = (try? FileManager.default.attributesOfItem(atPath: attachments.path))?[.posixPermissions] as? Int
        guard mode == 0o700 else { return "the attachments' directory is not private" }
        preview.close()
        guard !preview.isUp, desk.copies.held.isEmpty else { return "the copy outlived its preview" }
        return "attachment: fetched and shown, and gone when the preview closed"
    }

    /// The same file again, from a window of the note's own, and left
    /// open: a decrypted file on disk and a panel reading it, for the lock.
    private static func leaveAttachment(_ door: Door) async -> Bool {
        guard let panes = door.panes, let desk = door.desk,
              let entry = door.store.shelves.all.first(where: { !$0.item.attachments.isEmpty }),
              panes.windows?.open(entry.id, from: panes) != nil,
              let own = panes.windows?.panes(showing: entry.id),
              let row = own.detail?.attachments.first?.id else { return false }
        await own.openAttachment(row)?.value
        return preview.isUp && desk.copies.held.count == 1
    }

    private static func leaveEditing(_ door: Door) -> String {
        guard let panes = door.panes, press(.edit), let editor = panes.editor else { return "⌘E opened no form" }
        editor.form.password = DemoVault.unsaved
        // Another item is no way out of it.
        panes.moveSelection(by: 1)
        guard panes.editor === editor, panes.isAskingToDiscard else { return "the form let itself be left" }
        panes.dismiss()
        return "a form is open with a password typed into it"
    }

    private static func leakOnPurpose() {
        #if DEBUG
        let canary = DemoVault.shared
        switch ProcessInfo.processInfo.environment["OP_LEAK"] {
        case "log":
            Log.app.error("leaked on purpose: \(canary, privacy: .public)")
        case "defaults":
            UserDefaults.standard.set(canary, forKey: "leakedOnPurpose")
            UserDefaults.standard.synchronize()
        case "tmp":
            try? canary.write(to: FileManager.default.temporaryDirectory
                .appendingPathComponent("oripass-leaked-on-purpose.txt"),
                atomically: true, encoding: .utf8)
        case "pasteboard":
            // Not through `Clipboard`, so it is nobody's to clear.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(canary, forType: .string)
        case "hash":
            // As a careless breach check would: the whole hash, in a file.
            let mark = BreachMark(canary)
            try? (mark.prefix + mark.suffix).lowercased().write(to: FileManager.default.temporaryDirectory
                .appendingPathComponent("oripass-leaked-on-purpose.txt"),
                atomically: true, encoding: .utf8)
        case "seal":
            // The password the seal holds, beside it and not sealed.
            try? Data(DemoVault.tourPassword.utf8)
                .write(to: sealDirectory.appendingPathComponent("leaked-on-purpose"))
        default:
            break
        }
        #endif
    }
}

/// OP-3's proof, kept runnable: `OP_DEMO=seal` seals thirty-two random bytes
/// into `OP_SEAL_DIR` and exits, and `OP_DEMO=unseal` in a later process, or a
/// later build, asks for a finger and prints "match" when they come back the
/// same. Two processes because the question is whether a second one may ask.
enum DemoSeal {
    private static var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["OP_SEAL_DIR"]
            ?? NSTemporaryDirectory()).appendingPathComponent("oripass-demo-seal")
    }

    static func run(_ choice: String) -> Never {
        do {
            if choice == "seal" {
                let secret = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
                let sealed = try EnclaveSeal.seal(secret)
                try FileManager.default.createDirectory(at: directory,
                                                        withIntermediateDirectories: true)
                try sealed.key.write(to: directory.appendingPathComponent("key"))
                try sealed.encapsulated.write(to: directory.appendingPathComponent("encapsulated"))
                try sealed.box.write(to: directory.appendingPathComponent("box"))
                try secret.write(to: directory.appendingPathComponent("expected"))
                print("sealed")
            } else {
                let sealed = EnclaveSeal(
                    key: try Data(contentsOf: directory.appendingPathComponent("key")),
                    encapsulated: try Data(contentsOf: directory.appendingPathComponent("encapsulated")),
                    box: try Data(contentsOf: directory.appendingPathComponent("box"))
                )
                let expected = try Data(contentsOf: directory.appendingPathComponent("expected"))
                print(try sealed.open(reason: "unlock OriPass") == expected ? "match" : "differ")
            }
            exit(0)
        } catch {
            print("failed: \((error as NSError).domain) \((error as NSError).code)")
            exit(1)
        }
    }
}

/// `OP_DEMO=child` starts the `bw` named by `OP_CHILD_BW` in the run directory
/// `OP_CHILD_RUN`, says "ready" and its pid, and then does nothing for ever.
/// `BwChildTests` kills this process with `SIGKILL` and watches the child go
/// with it, which cannot be shown from inside the process being killed.
enum DemoChild {
    static func run() -> Never {
        let environment = ProcessInfo.processInfo.environment
        guard let binary = environment["OP_CHILD_BW"], let run = environment["OP_CHILD_RUN"] else {
            exit(2)
        }
        let directory = URL(fileURLWithPath: run)
        let child = BwChild(binary: URL(fileURLWithPath: binary), runDirectory: directory,
                            dataDirectory: directory.appendingPathComponent("data"))
        Task.detached {
            do {
                try await child.start()
                FileHandle.standardOutput.write(Data("ready \(child.pid ?? 0)\n".utf8))
            } catch {
                exit(1)
            }
        }
        dispatchMain()
    }
}
