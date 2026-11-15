import Carbon.HIToolbox
import SwiftUI

/// The settings window (`docs/look.md`, "Settings"): the rooms down the
/// left, and the chosen room's rows at the right under its name.
struct RoomsView: View {
    @ObservedObject var rooms: Rooms
    @ObservedObject private var preferences: Preferences
    @ObservedObject private var door: Door
    @ObservedObject private var store: VaultStore
    @ObservedObject private var passes: AgentPasses

    init(rooms: Rooms) {
        self.rooms = rooms
        preferences = rooms.preferences
        door = rooms.door
        store = rooms.door.store
        passes = rooms.door.passes
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                list
                    .frame(width: Metrics.settingsSidebar)
                Hairline(.vertical, colour: Palette.divider)
                VStack(spacing: 0) {
                    HStack {
                        Text(rooms.room.title)
                            .font(Fonts.pageHeading)
                            .foregroundStyle(Palette.text)
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Metrics.loose)
                    .frame(height: Metrics.toolbarHeight)
                    Hairline(.horizontal)
                    ScrollView {
                        VStack(alignment: .leading, spacing: Metrics.wide) {
                            room
                        }
                        .frame(maxWidth: Metrics.settingsColumn, alignment: .leading)
                        .padding(.horizontal, Metrics.loose)
                        .padding(.vertical, Metrics.wide)
                        .frame(maxWidth: .infinity)
                    }
                }
                .background(Palette.content)
            }
            if rooms.isAskingToSignOut {
                SignOutQuestion(email: store.email ?? "", cancel: rooms.cancelSignOut,
                                signOut: { rooms.confirmSignOut() })
                    .transition(Motion.transition(.fade))
            }
        }
        // As the door's own view is: another size is every view made again.
        .id(door.zoom)
        .id(door.density)
        .ignoresSafeArea()
        .animation(Motion.animation(Motion.slide), value: rooms.isAskingToSignOut)
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Room.allCases) { room in
                let isChosen = rooms.room == room
                Button { rooms.room = room } label: {
                    HStack(spacing: Metrics.close) {
                        room.glyph.image
                            .font(Fonts.sidebarGlyph)
                            .foregroundStyle(isChosen ? Palette.accent : Palette.secondText)
                            .frame(width: Metrics.sidebarMark)
                        Text(room.title)
                            .font(Fonts.body)
                            .foregroundStyle(Palette.text)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Metrics.gap)
                    .frame(height: Metrics.sidebarRow)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                            .fill(isChosen ? Palette.sidebarSelection : Palette.sidebarSelection.opacity(0))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(room.title)
                .accessibilityAddTraits(isChosen ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.close)
        .padding(.top, Metrics.toolbarHeight + Metrics.close)
        .background(SidebarGround())
    }

    @ViewBuilder
    private var room: some View {
        switch rooms.room {
        case .general: general
        case .appearance: appearance
        case .security: security
        case .privacy: privacy
        case .filling: filling
        case .developer: developer
        case .account: account
        case .about: about
        }
    }

    private var settings: Binding<Settings> { $preferences.settings }

    // MARK: General

    @ViewBuilder
    private var general: some View {
        RoomGroup {
            RoomRow("Open \(AppInfo.name) at login", problem: rooms.loginProblem) {
                Switch(isOn: Binding { rooms.startsAtLogin } set: { rooms.setStartsAtLogin($0) },
                       name: "Open at login")
            }
            RoomRule()
            switchRow("menuBar.showsMark", "Show the mark in the menu bar", settings.menuBar.showsMark)
            RoomRule()
            // With no mark the Dock icon is all there is to click, and stays.
            switchRow("menuBar.keepsDock", "Keep the Dock icon when no window is open",
                      caption: preferences.settings.menuBar.showsMark
                          ? nil : "It stays while the mark is off, or there would be nothing to click.",
                      isOff: !preferences.settings.menuBar.showsMark, settings.menuBar.keepsDock)
        }
        RoomGroup("Keys that work from any app") {
            ForEach(HotKeyAction.allCases, id: \.self) { action in
                if action != HotKeyAction.allCases.first { RoomRule() }
                shortcut(action)
            }
        }
    }

    private func shortcut(_ action: HotKeyAction) -> some View {
        let key = rooms.key(for: action)
        return RoomRow(action.title, problem: rooms.keyProblems[action]) {
            HStack(spacing: Metrics.tight) {
                if rooms.isChanged(action) {
                    small(.restore, "Use the default for \(action.title)") { rooms.reset(action) }
                }
                if key != nil {
                    small(.clear, "Take the key from \(action.title)") { rooms.clear(action) }
                }
                HotKeyRecorder(words: key?.words ?? "") { rooms.record($0, for: action) }
                    .frame(width: Metrics.recorder.width, height: Metrics.recorder.height)
                    .accessibilityElement()
                    .accessibilityLabel("Key for \(action.title)")
                    .accessibilityValue(key?.words ?? "not set")
                    .accessibilityIdentifier("shortcuts.bound")
            }
        }
    }

    private func small(_ glyph: Glyph, _ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            glyph.image
                .font(Fonts.footGlyph)
                .foregroundStyle(Palette.faintText)
                .frame(width: Metrics.recorder.height, height: Metrics.recorder.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }

    // MARK: Appearance

    @ViewBuilder
    private var appearance: some View {
        RoomGroup {
            RoomRow("Theme") {
                Options(field: "look.theme", label: "Theme", values: Theme.allCases, word: \.word,
                        chosen: settings.look.theme)
            }
            RoomRule()
            RoomRow("Density") {
                Options(field: "look.density", label: "Density", values: Density.allCases, word: \.word,
                        each: Metrics.settingsWideSegment, chosen: settings.look.density)
            }
            RoomRule()
            RoomRow("Size", caption: "⌘+, ⌘- and ⌘0 move between the same three.") {
                Options(field: "look.zoom", label: "Size", values: Zoom.allCases, word: \.word,
                        chosen: Binding { door.zoom } set: { door.zoom(to: $0) })
            }
        }
    }

    // MARK: Security

    @ViewBuilder
    private var security: some View {
        RoomGroup {
            RoomRow("Unlock with Touch ID", caption: fingerCaption, isOff: !rooms.canUseFinger) {
                Switch(isOn: Binding { preferences.settings.lock.unlockWithFinger == true }
                       set: { rooms.setFinger($0) }, name: "Unlock with Touch ID")
                    .accessibilityIdentifier("lock.unlockWithFinger")
            }
            RoomRule()
            RoomRow("Ask for the password again after") {
                Options(field: "lock.fingerDays", label: "Days", values: Room.fingerDays,
                        word: { $0 == 1 ? "1 day" : "\($0) days" }, chosen: settings.lock.fingerDays)
            }
        }
        RoomGroup("Lock by itself") {
            ForEach(LockPolicy.Condition.rooms, id: \.field) { row in
                switchRow(row.field, row.words, Binding { preferences.settings.lock.locks(row.condition) }
                          set: { preferences.settings.lock.set(row.condition, to: $0) })
                RoomRule()
            }
            RoomRow("Minutes of idleness before it does", isOff: !preferences.settings.lock.whenIdle) {
                Options(field: "lock.idleMinutes", label: "Minutes", values: Room.idleMinutes,
                        word: { String($0) }, each: Metrics.settingsNarrowSegment,
                        chosen: settings.lock.idleMinutes)
            }
        }
        RoomGroup("Copying and revealing") {
            RoomRow("Clear a copy after") {
                Options(field: "clipboard.clearSeconds", label: "Clear after", values: Room.clearSeconds,
                        word: { $0 < 120 ? "\(Int($0)) s" : "\(Int($0) / 60) min" },
                        chosen: settings.clipboard.clearSeconds)
            }
            RoomRule()
            switchRow("clipboard.staysOnThisMac", "Keep a copy on this Mac",
                      caption: "Off, a copy reaches your other devices through Universal Clipboard.",
                      settings.clipboard.staysOnThisMac)
            RoomRule()
            switchRow("details.revealWithOption", "Hold ⌥ to reveal hidden fields",
                      settings.details.revealWithOption)
        }
    }

    private var fingerCaption: String {
        if !rooms.canUseFinger { return "This Mac has no finger to offer now: none is enrolled, or the lid is shut." }
        return preferences.settings.lock.unlockWithFinger == true
            ? "Turning it off locks the vault and deletes the password kept for it."
            : "A finger opens the vault from the next unlock with the master password."
    }

    // MARK: Privacy

    @ViewBuilder
    private var privacy: some View {
        RoomGroup {
            switchRow("privacy.siteIcons", "Site icons", caption: IconStore.sentence, settings.privacy.siteIcons)
        }
        RoomGroup("Password Health") {
            switchRow("privacy.breachCheck", "Check passwords against known breaches",
                      caption: Breaches.sentence, settings.privacy.breachCheck)
            RoomRule()
            switchRow("privacy.twoFactorCheck", "Find logins that could have a one-time code",
                      caption: TwoFactorCheck.sentence, settings.privacy.twoFactorCheck)
        }
        RoomGroup("Passkeys") {
            switchRow("privacy.passkeysInSystemList", "List passkeys with the system",
                      caption: PasskeyOffer.sentence, settings.privacy.passkeysInSystemList)
        }
        Text("Everything else this app sends is sent by bw, to the server the account is on.")
            .font(Fonts.caption)
            .foregroundStyle(Palette.secondText)
            .padding(.horizontal, Metrics.wide)
    }

    // MARK: Filling

    @ViewBuilder
    private var filling: some View {
        RoomGroup("Typing into another app") {
            RoomRow("Accessibility",
                    caption: "macOS has to allow \(AppInfo.name) to type. Until it does, a fill copies the password instead.") {
                standing(rooms.isTrusted ? "Allowed" : "Not allowed", isGood: rooms.isTrusted)
                Button("Open System Settings…", action: rooms.openAccessibility)
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityLabel("Open Accessibility in System Settings")
            }
            RoomRule()
            switchRow("fill.pressesReturn", "Press Return after the password", settings.fill.pressesReturn)
        }
        RoomGroup("Reading the page a browser is on") {
            ForEach(Browser.allCases, id: \.self) { browser in
                let grant = rooms.grants[browser]
                RoomRow(browser.name) {
                    standing(grant?.words ?? "…", isGood: grant == .allowed)
                        .accessibilityLabel("\(browser.name): \(grant?.words ?? "not known")")
                }
                RoomRule()
            }
            RoomRow("Automation",
                    caption: "macOS asks once for each browser, the first time Quick Access opens over it.") {
                Button("Open System Settings…", action: rooms.openAutomation)
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityLabel("Open Automation in System Settings")
            }
        }
        RoomGroup("The extension in Orion") {
            switchRow("browser.inOrion", "Let Orion reach \(AppInfo.name)", caption: orionCaption,
                      settings.browser.inOrion)
            ForEach(preferences.settings.browser.allowed, id: \.self) { origin in
                RoomRule()
                extensionRow(origin, standing: "Allowed", isGood: true, taking: "Take Back")
            }
            ForEach(preferences.settings.browser.denied, id: \.self) { origin in
                RoomRule()
                extensionRow(origin, standing: "Denied", isGood: false, taking: "Forget")
            }
        }
        if !preferences.settings.browser.neverSave.isEmpty {
            RoomGroup("Sites that never ask to save") {
                ForEach(Array(preferences.settings.browser.neverSave.enumerated()), id: \.element) { place, host in
                    if place > 0 { RoomRule() }
                    RoomRow(host) {
                        Button("Ask Again") { rooms.askAgain(on: host) }
                            .buttonStyle(QuietButtonStyle())
                            .accessibilityLabel("Ask again on \(host)")
                    }
                }
            }
        }
    }

    private var orionCaption: String {
        rooms.hasOrion
            ? "Tells Orion where this app's helper is. Each extension that then asks is let in or turned away on a card, and is listed here."
            : "Orion has not been run on this Mac. Its file is written at the next launch of \(AppInfo.name) after it has."
    }

    /// An extension as the card was told it, and the way back to the card.
    private func extensionRow(_ origin: String, standing words: String, isGood: Bool, taking action: String) -> some View {
        RoomRow(origin, caption: "\(action) puts it back on the card, the next time it asks.") {
            standing(words, isGood: isGood)
                .accessibilityLabel("\(origin): \(words)")
            Button(action) { rooms.forget(origin) }
                .buttonStyle(QuietButtonStyle())
                .accessibilityLabel("\(action) \(origin)")
        }
    }

    private func standing(_ words: String, isGood: Bool) -> some View {
        Text(words)
            .font(Fonts.body)
            .foregroundStyle(isGood ? Palette.good : Palette.secondText)
    }

    // MARK: Developer

    @ViewBuilder
    private var developer: some View {
        RoomGroup("SSH agent") {
            RoomRow("Sign for ssh with a key from the vault",
                    caption: "A socket at ~/.oripass/agent.sock answers while \(AppInfo.name) runs, locked or not. No key leaves the vault, and the app never writes ~/.ssh.",
                    problem: rooms.agentProblem) {
                Switch(isOn: Binding { preferences.settings.ssh.isOn } set: { rooms.setAgent($0) },
                       name: "SSH agent")
                    .accessibilityIdentifier("ssh.isOn")
            }
            RoomRule()
            RoomRow("A finger says yes to one key for one app",
                    isOff: !preferences.settings.ssh.isOn) {
                Options(field: "ssh.approval", label: "Approve for", values: SSHApproval.allCases, word: \.word,
                        each: Metrics.settingsWideSegment, chosen: settings.ssh.approval)
            }
            RoomRule()
            RoomRow("For ~/.ssh/config, under Host *", caption: SSHAgent.configLine,
                    isOff: !preferences.settings.ssh.isOn) {
                Button("Copy", action: rooms.copyAgentLine)
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityLabel("Copy the line for the ssh config")
            }
        }
        RoomGroup("Passes") {
            ForEach(passes.standing) { pass in
                passRow(pass)
                RoomRule()
            }
            if rooms.newPass != nil {
                passForm
            } else {
                RoomRow("Keep an app signing while you are away",
                        caption: rooms.passRefusal ?? "One app, every SSH key, one finger. The keys stay in memory with the vault shut until the pass ends.",
                        isOff: !preferences.settings.ssh.isOn || rooms.passRefusal != nil) {
                    Button("New Pass…") { rooms.beginPass() }
                        .buttonStyle(QuietButtonStyle())
                }
            }
            RoomRule()
            phoneRow
        }
    }

    /// Who may answer what a pass leaves to the card, away from the Mac.
    @ViewBuilder
    private var phoneRow: some View {
        if let phone = preferences.settings.ssh.phone {
            RoomRow(phone.name, caption: "\(phone.fingerprint). Its face answers what a pass leaves to the card, through OriCode.") {
                Button("Forget Phone", action: rooms.forgetPhone)
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityIdentifier("ssh.phone")
            }
        } else if rooms.isWaitingForPhone {
            RoomRow("Waiting for your phone", caption: "Add this Mac in OriCode on the phone. Five minutes, then a card here takes a finger.") {
                Button("Cancel", action: rooms.cancelPhone)
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityIdentifier("ssh.phone")
            }
        } else {
            RoomRow("Answer from a phone", caption: "OriCode only carries the answer. A key in the phone makes it, under its face.",
                    isOff: !preferences.settings.ssh.isOn) {
                Button("Add Phone…") { rooms.addPhone() }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityIdentifier("ssh.phone")
            }
        }
    }

    private func passRow(_ pass: AgentPass) -> some View {
        RoomRow(pass.appName, caption: pass.summary) {
            HStack(spacing: Metrics.gap) {
                Text("\(pass.ends, style: .relative) left")
                    .font(Fonts.caption)
                    .foregroundStyle(Palette.secondText)
                Button("Revoke") { rooms.revoke(pass) }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityLabel("Revoke the pass for \(pass.appName)")
            }
        }
    }

    @ViewBuilder
    private var passForm: some View {
        if let form = rooms.newPass {
            RoomRow("App", caption: "A running app, known by its signature, and everything it starts. One with no team of its own cannot hold a pass.") {
                Picker("App", selection: Binding { form.app } set: { rooms.newPass?.app = $0 }) {
                    ForEach(form.apps) { Text(verbatim: $0.name).tag(Optional($0)) }
                }
                .labelsHidden()
                .fixedSize()
            }
            RoomRule()
            RoomRow("Keys", caption: "Every SSH key in the vault, for its git commits and its logins.") {
                value(AgentPass.keysWord(form.keys.count))
            }
            RoomRule()
            RoomRow("Hosts", caption: "Those in ~/.ssh/known_hosts now, and any you allow with a finger later. A host it has not seen comes to the card.") {
                value(AgentPass.knownHostsWord)
            }
            RoomRule()
            RoomRow("For") {
                Segments(choices: PassSpan.allCases, word: \.word, name: \.word, label: "Keep allowing for",
                         chosen: Binding { form.span } set: { rooms.newPass?.span = $0 }, ground: Palette.field)
                    .frame(width: Metrics.settingsPassSpans)
            }
            RoomRule()
            RoomRow("Touch ID gives it", problem: form.problem) {
                HStack(spacing: Metrics.gap) {
                    Button("Cancel", action: rooms.cancelPass)
                        .buttonStyle(QuietButtonStyle())
                    Button("Give Pass") { rooms.givePass() }
                        .buttonStyle(FilledButtonStyle())
                        .disabled(!form.isReady)
                }
            }
        }
    }

    // MARK: Account

    @ViewBuilder
    private var account: some View {
        RoomGroup {
            RoomRow("Email") { value(store.email ?? "No account on this Mac") }
            RoomRule()
            RoomRow("Server") { value(store.email == nil ? "None" : rooms.server) }
            RoomRule()
            RoomRow("Last synced") { value(store.state == .unlocked ? store.standing.sentence : lastSync) }
        }
        RoomGroup("The engine") {
            RoomRow("bw", caption: rooms.engine?.notice) { value(engine) }
            RoomRule()
            RoomRow("Where bw is", caption: "Empty looks in Homebrew and then along PATH. Once bw has been found, a change is read when the app is next opened.") {
                TextField("", text: settings.engine.bwPath,
                          prompt: Text(BwBinary.homebrew).foregroundStyle(Palette.prompt))
                    .textFieldStyle(.plain)
                    .font(Fonts.body)
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, Metrics.close)
                    .frame(width: Metrics.settingsField, height: Metrics.recorder.height)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous).fill(Palette.field)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                            .strokeBorder(Palette.outline, lineWidth: Metrics.hairline)
                    )
                    .accessibilityLabel("Path to bw")
                    .accessibilityIdentifier("engine.bwPath")
            }
        }
        RoomGroup {
            RoomRow("Web vault",
                    caption: "Changing the master password, two-step login, importing and exporting are done there.") {
                Button("Open…", action: rooms.openWebVault)
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityLabel("Open the web vault")
            }
            RoomRule()
            RoomRow("Lock and forget", caption: "Locks the vault and deletes the password kept for Touch ID, so the next unlock is typed.") {
                Button("Lock and Forget") { rooms.lockAndForget() }
                    .buttonStyle(QuietButtonStyle())
            }
            RoomRule()
            RoomRow("Sign out", caption: "Takes the account off this Mac. Nothing in the vault is deleted.") {
                Button(rooms.isSigningOut ? "Signing Out…" : "Sign Out…", action: rooms.askToSignOut)
                    .buttonStyle(QuietButtonStyle())
                    .opacity(rooms.canSignOut ? 1 : Palette.disabled)
                    .disabled(!rooms.canSignOut)
            }
        }
    }

    private var lastSync: String {
        guard let last = store.lastSync else { return SyncStanding.never.sentence }
        return SyncStanding.synced(store.now().timeIntervalSince(last)).sentence
    }

    private var engine: String {
        if let engine = rooms.engine { return "\(engine.url.path), \(engine.version)" }
        return rooms.hasLooked ? "Not found" : "Looking…"
    }

    private func value(_ words: String) -> some View {
        Text(words)
            .font(Fonts.body)
            .foregroundStyle(Palette.secondText)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }

    // MARK: About

    @ViewBuilder
    private var about: some View {
        HStack(spacing: Metrics.wide) {
            // The picture the Dock has of the app, so the room that names
            // it shows the same one. A bundle with no icon gets the mark.
            Group {
                if let icon = AppIcon.image {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    AppMark().fill(Palette.accent, style: AppMark.fill)
                }
            }
            .frame(width: Metrics.aboutMark, height: Metrics.aboutMark)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Metrics.tight) {
                Text(AppInfo.name)
                    .font(Fonts.title)
                    .foregroundStyle(Palette.text)
                Text("Version \(AppInfo.version)")
                    .font(Fonts.body)
                    .foregroundStyle(Palette.secondText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.close)
        RoomGroup("What it stands on") {
            RoomRow("bw", caption: "Bitwarden's command line client does every login, sync, decryption and write. It is not part of this app: Homebrew installs it, under the GPL 3.0.") {
                EmptyView()
            }
        }
        RoomGroup("Licences") {
            RoomRow("Public Suffix List",
                    caption: "Says which part of an address is the site. Inside the app as publicsuffix.org served it, unchanged, under the Mozilla Public License 2.0.") {
                Button("Source") { rooms.open(Rooms.publicSuffix) }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityLabel("Where the Public Suffix List comes from")
                Button("Licence") { rooms.open(Rooms.listLicence) }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityLabel("The Mozilla Public License")
            }
            RoomRule()
            RoomRow("2FA Directory",
                    caption: "The list of sites that take a one-time code, fetched while its switch in Privacy is on. Data sourced from 2FA Directory by 2factorauth, under the MIT licence.") {
                EmptyView()
            }
        }
    }

    private func switchRow(_ field: String, _ words: String, caption: String? = nil, isOff: Bool = false,
                           _ isOn: Binding<Bool>) -> some View {
        RoomRow(words, caption: caption, isOff: isOff) {
            Switch(isOn: isOn, name: words)
                .accessibilityIdentifier(field)
        }
    }
}

