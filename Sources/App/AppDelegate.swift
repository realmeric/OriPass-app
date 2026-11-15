import AppKit
import CryptoKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var window: NSWindow?
    private var store: VaultStore?
    private var door: Door?
    private var lockPolicy: LockPolicy?
    private var syncPolicy: SyncPolicy?
    /// Held for the menu items' target, which a menu does not retain.
    private var lockCommands: LockCommands?
    private var windowCommands: WindowCommands?
    private var itemCommands: ItemCommands?
    /// Made at launch and kept, so that showing it is ordering it in (D18).
    private var quickAccess: QuickAccess?
    /// Registered for as long as the app runs, locked or not. The tour's are
    /// on combinations no keyboard has (`DemoTour.keys`), so the canary runs
    /// with the keys held as the app holds them and takes none from
    /// whatever else is on this Mac.
    private var hotKeys: HotKeys?
    /// The mark in the menu bar, and the menu it drops. Locked or not the
    /// mark stays: it is how the app is reached with no window open.
    private var statusItem: StatusItem?
    private var menuBar: MarkMenu?
    /// Whether the app is in the Dock, which follows from whether a window
    /// is open and from the switch that says what to do when none is.
    private var presence: Presence?
    /// Every choice, and what makes the standing things agree with one that
    /// has changed.
    private var preferences: Preferences?
    private var following: Following?
    /// The settings window and ⌘,.
    private var settingsCommands: SettingsCommands?
    /// Open while the vault is, for the extension in a browser.
    private var browserDoor: BrowserDoor?
    private var passkeyOffer: PasskeyOffer?
    /// Signs for ssh, and stands while the vault is shut with its switch on.
    private var agent: SSHAgent?

    /// The unit test bundle is hosted by this app, so `xcodebuild test` runs
    /// `applicationDidFinishLaunching` for real. Without this guard every test
    /// run would put a window on screen and, later, start a child.
    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// `bw`, behind the app that is not a demo, with whatever child the
    /// last run of the app left killed before anything else is asked of it.
    private static func engine(_ preferences: Preferences) -> ServeBackend {
        let backend = ServeBackend(finder: preferences.bwFinder)
        backend.clearLeftovers()
        return backend
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningTests else { return }

        if Demo.choice == "seal" || Demo.choice == "unseal" { DemoSeal.run(Demo.choice) }

        if Demo.choice == "contrast" { Contrast.run() }

        if Demo.choice == "shots" {
            // Nothing is shown, so nothing should bounce in the Dock either.
            NSApp.setActivationPolicy(.accessory)
            Task { await Shots.run() }
            return
        }

        if Demo.choice == "scroll" {
            Task { await ScrollTrace.run() }
            return
        }

        if Demo.choice == "quick" {
            Task { await QuickTrace.run() }
            return
        }

        if Demo.choice == "type" {
            Task { await TypeTrace.run() }
            return
        }

        Log.app.info(
            "launched \(AppInfo.name, privacy: .public) \(AppInfo.version, privacy: .public)"
        )

        // The tour's choices are emptied each time it starts, and the demo's
        // are its own, so an answer given to the demo is not the app's.
        let defaults: UserDefaults = Demo.choice == "tour" ? DemoTour.defaults : Demo.isOn ? Demo.defaults : .standard
        if Demo.choice == "tour" { DemoTour.forgetChoices() }
        let preferences = Preferences(defaults: defaults)
        self.preferences = preferences

        // The demo's vault is invented and held in memory. Everything else is
        // `bw` (D4).
        // And the demo's breach check and list of two-factor sites ask
        // nobody, so they are on; the real ones are off until their
        // switches are (D13).
        let store = Demo.isOn
            ? VaultStore(backend: Demo.choice == "tour" ? DemoVault.backend(password: DemoVault.tourPassword)
                                                         : DemoVault.backend(),
                         breaches: DemoBreaches.checker(),
                         twoFactor: DemoTwoFactor.checker())
            : VaultStore(backend: Self.engine(preferences),
                         breaches: Breaches.standard(preferences), twoFactor: TwoFactorCheck.standard(preferences))
        self.store = store
        let door: Door
        // An item that asks is answered for with a finger while the
        // password is sealed, and with the master password in a panel
        // otherwise.
        if Demo.choice == "tour" {
            door = DemoTour.door(over: store, preferences: preferences)
        } else if Demo.isOn {
            // The demo's enclave key is a real one and its password is
            // "demo": a seal left by the last run is not worth a sheet.
            try? FileManager.default.removeItem(at: AppPaths.demoSeal)
            let seal = PasswordSeal(directory: AppPaths.demoSeal, lifetime: { preferences.now.lock.fingerLifetime })
            let asker = OwnerCheck(store: store, seal: seal, stage: PasswordPanel())
            door = Door(store: store, seal: seal,
                        defaults: defaults, preferences: preferences, icons: DemoIcons.store,
                        clipboard: Clipboard(pasteboard: .general, choices: { preferences.settings.clipboard }),
                        stage: LargeTypePanel(),
                        present: { $0.makeKeyAndOrderFront(nil) },
                        desk: AttachmentDesk(copies: OpenCopies(directory: AppPaths.demoAttachments),
                                             stage: QuickLookPanel(), panels: SystemFilePanels()),
                        reprompt: Reprompt(store: store, authoriser: asker),
                        armedFill: ArmedFill(sites: SystemSites()))
        } else {
            let seal = PasswordSeal(lifetime: { preferences.now.lock.fingerLifetime })
            let asker = OwnerCheck(store: store, seal: seal, stage: PasswordPanel())
            door = Door(store: store, seal: seal, signIn: BwSignIn(finder: preferences.bwFinder),
                        defaults: defaults, preferences: preferences,
                        icons: { IconStore.standard(preferences) },
                        clipboard: Clipboard(pasteboard: .general, choices: { preferences.settings.clipboard }),
                        stage: LargeTypePanel(),
                        present: { $0.makeKeyAndOrderFront(nil) },
                        desk: AttachmentDesk(copies: OpenCopies(directory: AppPaths.attachments),
                                             stage: QuickLookPanel(), panels: SystemFilePanels()),
                        reprompt: Reprompt(store: store, authoriser: asker),
                        armedFill: ArmedFill(sites: SystemSites()), accountFiles: [AppPaths.icons])
        }
        // A copy of an attachment that a crash or a kill left behind: the
        // app that wrote it is not there to delete it, so this one does,
        // before anything else (D6).
        door.desk?.copies.removeAll()
        // And the door's file, from a run that was killed with its vault
        // open: a locked app has none.
        if let bridge = AppPaths.bridge { try? FileManager.default.removeItem(at: bridge) }
        self.door = door
        if Demo.choice != "tour" { door.restoreZoom() }
        // The tour's is the real one at the real path, with the real card,
        // which it asks through as a host would.
        if let reprompt = door.reprompt {
            browserDoor = BrowserDoor(store: store, reprompt: reprompt, preferences: preferences,
                                      stage: BrowserPanel(), path: AppPaths.bridge,
                                      newKey: Demo.isOn ? DemoVault.newPasskeyKey : { P256.Signing.PrivateKey() },
                                      front: Demo.choice == "tour" ? { DemoTour.front } : FrontApp.behindTheSheet,
                                      tabs: Demo.choice == "tour" ? DemoTour.Tab() : AppleEventTabs(),
                                      icons: Demo.isOn ? DemoIcons.png : IconCache.standard(preferences),
                                      generator: { GeneratorSettings(defaults) })
        }
        // A demo's passkeys are nobody's, and the system's list is his.
        if !Demo.isOn { passkeyOffer = PasskeyOffer(store: store, preferences: preferences, list: SystemIdentityList()) }
        // Off, a killed run's file is taken away, or a client would find a
        // socket nobody answers. On, opening it takes the path anyway.
        let agentPath = Demo.isOn ? AppPaths.demoAgent : AppPaths.agent
        if !preferences.settings.ssh.isOn { try? FileManager.default.removeItem(at: agentPath) }
        // A killed run's file is taken away: the door stands only while a
        // pass does, and none has outlived the run.
        let phonePath = Demo.isOn ? AppPaths.demoApprove : AppPaths.approve
        try? FileManager.default.removeItem(at: phonePath)
        let agent = SSHAgent(door: door, authoriser: door.reprompt?.authoriser,
                             stage: Demo.choice == "tour" ? nil : AgentPanel(), path: agentPath, phonePath: phonePath)
        self.agent = agent
        if !Demo.isOn { door.passes.knownHosts = { KnownHosts.read(AppPaths.knownHosts) } }
        lockPolicy = LockPolicy(store: store, preferences: preferences)
        syncPolicy = SyncPolicy(store: store)
        // The demo's ids are the same on every Mac and are kept in no
        // file. The tour's file is where the canary's search reads.
        let recents = Demo.choice == "tour" ? DemoTour.recents : Demo.isOn ? nil : AppPaths.recents
        // The tour is told what is in front and asks no browser anything:
        // an Apple Event from it would raise the system's question on
        // whatever Mac the canary runs on.
        // Nor does it post a key or ask macOS for anything: its typist has a
        // sink that keeps what it was sent.
        let quickAccess = Demo.choice == "tour"
            ? QuickAccess(door: door, recents: Recents(file: recents), front: { DemoTour.front },
                          tabs: DemoTour.Tab(), typist: DemoTour.typist, settings: defaults,
                          present: DemoTour.present)
            : QuickAccess(door: door, recents: Recents(file: recents), front: FrontApp.now, tabs: AppleEventTabs(),
                          typist: Typist(access: SystemAccessibility(), ground: SystemForeground(),
                                         sink: EventKeys()),
                          settings: defaults, voice: SystemVoice())
        // Read now and on another thread, so the first press of the key
        // does not wait for ten thousand rules.
        Task.detached(priority: .utility) { _ = PublicSuffix.standard.count }
        self.quickAccess = quickAccess
        let commands = LockCommands(door: door)
        lockCommands = commands
        let viewCommands = WindowCommands(door: door)
        windowCommands = viewCommands
        // The tour's window stays behind whatever is on the screen and
        // never has the keys, and the tour sends the menu's actions itself.
        let itemCommands = ItemCommands(door: door, mainHasKeys: { [weak self] in
            Demo.choice == "tour" || self?.window?.isKeyWindow == true
        })
        self.itemCommands = itemCommands
        if let mainMenu = NSApp.mainMenu {
            // View first and Item after it, so that Vault lands between
            // them and Window.
            viewCommands.install(in: mainMenu)
            itemCommands.install(in: mainMenu)
            commands.install(in: mainMenu)
        }

        let presence = Presence(choices: { preferences.settings.menuBar })
        self.presence = presence

        let window = MainWindow.make(remembersFrameAs: MainWindow.frameName)
        window.contentView = NSHostingView(rootView: DoorView(door: door))
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        let isTour = Demo.choice == "tour"
        let keys = startHotKeys(isTour ? DemoTour.keys : preferences.settings.shortcuts.all, saysRefusals: !isTour,
                                door: door, quick: quickAccess, lock: commands)

        // The demo and the tour change nothing outside themselves: no login
        // item is registered for a build that is not the installed one, and
        // nothing is asked of the system about a grant.
        let typist = quickAccess.typist
        let hands = Demo.isOn
            ? Rooms.Hands(access: typist?.access ?? FakeAccessibility(isTrusted: false),
                          refusedKeys: { [weak keys] in keys?.refused ?? [:] },
                          agentProblem: { [weak agent] in agent?.problem },
                          passKeys: { [weak agent] in agent?.passKeys ?? [] },
                          passApps: { await PassApp.signed(PassApp.running) },
                          hasFinger: { [weak door] in door?.reprompt?.authoriser.hasFinger == true },
                          givePass: { [weak agent] in await agent?.give(to: $0, for: $1) ?? false },
                          waitForPhone: { [weak agent] in await agent?.phones.waitForPhone() ?? false },
                          stopWaitingForPhone: { [weak agent] in agent?.phones.stopWaiting() })
            : Rooms.Hands(loginItem: SystemLoginItem(), access: typist?.access ?? SystemAccessibility(),
                          automation: SystemAutomation(), refusedKeys: { [weak keys] in keys?.refused ?? [:] },
                          engine: {
                              try? await BwBinary.locate(preferred: preferences.now.engine.bwPath,
                                                         dataDirectory: AppPaths.bwData)
                          },
                          open: { NSWorkspace.shared.open($0) },
                          agentProblem: { [weak agent] in agent?.problem },
                          hasOrion: { BrowserHosts().hasOrion },
                          passKeys: { [weak agent] in agent?.passKeys ?? [] },
                          passApps: { await PassApp.signed(PassApp.running) },
                          hasFinger: { [weak door] in door?.reprompt?.authoriser.hasFinger == true },
                          givePass: { [weak agent] in await agent?.give(to: $0, for: $1) ?? false },
                          waitForPhone: { [weak agent] in await agent?.phones.waitForPhone() ?? false },
                          stopWaitingForPhone: { [weak agent] in agent?.phones.stopWaiting() })
        let settings = SettingsCommands(rooms: Rooms(door: door, hands: hands), present: { window in
            // The tour's windows stay behind whatever is on the screen.
            if isTour { window.orderFront(nil) } else {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }, willShow: { [weak presence] in presence?.willShowWindow() },
           didClose: { [weak presence] in presence?.windowClosed() })
        settingsCommands = settings
        door.showSettings = { [weak settings] in settings?.show() }

        let menuBar = MarkMenu(door: door, quick: quickAccess, lock: commands, showApp: { [weak self] in
            self?.showAppWindow()
        }, showSettings: { [weak settings] in settings?.show() },
           quickKey: { [weak keys] in keys?.bound[.quickAccess] })
        self.menuBar = menuBar
        let mark = StatusItem(click: { [weak menuBar] in menuBar?.clickOnMark() },
                              menu: { [weak menuBar] in menuBar?.menu() ?? NSMenu() })
        statusItem = mark
        // The tour's keys are on combinations no keyboard has, and stay
        // there whatever its settings say. It turns Orion's switch on to
        // be let through the door, and tells this Mac's Orion nothing.
        following = Following(preferences, hands: .init(
            showMark: { [weak mark] in $0 ? mark?.show() : mark?.hide() },
            updatePresence: { [weak presence] in presence?.update() },
            applyKeys: { [weak keys] in if !isTour { keys?.apply($0) } },
            setAppearance: { NSApp.appearance = $0 },
            setDensity: { [weak door] in door?.density(to: $0) },
            recount: { [weak store] in store?.recount() },
            followHost: { if !isTour { BrowserHosts().follow($0) } },
            followAgent: { [weak agent] in agent?.follow($0) }))

        if isTour {
            let bar = DemoTour.Bar(menu: menuBar, mark: mark, presence: presence, window: window, settings: settings)
            let browser = browserDoor
            Task { await DemoTour.run(door: door, quick: quickAccess, hotKeys: keys, bar: bar, agent: agent, browser: browser) }
        } else {
            Task {
                await store.refresh()
                door.lockScreenAppeared()
                // What `scripts/release.sh` waits for before it installs a
                // build, and again once the copy in /Applications is up.
                let held = door.panes == nil ? "lock screen" : "panes"
                let shown = window.isVisible ? "on screen" : "not shown"
                Log.app.notice("door: \(held, privacy: .public) up, window \(shown, privacy: .public)")
            }
        }
    }

    /// The keys that work from any app. One that another app already holds
    /// is said so on the screen, once, and not lost without a word.
    @discardableResult
    private func startHotKeys(_ wanted: [HotKeyAction: HotKey], saysRefusals: Bool,
                              door: Door, quick: QuickAccess, lock: LockCommands) -> HotKeys {
        let showApp: () -> Void = { [weak self] in self?.showAppWindow() }
        let actions = HotKeyActions(quick: quick, door: door, lock: lock, showApp: showApp)
        // The tour's windows stay behind whatever is on the screen.
        if saysRefusals {
            quick.showApp = showApp
            quick.activate = { [weak self] in
                // A window of one item is no less a window than the main one.
                self?.presence?.willShowWindow()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        let keys = HotKeys()
        keys.onFire = { actions.perform($0) }
        hotKeys = keys
        let refused = keys.apply(wanted)
        guard saysRefusals, let sentence = HotKeys.report(refused, asked: wanted) else { return keys }
        let alert = NSAlert()
        alert.messageText = "A key could not be taken"
        alert.informativeText = sentence + "\n\nAnother app holds it. Quit that app and open \(AppInfo.name) again, "
            + "or the key will do nothing."
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) { _ in } } else { alert.runModal() }
        return keys
    }

    /// The main window, brought back from wherever it is: closed, behind
    /// another app, or with the Dock icon gone because it was.
    private func showAppWindow() {
        guard let window else { return }
        presence?.willShowWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// The Edit menu's Copy, when it has come all the way down the chain:
    /// no field with a selection of its own took it, so it is the item's.
    @objc func copy(_ sender: Any?) {
        itemCommands?.copyPrimary()
    }

    /// ⌘, and the app menu's Settings, which the scene makes
    /// (`OriPassApp`). Locked or not: the settings are the app's.
    @objc func showSettings(_ sender: Any?) {
        settingsCommands?.show()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action != #selector(copy(_:)) || itemCommands?.canCopy == true
    }

    /// A window that is put away shows nothing when it comes back.
    func windowWillClose(_ notification: Notification) {
        door?.panes?.putAway()
        presence?.windowClosed()
    }

    /// The panel and the hot keys have to outlive the last window, so
    /// closing it is not quitting. Quit is in the menu, in the mark's menu
    /// and on ⌘Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        presence?.lastWindowClosed()
        return false
    }

    /// The Dock icon, clicked with no window open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showAppWindow() }
        return false
    }

    /// A lock screen that came up behind another app raises its Touch ID
    /// sheet now. And the two states that are left by doing something in a
    /// terminal: he comes back, and the window should already know.
    func applicationDidBecomeActive(_ notification: Notification) {
        door?.raiseFingerIfOwed()
        guard let store, store.state == .noCLI || store.state == .loggedOut else { return }
        Task { await store.refresh() }
    }

    /// A socket left behind is one nobody answers.
    func applicationWillTerminate(_ notification: Notification) {
        agent?.end()
    }

    /// Quitting is a lock like any other, and the child is told to go
    /// before the process does, where otherwise it would find its
    /// connection ended and take two seconds more to leave by itself. With
    /// that switch off the vault is left as it is, and what was copied and
    /// what a preview was reading still go (`Door.quit`). Only an open
    /// vault has either: every other state has been through the door's
    /// sink, which takes both.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let door, let lockPolicy, store?.state == .unlocked else { return .terminateNow }
        Task {
            await door.quit(under: lockPolicy)
            await passkeyOffer?.quit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
