import AppKit
import Combine
import Foundation
import Security
import SwiftUI

/// An app by its signature, which is the only thing a pass matches it by:
/// what it is called and where its file lies say nothing.
struct AppSigner: Hashable {
    /// Where a real team stands, for Apple's own apps, which have none. No
    /// team is called this: a team is ten letters and digits.
    static let apple = "Apple"

    let bundleID: String
    let team: String

    /// Who process `pid` is, from the system. Nil for anything a signature
    /// would not hold a pass to: unsigned, ad hoc, a certificate of nobody's
    /// that only calls itself a team, a program another may be loaded into,
    /// and in a Release build one any process of his may attach to. The
    /// team in the code's own directory is only what the code says, so it
    /// counts once Apple's anchor and the certificate have been held to it.
    static func of(_ pid: pid_t) -> AppSigner? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              let status = PeerCheck.status(of: code)
        else { return nil }
        var information: CFDictionary?
        var signed: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &signed) == errSecSuccess, let signed,
              SecCodeCopySigningInformation(signed, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let said = information as? [String: Any], let bundleID = said[kSecCodeInfoIdentifier as String] as? String,
              isPlain(bundleID)
        else { return nil }
        let team = said[kSecCodeInfoTeamIdentifier as String] as? String
        if let team {
            guard isPlain(team), status & PeerCheck.hardened != 0,
                  PeerCheck.takesDebuggable || status & PeerCheck.debuggable == 0
            else { return nil }
        }
        let held = team.map { "anchor apple generic and certificate leaf[subject.OU] = \"\($0)\"" } ?? "anchor apple"
        var requirement: SecRequirement?
        SecRequirementCreateWithString("identifier \"\(bundleID)\" and \(held)" as CFString, [], &requirement)
        guard let requirement, SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return nil }
        return AppSigner(bundleID: bundleID, team: team ?? apple)
    }

    /// Nothing that could close a quotation in a requirement.
    private static func isPlain(_ word: String) -> Bool {
        !word.isEmpty && word.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }
    }
}

/// How long a pass stands.
enum PassSpan: String, CaseIterable, Hashable {
    case oneHour, fourHours, eightHours, oneDay

    var word: String {
        switch self {
        case .oneHour: return "1 hour"
        case .fourHours: return "4 hours"
        case .eightHours: return "8 hours"
        case .oneDay: return "24 hours"
        }
    }

    var window: TimeInterval {
        switch self {
        case .oneHour: return 60 * 60
        case .fourHours: return 4 * 60 * 60
        case .eightHours: return 8 * 60 * 60
        case .oneDay: return 24 * 60 * 60
        }
    }
}

/// A running app New Pass can name.
struct PassApp: Hashable, Identifiable {
    let name: String
    let signer: AppSigner

    var id: AppSigner { signer }

    /// What is running with a Dock icon, by its signature, so an app that
    /// could not hold a pass is not offered one. `running` is the workspace's
    /// and read on the main thread; the signatures are read off it.
    static func signed(_ running: [(name: String, pid: pid_t)]) async -> [PassApp] {
        await Task.detached {
            var apps: [AppSigner: PassApp] = [:]
            for app in running {
                guard let signer = AppSigner.of(app.pid) else { continue }
                apps[signer] = PassApp(name: app.name, signer: signer)
            }
            return apps.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }.value
    }

    @MainActor static var running: [(name: String, pid: pid_t)] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let name = app.localizedName else { return nil }
            return (name, app.processIdentifier)
        }
    }
}

/// What a pass signs (D22).
enum PassAct {
    /// A login of `ssh`'s, on the connection's own bound session, to a host
    /// the pass knows.
    case login
    /// A git commit or tag: `SSHSigData` under the namespace `git`.
    case commit
    /// One request his phone said yes to, which is neither of those.
    case phone
}

