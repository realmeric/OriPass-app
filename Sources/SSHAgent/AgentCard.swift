import AppKit
import Combine
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import SwiftUI

/// What a signature is for, for the card's words. It is read from what is to
/// be signed and from what the process says, so it decides nothing.
enum AgentPurpose: Equatable {
    case login, commit, signature

    init(signing data: Data, key: Data) {
        if let signature = SSHSigData(data) {
            self = signature.isGit ? .commit : .signature
        } else {
            self = UserAuthRequest(data, key: key) == nil ? .signature : .login
        }
    }
}

/// What is being asked: who, for which key, going where, or who wants a shut
/// vault opened. It holds a name and a fingerprint and no key.
@MainActor
final class AgentQuestion: ObservableObject {
    struct Key {
        let name: String
        let fingerprint: String
    }

    /// A phone asking to be added, which is all this card is about then.
    struct Adding {
        let name: String
        let fingerprint: String
    }

    static let spanLabel = "Allow for"
    static let awayLabel = "Keep allowing while I'm away"
    static let passLabel = "Keep allowing for"

    let peer: AgentPeer
    /// Nil over a shut vault, which has no list to name one from.
    let key: Key?
    let purpose: AgentPurpose
    /// The host key's fingerprint, when `session-bind` gave one. The agent
    /// has no name for it, and a name in `known_hosts` may well be hashed.
    let host: String?
    let isForwarded: Bool
    let adding: Adding?
    /// False with the lid shut: the master password stands in its place.
    let hasFinger: Bool
    /// A key is named over a shut vault when a pass holds it, and a touch
    /// then opens the vault as well.
    let opensVault: Bool
    /// False over a shut vault with no finger, which a password cannot open
    /// from here: only the phone can answer.
    let offersPassword: Bool
    /// Nil for a caller with no app above it.
    let icon: NSImage?
    let asked: Date
    let patience: TimeInterval
    /// What a finger on this card is asked for on. `AgentFinger` draws it,
    /// and with nothing drawing it the system's sheet asks.
    let finger = TouchIDEnclave.context()
    /// How long this yes stands, and no other: the settings are not told.
    @Published var span: SSHApproval
    /// The row under the segments, which opens the four spans of a pass.
    @Published var keepsAllowing = false
    @Published var keptFor = PassSpan.oneHour
    /// The request that went to the phone, while the card waits on either.
    @Published var phoneRequest: String?
    /// True once the phone's yes has been checked. It is for this request
    /// and nothing else, and it opens nothing.
    private(set) var yesFromPhone = false
    /// How OriCode is told it ended, when it was not a person at the Mac.
    private(set) var ending: PhoneOutcome?

    private var refuse: (() -> Void)?
    private var choosing: CheckedContinuation<Bool, Never>?

    init(peer: AgentPeer, key: Key?, purpose: AgentPurpose = .login, host: String?, isForwarded: Bool, adding: Adding? = nil,
         hasFinger: Bool, opensVault: Bool = false, offersPassword: Bool = true, approval: SSHApproval,
         icon: NSImage? = nil, asked: Date = Date(), patience: TimeInterval = 60, refuse: @escaping () -> Void) {
        self.peer = peer
        self.key = key
        self.purpose = purpose
        self.host = host
        self.isForwarded = isForwarded
        self.adding = adding
        self.hasFinger = hasFinger
        self.opensVault = opensVault
        self.offersPassword = offersPassword
        self.icon = icon
        self.asked = asked
        self.patience = patience
        // A forwarded yes is for the one request, so there is nothing to
        // choose.
        span = isForwarded ? .eachUse : approval
        self.refuse = refuse
    }

    /// What it wants done, in the words of whoever is reading the card and
    /// not of the protocol.
    var statement: String {
        let app = peer.appName
        if let adding { return "\(app) wants to add \(adding.name)" }
        guard key != nil else { return "\(app) wants to open the vault" }
        switch (purpose, peer.gitAct, destination) {
        case (.commit, _, _): return "\(app) wants to sign a commit"
        case (.signature, _, _): return "\(app) wants to sign something with an SSH key"
        case (.login, .push, let host?): return "\(app) wants to push to \(host)"
        case (.login, .fetch, let host?): return "\(app) wants to fetch from \(host)"
        case (.login, _, let host?): return "\(app) wants to connect to \(host)"
        case (.login, _, nil): return "\(app) wants to connect to a server"
        }
    }

