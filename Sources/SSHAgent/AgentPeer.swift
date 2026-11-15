import Darwin
import Foundation

/// Who is on the other end of the socket, from the system and not from
/// anything the caller says: the process that connected, then its parents,
/// up to the outermost app, `ssh`, `zsh`, `claude`, OriCode. A name on the
/// card and no more than that: the file a process was started from can be
/// called anything. What decides is the app at the top, whose approval it is,
/// and for a pass that app's signature.
struct AgentPeer: Equatable {
    /// How far up a chain is walked, past which it is a loop or a joke.
    private static let furthest = 32
    private static let ssh = "ssh"
    private static let git = "git"
    private static let worktrees = ".worktrees"

    let names: [String]
    /// What an approval is held under: the path of the app at the top, or
    /// of the last process below launchd when no app is.
    let app: String
    /// The process of that app, for its icon. Nil with no app at the top.
    var appProcess: pid_t?
    /// Where the process that connected says it is going, when it is an
    /// `ssh` (`SSHDestination`).
    var destination: String?
    /// What that `ssh` was started to do for `git`, when it says.
    var gitAct: GitAct?
    /// The folder a `git` further down the chain is working in, for a person
    /// to read. Nothing is decided on it.
    var project: String?
    /// The signature of that app's process, read at connect. Nil with no
    /// app at the top, and for an app no pass would hold to (`AppSigner`).
    var signer: AppSigner?

    var appName: String { names.last ?? Self.unknown }

    static let unknown = "An unknown process"

    /// `path`, `parent`, `arguments` and `folder` are the system's, or a
    /// test's table. A pid they know nothing of ends the walk.
    static func walk(from pid: pid_t, path: (pid_t) -> String?, parent: (pid_t) -> pid_t?,
                     arguments: (pid_t) -> [String] = { _ in [] },
                     folder: (pid_t) -> String? = { _ in nil }) -> AgentPeer {
        var names: [String] = []
        var top: String?
        var outermost: (app: String, process: pid_t, names: Int)?
        var current = pid
        let isSSH = path(pid).map { URL(fileURLWithPath: $0).lastPathComponent == ssh } == true
        let said = isSSH ? arguments(pid) : []
        let destination = SSHDestination.read(said)
        for _ in 0..<furthest where current > 1 {
            guard let file = path(current) else { break }
            // Xcode's `git` under OriCode is OriCode's: an app further up
            // takes the place of one further down.
            if let bundle = file.range(of: ".app/") {
                let app = String(file[..<bundle.lowerBound]) + ".app"
                outermost = (app, current, names.count)
            }
            names.append(URL(fileURLWithPath: file).lastPathComponent)
            top = file
            guard let next = parent(current) else { break }
            current = next
        }
        let project = names.contains(git) ? folder(pid).flatMap(Self.project(in:)) : nil
        guard let outermost else {
            return AgentPeer(names: names, app: top ?? unknown, destination: destination,
                             gitAct: SSHDestination.gitAct(said), project: project)
        }
        let name = URL(fileURLWithPath: outermost.app).deletingPathExtension().lastPathComponent
        return AgentPeer(names: names.prefix(outermost.names) + [name], app: outermost.app,
                         appProcess: outermost.process, destination: destination,
                         gitAct: SSHDestination.gitAct(said), project: project)
    }

    /// The folder's own name, or for a worktree under `.worktrees` the name
    /// of the folder that holds them.
    static func project(in path: String) -> String? {
        let folders = URL(fileURLWithPath: path).pathComponents.dropFirst()
        if let above = folders.lastIndex(of: worktrees), above > folders.startIndex {
            return folders[above - 1]
        }
        return folders.last
    }

    /// The process that connected to `descriptor`.
    static func of(_ descriptor: Int32) -> AgentPeer {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 else {
            return AgentPeer(names: [], app: unknown)
        }
        var peer = walk(from: pid, path: path(of:), parent: parent(of:), arguments: arguments(of:), folder: folder(of:))
        peer.signer = peer.appProcess.flatMap(AppSigner.of)
        return peer
    }

    private static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        var information = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &information, size) == size else { return nil }
        return pid_t(information.pbi_ppid)
    }

    private static func folder(of pid: pid_t) -> String? {
        var information = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &information, size) == size else { return nil }
        return withUnsafeBytes(of: &information.pvi_cdir.vip_path) { bytes in
            bytes.bindMemory(to: CChar.self).baseAddress.map { String(cString: $0) }
        }
    }

    private static func arguments(of pid: pid_t) -> [String] {
        var name = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&name, 3, nil, &size, nil, 0) == 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&name, 3, &bytes, &size, nil, 0) == 0 else { return [] }
        return words(ofProcessArguments: bytes.prefix(size))
    }

    /// What `KERN_PROCARGS2` answers: how many arguments, the file the
    /// process was started from, the nulls that pad it, the arguments and
    /// then its environment, which is left where it lies.
    static func words(ofProcessArguments bytes: ArraySlice<UInt8>) -> [String] {
        guard bytes.count > MemoryLayout<UInt32>.size else { return [] }
        let count = bytes.prefix(MemoryLayout<UInt32>.size).reversed().reduce(0) { $0 << 8 | Int($1) }
        let arguments = bytes.dropFirst(MemoryLayout<UInt32>.size).drop { $0 != 0 }.drop { $0 == 0 }
        guard !arguments.isEmpty else { return [] }
        return arguments.split(separator: 0, maxSplits: count, omittingEmptySubsequences: false)
            .prefix(count)
            .map { String(decoding: $0, as: UTF8.self) }
    }
}