/// One app, and every SSH key the vault held as it was given, until it ends
/// (D21, D22). It holds their private halves in memory, outside the store, so
/// that they can sign with the vault shut, and it is the only thing in the
/// app that outlives a lock holding anything of an item's secret. The pages
/// are kept from the swap file, and every way it ends is `wipe`.
final class AgentPass: Redacted, Identifiable {
    /// A key and its private half, which is the pass's from here on and
    /// nobody else's to wipe.
    typealias Held = (key: AgentKey, half: PrivateHalf)

    let id = UUID()
    let keys: [AgentKey]
    let appName: String
    let signer: AppSigner
    let ends: Date
    /// `Enclave.fingerprints` when it was given: another set of fingers did
    /// not give it.
    let fingers: Data

    /// Read and written on the main actor.
    fileprivate(set) var logins = 0
    fileprivate(set) var commits = 0
    fileprivate(set) var phoned = 0
    fileprivate(set) var lastSignature: Date?
    /// The host keys its logins may go to: `known_hosts` as it stood when
    /// the pass was given, and each one a person has answered for since.
    /// Public, and read once: `ssh -o StrictHostKeyChecking=accept-new`
    /// writes a stranger to that file before it asks to sign.
    fileprivate var knownHosts: Set<Data>

    private let halves: [Data: PrivateHalf]
    /// A signature runs off the main thread, and a wipe must not land in
    /// the middle of one.
    private let lock = NSLock()
    private var isOver = false

    var redactedLabel: String { "AgentPass" }

    init(held: [Held], appName: String, signer: AppSigner, knownHosts: Set<Data>, ends: Date, fingers: Data) {
        keys = held.map(\.key)
        halves = Dictionary(held.map { ($0.key.blob, $0.half) }) { first, _ in first }
        self.appName = appName
        self.signer = signer
        self.knownHosts = knownHosts
        self.ends = ends
        self.fingers = fingers
        halves.values.forEach { $0.pin() }
    }

    deinit { wipe() }

    var signatures: Int { logins + commits + phoned }

    func holds(_ blob: Data) -> Bool { halves[blob] != nil }

    /// For a test, which holds these to being zeros after the pass has gone.
    var heldBytes: [SecretBytes] { halves.values.map(\.heldBytes) }

    /// Nil once it is over, and for what the key would not sign.
    func sign(_ data: Data, with blob: Data, flags: UInt32) -> Data? {
        lock.withLock { isOver ? nil : halves[blob]?.sign(data, flags: flags) }
    }

    /// Waits for a signature on its way.
    fileprivate func wipe() {
        lock.withLock {
            guard !isOver else { return }
            isOver = true
            for half in halves.values {
                half.wipe()
                half.unpin()
            }
        }
    }
}

/// The host keys in a `known_hosts` file. A name is not read: the key is what
/// a pass compares, and it stands in the clear after a hashed name as after a
/// plain one. A key marked `@revoked` is known to be bad, wherever else it
/// stands, and a line marked `@cert-authority` names no host's own key.
enum KnownHosts {
    static func read(_ file: URL) -> Set<Data> {
        (try? String(contentsOf: file, encoding: .utf8)).map(keys(in:)) ?? []
    }

    static func keys(in text: String) -> Set<Data> {
        var known: Set<Data> = []
        var revoked: Set<Data> = []
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = words.first, !first.hasPrefix("#") else { continue }
            let isMarked = first.hasPrefix("@")
            guard words.count > (isMarked ? 3 : 2),
                  let key = Data(base64Encoded: String(words[isMarked ? 3 : 2]))
            else { continue }
            if first == "@revoked" { revoked.insert(key) } else if !isMarked { known.insert(key) }
        }
        return known.subtracting(revoked)
    }
}

/// One line of what was signed while nobody was asked: by which app, and for
/// a login which host, as the process named it or else by its host key. A
/// commit has no host.
private struct PassLine: Hashable {
    let app: String
    let host: String?
    var byPhone = false
}

/// A one-shot timer on the wall's clock, which `Task.sleep` is not: an end
/// that fell while the Mac slept fires as it wakes, and it is gone with this.
final class PassTimer {
    private let source: DispatchSourceTimer