    /// What a touch gives, which follows the span and the pass on the card.
    var sentence: String {
        if adding != nil {
            return "Compare these characters with the ones on the phone. A touch lets it answer what a pass leaves to this card."
        }
        if phoneOnly { return "Nothing here can answer this: there is no finger to be had. Your phone can, for this one request." }
        let who = "\(peer.appName), and whatever it runs,"
        if isForwarded { return key == nil ? "A touch opens the vault." : "A touch allows this one request." }
        let opening = key == nil || opensVault
        if let passSpan {
            let gives = "gives \(peer.appName) a pass for \(passSpan.word)"
            return opening ? "A touch opens the vault and \(gives)." : "A touch allows this and \(gives)."
        }
        guard opening else { return "A touch lets \(who) use this key \(lasting). The key stays in \(AppInfo.name)." }
        return "A touch opens the vault and lets \(who) use \(key == nil ? "a" : "this") key \(lasting)."
    }

    private var lasting: String {
        switch span {
        case .eachUse: return "this once"
        case .tenMinutes: return "for 10 minutes"
        case .untilLock: return "until the vault locks"
        }
    }

    var warning: String? {
        isForwarded ? "This came from a remote host through agent forwarding, so it is asked every time." : nil
    }

    /// Over a shut vault with no finger, the phone is the one way to a yes.
    private var phoneOnly: Bool { !hasFinger && !offersPassword }

    var offersSpan: Bool { !isForwarded && adding == nil && !phoneOnly }

    /// A pass is for the whole of an app, so it takes that app shown to be
    /// what it is, and a finger to give it. A forwarded request has neither
    /// to say.
    var offersPass: Bool { !isForwarded && adding == nil && hasFinger && peer.signer != nil }

    /// The pass this answer gives, if any.
    var passSpan: PassSpan? { offersPass && keepsAllowing ? keptFor : nil }

    var passSentence: String {
        "This is for the whole of \(peer.appName) and everything it starts. Every SSH key in the vault signs its git commits and its logins to known hosts with nobody asked, the vault open or shut, and stays in memory until the pass ends."
    }
    var destination: String? { peer.destination }

    /// A forwarded request has come back through the host `ssh` went to,
    /// and is going somewhere else, which the host key names.
    var destinationLabel: String { isForwarded ? "Through" : "Going to" }

    /// The line under the destination: the proof, or that there is none.
    var hostLine: String? {
        guard host == nil, destination != nil else { return nil }
        return "The server has not proved this: it is only what the process says."
    }

    var chain: String { peer.names.joined(separator: " › ") }

    /// What the card says, in lines, which is what the phone shows and what
    /// he answers there.
    var words: String {
        var lines = [statement]
        if let warning { lines.append(warning) }
        if let key { lines.append("Key: \(key.name)") }
        if let destination { lines.append("\(destinationLabel): \(destination)") }
        if let host { lines.append("Server's key: \(host)") }
        if let project = peer.project { lines.append("Project: \(project)") }
        lines.append("Asked by: \(chain)")
        return lines.joined(separator: "\n")
    }

    /// How much of the sixty seconds is left at `moment`, from 1 to 0.
    func left(at moment: Date) -> Double {
        min(max(1 - moment.timeIntervalSince(asked) / patience, 0), 1)
    }

    /// Waits for the password's button. False for Deny and the clock.
    func passwordChosen() async -> Bool {
        guard refuse != nil else { return false }
        return await withCheckedContinuation { choosing = $0 }
    }

    func usePassword() {
        choosing?.resume(returning: true)
        choosing = nil
    }

    /// The phone's yes, checked. The card goes the way Deny takes it.
    func answeredByPhone() {
        yesFromPhone = true
        deny()
    }

    func expire() {
        ending = .expired
        deny()
    }

    func withdraw() {
        ending = .withdrawn
        deny()
    }