// MARK: - The pieces of a room

/// Rows in one outline, under a small heading when they have one.
struct RoomGroup<Rows: View>: View {
    private let heading: String?
    private let rows: Rows

    init(_ heading: String? = nil, @ViewBuilder rows: () -> Rows) {
        self.heading = heading
        self.rows = rows()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.groupRadius, style: .continuous)
        VStack(alignment: .leading, spacing: Metrics.close) {
            if let heading {
                Text(heading.uppercased())
                    .font(Fonts.heading)
                    .tracking(Metrics.headingTracking)
                    .foregroundStyle(Palette.secondText)
                    .padding(.horizontal, Metrics.wide)
                    .accessibilityLabel(heading)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) { rows }
                .overlay(shape.strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
        }
    }
}

/// The line between two rows of a group, in from the outline at its left.
struct RoomRule: View {
    var body: some View {
        Hairline(.horizontal)
            .padding(.leading, Metrics.wide)
    }
}

/// A label with its control at the right, and under the label a grey line
/// that says what the control does and a red one when it could not.
struct RoomRow<Control: View>: View {
    private let words: String
    private let caption: String?
    private let problem: String?
    /// The control cannot be used now. It and the label are faint, and the
    /// grey line is not: it is the sentence that says why.
    private let isOff: Bool
    private let control: Control