    init(at moment: Date, fire: @escaping @MainActor () -> Void) {
        source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(wallDeadline: .now() + max(moment.timeIntervalSinceNow, 0))
        source.setEventHandler { MainActor.assumeIsolated(fire) }
        source.resume()
    }

    deinit { source.cancel() }
}

/// Every pass that stands, and what was signed through them. One for the
/// app and the door's, so that the lock screen, the mark's menu and Developer
/// read the same thing, and nothing here is written anywhere: a quit is the
/// end of all of it (D21). One pass for one app, so what stands is matched by
/// the caller's signature alone.
///
/// It holds the one timer a locked app may have, at the soonest end, in
/// `Instruments` while it runs. The clock is read at every match as well, so
/// a late timer cannot stretch a pass. A change of the enrolled fingers has
/// nothing to announce it, so that is read at every match too, and at each
/// lock screen.
@MainActor
final class AgentPasses: ObservableObject {
    typealias Wake = (Date, @escaping @MainActor () -> Void) -> AnyObject

    @Published private(set) var standing: [AgentPass] = []
    /// `Enclave.fingerprints`, which is the door's to hand over. Nil is no
    /// saying, as with the lid shut, and is not another finger.
    var fingers: () -> Data? = { nil }
    /// `KnownHosts.read` of the real file, which is the delegate's to hand
    /// over: no test and no demo reads `~/.ssh`.
    var knownHosts: () -> Set<Data> = { [] }

    private let now: () -> Date
    private let wake: Wake
    private var timer: AnyObject?
    private var ticking: Instruments.Registration?
    /// Since the last time somebody was told.
    private var signed: [PassLine: Int] = [:]

    init(now: @escaping () -> Date = Date.init, wake: @escaping Wake = { PassTimer(at: $0, fire: $1) }) {
        self.now = now
        self.wake = wake
    }

    /// A pass replaces the app's last. With no mark of the fingers it could
    /// not be held to them, and is not given.
    @discardableResult
    func give(_ held: [AgentPass.Held], appName: String, signer: AppSigner, for span: PassSpan) -> AgentPass? {
        guard let mark = fingers() else {
            held.forEach { $0.half.wipe() }
            return nil
        }
        let pass = AgentPass(held: held, appName: appName, signer: signer, knownHosts: knownHosts(),
                             ends: now().addingTimeInterval(span.window), fingers: mark)
        standing.filter { $0.signer == signer }.forEach(end)
        standing.append(pass)
        arm()
        return pass
    }

    /// Revoke, and every other end but the clock's and the fingers'.
    func end(_ pass: AgentPass) {
        pass.wipe()
        standing.removeAll { $0 === pass }
        arm()
    }

    func endAll() {
        standing.forEach { $0.wipe() }
        standing = []
        arm()
    }

    /// Lets go of what is past its time or was given by other fingers.
    func sweep() {
        let moment = now()
        let enrolled = fingers()
        let over = standing.filter { pass in
            moment >= pass.ends || enrolled.map { $0 != pass.fingers } == true
        }
        guard !over.isEmpty else { return }
        over.forEach { $0.wipe() }
        standing.removeAll { pass in over.contains { $0 === pass } }
        arm()
    }

    private func arm() {
        timer = nil
        ticking = nil
        guard let soonest = standing.map(\.ends).min() else { return }
        // Set again after it fires whatever the sweep found: a clock moved
        // back while it ran would otherwise leave an end with no timer.
        timer = wake(soonest) { [weak self] in
            self?.sweep()
            self?.arm()
        }
        ticking = Instruments.register("pass", kind: .timer, owner: "SSHAgent")
    }

    private func pass(of signer: AppSigner) -> AgentPass? {
        standing.first { $0.signer == signer }
    }

    /// The keys a caller sees over a shut vault, its app's alone. What it
    /// may sign with is `pass(for:)`'s to say.
    func keys(for session: AgentSession) -> [AgentKey] {
        guard !session.isForwarded, let signer = session.peer.signer else { return [] }
        sweep()
        return pass(of: signer)?.keys ?? []
    }