    func deny() {
        choosing?.resume(returning: false)
        choosing = nil
        let refuse = self.refuse
        self.refuse = nil
        refuse?()
    }
}

extension AgentPeer {
    /// The app's own icon, from the running app, or from its file for a
    /// helper that is no running app of its own. What a process is called
    /// is nobody's proof of anything, and neither is this.
    var icon: NSImage? {
        guard appProcess != nil else { return nil }
        return appProcess.flatMap { NSRunningApplication(processIdentifier: $0)?.icon }
            ?? NSWorkspace.shared.icon(forFile: app)
    }
}

/// The card: one large mark, a bold line, what is being asked in an outlined
/// group, and a column of wide controls with the finger among them
/// (`docs/look.md`, "The card over ssh").
struct AgentCard: View {
    static let touchID = "Touch ID to allow"
    static let usePassword = "Use Master Password…"
    static let phoneAsked = "Your phone has been asked as well."

    @ObservedObject var question: AgentQuestion
    /// False for a shot and a test of the words: a shot has no sensor, and
    /// the fingerprint is a stand-in.
    var drawsFinger = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
        VStack(spacing: Metrics.wide) {
            AgentMark(icon: question.icon)
            VStack(spacing: Metrics.tight) {
                Text(verbatim: question.statement)
                    .font(Fonts.question)
                    .foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                if let warning = question.warning {
                    Text(verbatim: warning)
                        .font(Fonts.sentence)
                        .foregroundStyle(Palette.red)
                }
                Text(verbatim: question.sentence)
                    .font(Fonts.sentence)
                    .foregroundStyle(Palette.secondText)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            group
            if question.offersSpan {
                HStack(spacing: Metrics.gap) {
                    Text(verbatim: AgentQuestion.spanLabel)
                        .font(Fonts.rowSecond)
                        .foregroundStyle(Palette.secondText)
                        .accessibilityHidden(true)
                    Segments(choices: SSHApproval.allCases, word: \.word, name: \.word,
                             label: AgentQuestion.spanLabel, chosen: $question.span, ground: Palette.field)
                }
            }
            if question.offersPass { away }
            VStack(spacing: Metrics.gap) {
                proof
                if question.phoneRequest != nil {
                    Text(verbatim: Self.phoneAsked)
                        .font(Fonts.rowSecond)
                        .foregroundStyle(Palette.secondText)
                }
                Button("Deny", action: question.deny)
                    .buttonStyle(QuietButtonStyle(fills: true))
            }
        }
        .padding(Metrics.loose)
        .frame(width: Metrics.agentWidth)
        .background(shape.fill(Palette.content))
        .overlay(alignment: .bottomLeading) { AgentLine(question: question) }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
        .accessibilityElement(children: .contain)
    }

    private var group: some View {
        Outlined {
            if let adding = question.adding {
                AgentRow("Phone", adding.name) {
                    Text(verbatim: adding.fingerprint)
                        .font(Fonts.fingerprint)
                        .foregroundStyle(Palette.secondText)
                }
                rule
            }
            if let key = question.key {
                AgentRow("Key", key.name) {
                    Text(verbatim: key.fingerprint)
                        .font(Fonts.fingerprint)
                        .foregroundStyle(Palette.secondText)
                }
                rule
            }
            if question.destination != nil || question.host != nil {
                AgentRow(question.destinationLabel, question.destination) {
                    if let host = question.host {
                        HStack(spacing: Metrics.close) {
                            Text(verbatim: "Server's key")
                                .font(Fonts.label)
                                .foregroundStyle(Palette.secondText)
                            Text(verbatim: host)
                                .font(Fonts.fingerprint)
                                .foregroundStyle(Palette.secondText)
                        }
                    } else if let line = question.hostLine {
                        Text(verbatim: line)
                            .font(Fonts.label)
                            .foregroundStyle(Palette.secondText)
                    }
                }
                rule
            }
            if let project = question.peer.project {
                AgentRow("Project", project) { EmptyView() }
                rule
            }
            AgentRow("Asked by", question.chain, isCode: true) { EmptyView() }
        }
    }

    private var rule: some View {
        Hairline(.horizontal)
            .padding(.leading, Metrics.gap)
    }