    init(_ words: String, caption: String? = nil, problem: String? = nil, isOff: Bool = false,
         @ViewBuilder control: () -> Control) {
        self.words = words
        self.caption = caption
        self.problem = problem
        self.isOff = isOff
        self.control = control()
    }

    var body: some View {
        HStack(spacing: Metrics.gap) {
            VStack(alignment: .leading, spacing: Metrics.hair) {
                Text(words)
                    .font(Fonts.body)
                    .foregroundStyle(Palette.text)
                    .opacity(isOff ? Palette.disabled : 1)
                if let caption {
                    Text(caption)
                        .font(Fonts.caption)
                        .foregroundStyle(Palette.secondText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let problem {
                    Text(problem)
                        .font(Fonts.caption)
                        .foregroundStyle(Palette.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            control
                .opacity(isOff ? Palette.disabled : 1)
                .disabled(isOff)
        }
        .padding(.horizontal, Metrics.wide)
        // A control as tall as a button stands clear of the rules either
        // side of it at both densities.
        .padding(.vertical, caption == nil && problem == nil ? Metrics.settingsAir : Metrics.close)
        .frame(minHeight: Metrics.settingsRow)
    }
}

/// A row of segments over the values a field may take, drawn under the
/// field's name.
struct Options<Value: Hashable>: View {
    private struct Option: Hashable {
        let value: Value
        let word: String
    }

    let field: String
    let label: String
    let values: [Value]
    let word: (Value) -> String
    var each = Metrics.settingsSegment
    @Binding var chosen: Value

    init(field: String, label: String, values: [Value], word: @escaping (Value) -> String,
         each: CGFloat = Metrics.settingsSegment, chosen: Binding<Value>) {
        self.field = field
        self.label = label
        self.values = values
        self.word = word
        self.each = each
        _chosen = chosen
    }

    init(field: String, label: String, values: [Value], word: KeyPath<Value, String>,
         each: CGFloat = Metrics.settingsSegment, chosen: Binding<Value>) {
        self.init(field: field, label: label, values: values, word: { $0[keyPath: word] }, each: each,
                  chosen: chosen)
    }

    var body: some View {
        Segments(choices: values.map { Option(value: $0, word: word($0)) }, word: \.word, name: \.word,
                 label: label,
                 chosen: Binding { Option(value: chosen, word: word(chosen)) } set: { chosen = $0.value },
                 ground: Palette.field)
            .frame(width: each * CGFloat(values.count))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(field)
    }
}

/// The question between Sign Out and the account being gone from this Mac.
struct SignOutQuestion: View {
    let email: String
    var cancel: () -> Void = {}
    var signOut: () -> Void = {}

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
        ZStack {
            Palette.scrim
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: cancel)
                .accessibilityHidden(true)
            VStack(spacing: Metrics.loose) {
                Glyph.login.image
                    .resizable()
                    .scaledToFit()
                    .frame(width: Metrics.offerGlyph, height: Metrics.offerGlyph)
                    .foregroundStyle(Palette.red)
                    .accessibilityHidden(true)
                VStack(spacing: Metrics.close) {
                    Text("Sign out of \(email)?")
                        .font(Fonts.statement)
                        .foregroundStyle(Palette.text)
                    Text("The account is taken off this Mac: the password kept for Touch ID and everything bw keeps here. Nothing in the vault is deleted, and signing in brings it back.")
                        .font(Fonts.sentence)
                        .foregroundStyle(Palette.secondText)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Metrics.gap) {
                    Button("Cancel", action: cancel)
                        .buttonStyle(QuietButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button("Sign Out", action: signOut)
                        .buttonStyle(FilledButtonStyle(ground: Palette.redLit))
                }
            }
            .padding(Metrics.apart)
            .frame(width: Metrics.offerWidth)
            .background(shape.fill(Palette.content))
            .overlay(shape.strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
            .shadow(color: Palette.shadow, radius: Metrics.menuShadow, y: Metrics.tight)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Shots

extension Surface {
    /// The window on `room`, over a Mac that has a finger, a mark in its
    /// bar and the three browsers standing three ways.
    private static func room(_ name: String, _ room: Room,
                             _ arrange: @escaping @MainActor (Rooms) -> Void = { _ in }) -> Surface {
        Surface(name: name, size: Metrics.settingsWindow, frame: { SettingsWindow.make() }) { store in
            let seal = PasswordSeal(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("oripass-shot-seal"), enclave: FakeEnclave())
            let door = Door(store: store, seal: seal)
            door.preferences.settings.lock.unlockWithFinger = true
            let rooms = Rooms(door: door, hands: .init(loginItem: FakeLoginItem(isOn: true),
                                                       access: FakeAccessibility(isTrusted: true),
                                                       hasFinger: { true }))
            rooms.room = room
            rooms.show(grants: [.safari: .allowed, .brave: .notAsked, .orion: .notRunning],
                       engine: BwBinary(url: URL(fileURLWithPath: BwBinary.homebrew), version: "2026.9.1"))
            arrange(rooms)
            return AnyView(RoomsView(rooms: rooms))
        }
    }

    /// Every room. Then a key the rules refused, with a second one taken
    /// away; the switches the other way; Orion let in, with one extension
    /// of each answer; the question before the account goes; and a `bw`
    /// newer than the app was written for.
    static let settings: [Surface] = Room.allCases.map { room("settings-\($0.rawValue)", $0) } + [
        room("settings-general-refused", .general) { rooms in
            rooms.record(HotKey(key: UInt32(kVK_ANSI_C), carbon: UInt32(cmdKey)), for: .showApp)
            rooms.clear(.fill)
            rooms.preferences.settings.menuBar.showsMark = false
        },
        room("settings-security-off", .security) { rooms in
            rooms.preferences.settings.lock.unlockWithFinger = false
            rooms.preferences.settings.lock.whenIdle = false
            rooms.preferences.settings.details.revealWithOption = true
        },
        room("settings-developer-on", .developer) { rooms in
            rooms.preferences.settings.ssh.isOn = true
        },
        room("settings-developer-passes", .developer) { rooms in
            rooms.preferences.settings.ssh.isOn = true
            rooms.door.passes.fingers = { Data() }
            AgentPass.demo(rooms.door.passes)
        },
        room("settings-developer-phone", .developer) { rooms in
            rooms.preferences.settings.ssh.isOn = true
            rooms.preferences.settings.ssh.phone = SSHPhone(name: "Meriç's iPhone", publicKey: Data(repeating: 4, count: 65))
        },
        room("settings-developer-add-phone", .developer) { rooms in
            rooms.preferences.settings.ssh.isOn = true
            rooms.isWaitingForPhone = true
        },
        room("settings-developer-new-pass", .developer) { rooms in
            rooms.preferences.settings.ssh.isOn = true
            rooms.newPass = Rooms.NewPass(keys: AgentPass.demoKeys, apps: AgentPass.demoApps)
        },
        room("settings-filling-never", .filling) { rooms in
            rooms.preferences.settings.browser.neverSave = ["intranet.example.com", "login.example.org"]
        },
        room("settings-filling-orion", .filling) { rooms in
            rooms.preferences.settings.browser.inOrion = true
            rooms.preferences.settings.browser.answer("chrome-extension://kpmgpeopabaknoepkjmkmdcjkbmgjgkf/", allowed: true)
            rooms.preferences.settings.browser.answer("chrome-extension://bgnkhhnnamicmpeenaelnjfhikgbkllg/", allowed: false)
        },
        room("settings-sign-out", .account) { $0.askToSignOut() },
        room("settings-account-newer-bw", .account) { rooms in
            rooms.show(grants: [:], engine: BwBinary(url: URL(fileURLWithPath: BwBinary.homebrew), version: "2027.1.0"))
        },
    ]
}