    /// The pass this request is signed under, when there is one, and what
    /// it is signing. A login has to be on this connection's own bound
    /// session and to a host the pass knows: a bind proves a host signed a
    /// session, and can be replayed by anyone who saw it, so what ties a
    /// signature to that host is the session being inside what is signed.
    /// A commit is tied to nothing, which is D22's to answer for, and is
    /// signed on any connection that was not forwarded.
    func pass(for blob: Data, signing data: Data, on session: AgentSession) -> (pass: AgentPass, act: PassAct)? {
        guard !session.isForwarded, let signer = session.peer.signer else { return nil }
        sweep()
        guard let pass = pass(of: signer), pass.holds(blob) else { return nil }
        if SSHSigData(data)?.isGit == true { return (pass, .commit) }
        guard let host = Self.host(ofLogin: data, by: blob, on: session), pass.knownHosts.contains(host)
        else { return nil }
        return (pass, .login)
    }

    /// The app's pass, which a phone can answer for when it holds what is
    /// wanted, and with no key named holds anything.
    func pass(holding blob: Data?, for session: AgentSession) -> AgentPass? {
        guard let signer = session.peer.signer else { return nil }
        sweep()
        guard let pass = pass(of: signer), blob.map(pass.holds) != false else { return nil }
        return pass
    }

    /// Whether this is a login at all, and on this connection's own session.
    func isOwnLogin(_ data: Data, by blob: Data, on session: AgentSession) -> Bool {
        Self.host(ofLogin: data, by: blob, on: session) != nil
    }

    /// The host key of a login on this connection's own bound session.
    private static func host(ofLogin data: Data, by blob: Data, on session: AgentSession) -> Data? {
        guard let bound = session.bound, let login = UserAuthRequest(data, key: blob),
              login.session == bound.session, login.hostKey == nil || login.hostKey == bound.hostKey
        else { return nil }
        return bound.hostKey
    }

    /// He answered for this request himself: if it was a login, the app's
    /// pass knows that host from here on.
    func know(_ blob: Data, signing data: Data, on session: AgentSession) {
        guard !session.isForwarded, let signer = session.peer.signer,
              let host = Self.host(ofLogin: data, by: blob, on: session)
        else { return }
        pass(of: signer)?.knownHosts.insert(host)
    }

    /// One more signature, once it is made.
    func count(_ pass: AgentPass, _ act: PassAct, on session: AgentSession) {
        objectWillChange.send()
        pass.lastSignature = now()
        switch act {
        case .login:
            pass.logins += 1
            signed[PassLine(app: pass.appName, host: session.peer.destination ?? session.host), default: 0] += 1
        case .commit:
            pass.commits += 1
            signed[PassLine(app: pass.appName, host: nil), default: 0] += 1
        case .phone:
            pass.phoned += 1
            signed[PassLine(app: pass.appName, host: nil, byPhone: true), default: 0] += 1
        }
    }

    /// What was signed since this was last asked, in one line, and asked
    /// once: the app that signed most, its commits and the host it logged
    /// in to most, and the rest as a count.
    func takeReport() -> String? {
        defer { signed = [:] }
        let total = signed.values.reduce(0, +)
        let apps = Dictionary(grouping: signed, by: \.key.app)
            .map { (app: $0.key, count: $0.value.reduce(0) { $0 + $1.value }) }
            .sorted { ($1.count, $0.app) < ($0.count, $1.app) }
        guard let app = apps.first?.app else { return nil }
        let commits = signed[PassLine(app: app, host: nil)] ?? 0
        let login = signed.filter { $0.key.app == app && $0.key.host != nil }
            .sorted { ($1.value, $0.key.host ?? "") < ($0.value, $1.key.host ?? "") }.first
        var said: [String] = []
        if commits > 0 { said.append(AgentPass.number(commits, "commit")) }
        if let login, let host = login.key.host { said.append("\(AgentPass.number(login.value, "login")) for \(host)") }
        let phoned = signed[PassLine(app: app, host: nil, byPhone: true)] ?? 0
        if phoned > 0 { said.append("\(AgentPass.number(phoned, "request")) by phone") }
        let line = "\(app)'s pass signed \(said.joined(separator: " and "))"
        let rest = total - commits - phoned - (login?.value ?? 0)
        return rest == 0 ? "\(line)." : "\(line), and \(rest) more."
    }