    /// One switch, which opens the four spans. The same finger gives it.
    private var away: some View {
        VStack(spacing: Metrics.close) {
            HStack(spacing: Metrics.gap) {
                Text(verbatim: AgentQuestion.awayLabel)
                    .font(Fonts.rowSecond)
                    .foregroundStyle(Palette.secondText)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                Switch(isOn: $question.keepsAllowing, name: AgentQuestion.awayLabel)
            }
            if question.keepsAllowing {
                Segments(choices: PassSpan.allCases, word: \.word, name: \.word, label: AgentQuestion.passLabel,
                         chosen: $question.keptFor, ground: Palette.field)
                Text(verbatim: question.passSentence)
                    .font(Fonts.label)
                    .foregroundStyle(Palette.secondText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The finger, or with no finger to be had the button for the password.
    @ViewBuilder private var proof: some View {
        if question.hasFinger {
            VStack(spacing: Metrics.tight) {
                Group {
                    if drawsFinger {
                        AgentFinger(context: question.finger)
                    } else {
                        Glyph.fingerprint.image
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(Palette.fingerStandIn)
                    }
                }
                .frame(width: Metrics.agentFinger, height: Metrics.agentFinger)
                .accessibilityHidden(true)
                Text(verbatim: Self.touchID)
                    .font(Fonts.rowSecond)
                    .foregroundStyle(Palette.secondText)
            }
        } else if question.offersPassword {
            Button(Self.usePassword, action: question.usePassword)
                .buttonStyle(FilledButtonStyle(fills: true))
        }
    }
}

/// The asking app's icon with the key's tile on its corner, or the tile alone
/// when no app is asking.
private struct AgentMark: View {
    let icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Metrics.agentIcon, height: Metrics.agentIcon)
                    .overlay(alignment: .bottomTrailing) {
                        CategoryTile(type: .sshKey, side: Metrics.agentBadge)
                            .padding(Metrics.agentBadgeEdge)
                            .background(
                                RoundedRectangle(cornerRadius: Metrics.agentBadge * Metrics.iconCorner,
                                                 style: .continuous)
                                    .fill(Palette.content)
                            )
                            .offset(x: Metrics.tight, y: Metrics.tight)
                    }
            } else {
                CategoryTile(type: .sshKey, side: Metrics.agentIcon)
            }
        }
        .accessibilityHidden(true)
    }
}

/// One row of the group: what it is, its value and whatever stands under it.
private struct AgentRow<Under: View>: View {
    let label: String
    let value: String?
    let isCode: Bool
    let under: Under