/// What `git` starts an `ssh` to do on the far side.
enum GitAct: String {
    case push = "git-receive-pack"
    case fetch = "git-upload-pack"
}

/// The host in `ssh`'s command line, read as `ssh` reads it. That and, for
/// `git`, the name of the command it was given: arguments can hold anything,
/// so a user, a port and the rest of a command are dropped, and nothing else
/// is kept or drawn. It is only what the process says. The host key
/// `session-bind` shows is the proof.
enum SSHDestination {
    /// The options of OpenSSH's `ssh` that take a value, which is the rest
    /// of their word or the next one.
    private static let takingValue = Set("BDEFIJLOPQRSWbceilmopw")
    private static let scheme = "ssh://"
    /// The longest name DNS has.
    private static let longest = 253

    /// `arguments` as the process was given them, its own name first. Nil
    /// when nothing there is a host.
    static func read(_ arguments: [String]) -> String? {
        fromTheHost(arguments).first.flatMap(host)
    }

    /// `git` hands `ssh` its command as one word after the host, with the
    /// repository in it, which goes.
    static func gitAct(_ arguments: [String]) -> GitAct? {
        fromTheHost(arguments).dropFirst().first
            .flatMap { $0.split(separator: " ", maxSplits: 1).first }
            .flatMap { GitAct(rawValue: String($0)) }
    }

    /// The words from the first that is no option on.
    private static func fromTheHost(_ arguments: [String]) -> ArraySlice<String> {
        var words = arguments.dropFirst()
        while let word = words.first {
            if word == "--" { return words.dropFirst() }
            guard word.hasPrefix("-") else { return words }
            words = words.dropFirst()
            var letters = word.dropFirst()
            while let letter = letters.popFirst() {
                guard takingValue.contains(letter) else { continue }
                if letters.isEmpty { words = words.dropFirst() }
                break
            }
        }
        return []
    }

    private static func host(in word: String) -> String? {
        var host = word[...]
        let isAddress = host.hasPrefix(scheme)
        if isAddress { host = host.dropFirst(scheme.count).prefix { $0 != "/" } }
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        if host.hasPrefix("["), let end = host.firstIndex(of: "]") {
            host = host[host.index(after: host.startIndex)..<end]
        } else if isAddress {
            host = host.prefix { $0 != ":" }
        }
        let isName = host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_:".contains($0)) }
        return isName && !host.isEmpty && host.count <= longest && !host.hasPrefix("-") ? String(host) : nil
    }
}

/// One caller, for as long as its connection lasts, read and written on the
/// main actor: who it is, what `session-bind` told of it, and whether the
/// finger that opened the vault for it is still unspent.
@MainActor
final class AgentSession {
    /// `AGENT_MAX_SESSION_IDS` in OpenSSH.
    private static let mostBinds = 16

    let peer: AgentPeer
    /// The host key of the session this connection authenticates for, once
    /// that key has been shown to have signed it.
    private(set) var host: String?
    /// The session that host signed and its key, in full, for what a pass
    /// holds a signature to.
    private(set) var bound: (session: Data, hostKey: Data)?
    /// Once forwarded always forwarded: `ssh` says so as it hands the agent
    /// to a remote host, and what arrives after that is that host's to say.
    private(set) var isForwarded = false
    /// The vault was opened by a finger for this caller, which answers for
    /// its first signature as well, if it comes before this.
    var fingerLasts: Date?
    /// How long the yes that finger gave stands, as the card was left.
    var fingerSpan: SSHApproval?

    private var binds = 0
    private var isBoundToAuthenticate = false

    init(peer: AgentPeer) {
        self.peer = peer
    }

    /// False for a bind the agent will not take, which is told as a
    /// failure. `isForwarded` is read before anything else is looked at: a
    /// claim that can only make the agent stricter needs no proof. As in
    /// OpenSSH, a connection that was bound to authenticate takes no second
    /// bind.
    func take(_ bind: SessionBind) -> Bool {
        if bind.isForwarded { isForwarded = true }
        guard !isBoundToAuthenticate, binds < Self.mostBinds,
              SSHVerifies(bind.signature, over: bind.session, by: bind.hostKey)
        else { return false }
        binds += 1
        host = SSHFingerprint(of: bind.hostKey)
        bound = (bind.session, bind.hostKey)
        if !bind.isForwarded { isBoundToAuthenticate = true }
        return true
    }
}