    /// Sign Out: what was the account's goes with it.
    func forgetReport() {
        signed = [:]
    }

    /// The lock screen's line, and nil with nothing running.
    static func running(_ count: Int) -> String? {
        switch count {
        case 0: return nil
        case 1: return "1 SSH pass is running"
        default: return "\(count) SSH passes are running"
        }
    }
}

extension AgentPass {
    static let knownHostsWord = "Known hosts"

    static func keysWord(_ count: Int) -> String { number(count, "key") }

    fileprivate static func number(_ count: Int, _ word: String) -> String {
        count == 1 ? "1 \(word)" : "\(count) \(word)s"
    }

    /// The grey line of its row in Developer: what it holds, and what was
    /// signed, commits and logins apart.
    var summary: String {
        var line = "\(Self.keysWord(keys.count)) · "
        if signatures == 0 { return line + "nothing signed yet" }
        line += [commits > 0 ? Self.number(commits, "commit") : nil,
                 logins > 0 ? Self.number(logins, "login") : nil,
                 phoned > 0 ? "\(phoned) by phone" : nil].compactMap { $0 }.joined(separator: ", ")
        if let lastSignature { line += ", the last at \(lastSignature.formatted(date: .omitted, time: .shortened))" }
        return line
    }
}

/// What the first unlock after signatures were made says, over the panes,
/// until it is put away or the vault shuts.
struct PassReportLine: View {
    let sentence: String
    let dismiss: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
        HStack(spacing: Metrics.gap) {
            Text(verbatim: sentence)
                .font(Fonts.sentence)
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("OK", action: dismiss)
                .buttonStyle(QuietButtonStyle())
        }
        .padding(.horizontal, Metrics.gap)
        .padding(.vertical, Metrics.close)
        .background(shape.fill(Palette.content))
        .overlay(shape.strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
        .shadow(color: Palette.shadow, radius: Metrics.menuShadow, y: Metrics.tight)
        .padding(Metrics.loose)
        .accessibilityElement(children: .contain)
    }
}

extension AgentPass {
    /// Two passes for a shot, over the demo's one key that signs: one that
    /// has signed, and one that has not yet.
    static let demoApps = [PassApp(name: "OriCode", signer: AppSigner(bundleID: "dev.oricode", team: "ABCDE12345")),
                           PassApp(name: "Terminal", signer: AppSigner(bundleID: "com.apple.Terminal", team: AppSigner.apple))]

    static var demoKeys: [AgentKey] {
        guard let half = PrivateHalf(DemoVault.agentKey), let held = half.publicKey else { return [] }
        defer { half.wipe() }
        return [AgentKey(id: "demo", name: DemoVault.agentKeyName, kind: held.kind, blob: held.blob)]
    }

    @MainActor
    static func demo(_ passes: AgentPasses) {
        guard let key = demoKeys.first, let half = PrivateHalf(DemoVault.agentKey),
              let another = PrivateHalf(DemoVault.agentKey)
        else { return }
        let working = passes.give([(key, half)], appName: demoApps[0].name, signer: demoApps[0].signer, for: .eightHours)
        working?.commits = 14
        working?.logins = 3
        working?.lastSignature = Date()
        passes.give([(key, another)], appName: demoApps[1].name, signer: demoApps[1].signer, for: .oneHour)
    }
}

extension Surface {
    static let passReports: [Surface] = [
        Surface(name: "pass-report", size: Metrics.passReportShot, isBare: true) { _ in
            AnyView(PassReportLine(sentence: "OriCode's pass signed 14 commits and 3 logins for alpen, and 2 more.",
                                   dismiss: {}))
        },
    ]
}