    init(_ label: String, _ value: String?, isCode: Bool = false, @ViewBuilder under: () -> Under) {
        self.label = label
        self.value = value
        self.isCode = isCode
        self.under = under()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.hair) {
            Text(verbatim: label)
                .font(Fonts.label)
                .foregroundStyle(Palette.label)
            if let value {
                Text(verbatim: value)
                    .font(isCode ? Fonts.fingerprint : Fonts.rowTitle)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            under
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, Metrics.gap)
        .padding(.vertical, Metrics.agentRowInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The sensor. The view pairs itself with the context as it is made, and from
/// then on the finger is asked for in it and the system raises no sheet.
private struct AgentFinger: NSViewRepresentable {
    let context: LAContext

    func makeNSView(context view: Context) -> LAAuthenticationView {
        LAAuthenticationView(context: context, controlSize: .regular)
    }

    func updateNSView(_ view: LAAuthenticationView, context: Context) {}
}

/// The sixty seconds, along the foot of the card, running out towards the
/// left.
private struct AgentLine: View {
    let question: AgentQuestion

    var body: some View {
        TimelineView(.periodic(from: question.asked, by: Motion.runningDown)) { moment in
            let left = question.left(at: moment.date)
            GeometryReader { room in
                Rectangle()
                    .fill(Palette.accent)
                    .frame(width: room.size.width * left)
            }
            .accessibilityElement()
            .accessibilityLabel("\(Int((left * question.patience).rounded(.up))) seconds left")
        }
        .frame(height: Metrics.agentLine)
    }
}

/// Where the card is put. A test hands the agent something that only
/// remembers.
@MainActor
protocol AgentStage: AnyObject {
    /// True when the question is on the screen, with its finger drawn.
    func show(_ question: AgentQuestion) -> Bool
    func close()
}

/// The card in the middle of the screen the pointer is on, over every window
/// and every Space. The sensor listens only while its window has the keys, so
/// a card with a finger takes them as it comes up, and being non-activating
/// leaves the app in front where it is. It comes up by itself, while he may be
/// typing into something else, so nothing typed answers it: no key does
/// anything, and Esc is Deny only once it has been clicked. A card with no
/// finger has no use for the keys until that click.
@MainActor
final class AgentPanel: AgentStage {
    private var panel: Panel?
    private var growing: AnyCancellable?

    func show(_ question: AgentQuestion) -> Bool {
        close()
        let panel = Self.make(question, pointer: NSEvent.mouseLocation,
                              screens: NSScreen.screens.map { ($0.frame, $0.visibleFrame) })
        self.panel = panel
        // The row opens and shuts, and the sentence takes another length,
        // on a card that was sized to it, and only after the view has heard.
        let moved = question.$keepsAllowing.dropFirst().map { _ in }
        growing = moved.merge(with: question.$span.dropFirst().map { _ in }).sink { [weak panel] in
            DispatchQueue.main.async { panel.map(Self.fit) }
        }
        panel.orderFrontRegardless()
        if panel.canBecomeKey { panel.makeKey() }
        return panel.isVisible
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        growing = nil
        panel.dismiss = nil
        panel.orderOut(nil)
        panel.contentView = nil
    }

    /// The panel at the size of its card now, around the same middle.
    static func fit(_ panel: NSPanel) {
        guard let size = panel.contentView?.fittingSize else { return }
        let frame = panel.frame
        panel.setFrame(NSRect(x: (frame.midX - size.width / 2).rounded(), y: (frame.midY - size.height / 2).rounded(),
                              width: size.width, height: size.height), display: true)
    }

    /// The panel, sized to its card, in the middle of the screen `pointer`
    /// is on, and not shown.
    static func make(_ question: AgentQuestion, pointer: CGPoint,
                     screens: [(frame: NSRect, visible: NSRect)]) -> Panel {
        let card = FirstClickView(rootView: AgentCard(question: question))
        let size = card.fittingSize
        let panel = Panel(contentRect: AgentPlace.frame(of: size, pointer: pointer, screens: screens),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.dismiss = { [weak question] in question?.deny() }
        panel.needsKeys = question.hasFinger
        panel.level = .modalPanel
        panel.isOpaque = false
        panel.backgroundColor = Palette.none
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = card
        return panel
    }

    final class Panel: NSPanel {
        private static let escapeKey: UInt16 = 53

        var dismiss: (() -> Void)?
        var needsKeys = false
        private var wasClicked = false

        override var canBecomeKey: Bool { needsKeys || wasClicked }
        override var canBecomeMain: Bool { false }

        /// With this panel key the app counts as active, so a ⌘Q meant for
        /// the app in front would otherwise reach this app's menu.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            event.keyCode == Self.escapeKey ? super.performKeyEquivalent(with: event) : true
        }

        override func sendEvent(_ event: NSEvent) {
            switch event.type {
            case .leftMouseDown, .rightMouseDown:
                wasClicked = true
                super.sendEvent(event)
            case .keyDown:
                if wasClicked, event.keyCode == Self.escapeKey { dismiss?() }
            default:
                super.sendEvent(event)
            }
        }
    }

    /// As over the browser: the panel starts with no keys, and its first
    /// click would otherwise only bring it forward.
    private final class FirstClickView: NSHostingView<AgentCard> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

/// Where the card goes: the middle of what the screen under the pointer has
/// free. A pointer on no screen, between two displays that do not touch, gets
/// the first.
enum AgentPlace {
    static func frame(of size: CGSize, pointer: CGPoint, screens: [(frame: NSRect, visible: NSRect)]) -> NSRect {
        guard let screen = (screens.first { $0.frame.contains(pointer) } ?? screens.first)?.visible else {
            return NSRect(origin: .zero, size: size)
        }
        return NSRect(x: (screen.midX - size.width / 2).rounded(), y: (screen.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }
}

extension NSScreen {
    static var underPointer: NSScreen? {
        screens.first { $0.frame.contains(NSEvent.mouseLocation) }
    }
}

extension Surface {
    private static let oriCode = AgentPeer(names: ["ssh", "zsh", "claude", "OriCode"], app: "/Applications/OriCode.app",
                                           destination: "alpen", signer: AppSigner(bundleID: "dev.oricode", team: "ABCDE12345"))
    private static let committing = AgentPeer(names: ["ssh-keygen", "git", "zsh", "claude", "OriCode"],
                                              app: "/Applications/OriCode.app", project: "alpen",
                                              signer: oriCode.signer)
    private static let pushing = AgentPeer(names: ["ssh", "git", "zsh", "claude", "OriCode"],
                                           app: "/Applications/OriCode.app", destination: "github.com", gitAct: .push,
                                           project: "alpen", signer: oriCode.signer)
    private static let demoKey = AgentQuestion.Key(name: "Sunucu anahtarı",
                                                   fingerprint: "SHA256:KeyDemoKeyDemoKeyDemoKeyDemoKeyDemoKeyDemoK")
    private static let demoHost = "SHA256:DemoDemoDemoDemoDemoDemoDemoDemoDemoDemoDem"

    private static func agentQuestion(_ name: String, peer: AgentPeer = oriCode, key: AgentQuestion.Key? = demoKey,
                                      host: String? = demoHost, isForwarded: Bool = false, hasFinger: Bool = true,
                                      icon: Bool = true, keepsAllowing: Bool = false, purpose: AgentPurpose = .login,
                                      adding: AgentQuestion.Adding? = nil, waitsOnPhone: Bool = false,
                                      opensVault: Bool = false, offersPassword: Bool = true) -> Surface {
        Surface(name: name, size: Metrics.agentCardShot, isBare: true) { _ in
            // Part of the way through its sixty seconds.
            let question = AgentQuestion(peer: peer, key: key, purpose: purpose, host: host, isForwarded: isForwarded,
                                         adding: adding, hasFinger: hasFinger, opensVault: opensVault,
                                         offersPassword: offersPassword, approval: .tenMinutes,
                                         icon: icon ? AppIcon.image : nil, asked: Date() - 20) {}
            question.keepsAllowing = keepsAllowing
            question.phoneRequest = waitsOnPhone ? "shot" : nil
            question.keptFor = .eightHours
            return AnyView(AgentCard(question: question, drawsFinger: false).padding(Metrics.loose))
        }
    }

    /// The questions, with the finger's stand-in: the plain one, a commit's,
    /// which has no host, a push, with a pass being given, from a host the
    /// agent was forwarded to, over a shut vault, and with no finger to be
    /// had. And a caller with no app above it, who has no icon.
    static let agentQuestions: [Surface] = [
        agentQuestion("agent-question"),
        agentQuestion("agent-question-commit", peer: committing, host: nil, purpose: .commit),
        agentQuestion("agent-question-push", peer: pushing),
        agentQuestion("agent-question-pass", keepsAllowing: true),
        agentQuestion("agent-question-phone", waitsOnPhone: true),
        agentQuestion("agent-question-phone-shut", hasFinger: false, waitsOnPhone: true, opensVault: true,
                      offersPassword: false),
        agentQuestion("agent-question-add-phone", peer: AgentPeer(names: ["OriCode"], app: "OriCode"), key: nil, host: nil,
                      icon: false, adding: .init(name: "Meriç's iPhone", fingerprint: "3F9A-11C2-07BE-D4E8")),
        agentQuestion("agent-question-commit-pass", peer: committing, host: nil, keepsAllowing: true, purpose: .commit),
        agentQuestion("agent-question-forwarded", isForwarded: true),
        agentQuestion("agent-question-shut", key: nil),
        agentQuestion("agent-question-password", hasFinger: false),
        agentQuestion("agent-question-no-app", peer: AgentPeer(names: ["ssh", "launchd-job"], app: "/usr/local/bin/launchd-job"),
                      icon: false),
    ]
}
