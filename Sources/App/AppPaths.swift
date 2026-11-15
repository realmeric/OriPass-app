import Foundation

/// Where the app keeps what it keeps, all of it under
/// `~/Library/Application Support/OriPass/`. Nothing decrypted is ever among
/// it (D6). The one thing decrypted that is written at all is `attachments`,
/// which is not there.
enum AppPaths {
    static let support = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(AppInfo.name)

    /// `bw`'s own state, through `BITWARDENCLI_APPDATA_DIR`, so this app's
    /// login is its own and a `bw` in a terminal neither sees it nor disturbs
    /// it (D4).
    static let bwData = support.appendingPathComponent("bw")
    /// The child's pid and nothing else, in a directory of mode 0700. No
    /// socket file is made there, and the child has none anywhere (D5).
    static let run = support.appendingPathComponent("run")
    /// The enclave key's blob and the sealed master password (D7).
    static let seal = support.appendingPathComponent("seal")
    /// The ids of the items used last through Quick Access, and nothing
    /// else of them (`Recents`).
    static let recents = support.appendingPathComponent("recent.json")
    /// Site icons, one file per host. Under Caches, which the system may
    /// empty, and the one place here that says which sites he has logins for
    /// (D14, `docs/notes.md`).
    static let icons = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(AppInfo.bundleID)
        .appendingPathComponent("icons")
    /// The list of sites that take a one-time code, as it came. Public, and
    /// good for a week (`TwoFactorCheck`).
    static let twoFactor = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(AppInfo.bundleID)
        .appendingPathComponent("2fa")
    /// The door for the browser, there only while the vault is open
    /// (`BridgeServer`). In the group the Safari extension's sandbox can
    /// reach, and nil for a build that does not carry the group.
    static let bridge = BridgeWire.doorInTheGroup
    /// Orion's own folder, which `BrowserHosts` looks for and writes under.
    static let orion = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Orion")
    /// The SSH agent's socket, there while its switch is on (`SSHAgent`).
    /// Short and in the home directory because a socket's path is held to
    /// 104 bytes, and fixed because `~/.ssh/config` names it.
    static let agent = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".oripass").appendingPathComponent("agent.sock")
    /// The same for `OP_DEMO`, which leaves the real one alone.
    static let demoAgent = FileManager.default.temporaryDirectory
        .appendingPathComponent(AppInfo.bundleID).appendingPathComponent("agent-demo").appendingPathComponent("agent.sock")
    /// Where a phone's answer comes in, there only while a pass and a phone
    /// are (`PhoneDoor`).
    static let approve = agent.deletingLastPathComponent().appendingPathComponent("approve.sock")
    static let demoApprove = demoAgent.deletingLastPathComponent().appendingPathComponent("approve.sock")
    /// Which servers he has seen, for a pass to read as it is given.
    static let knownHosts = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ssh").appendingPathComponent("known_hosts")
    /// The same for `OP_DEMO`, so a demo never writes over the real seal.
    static let demoSeal = support.appendingPathComponent("seal-demo")
    /// The copy of an attachment that a preview is reading, and the one
    /// thing decrypted this app ever writes (`OpenCopies`). In the
    /// temporary directory, which is this user's alone, and emptied at
    /// launch, at the lock and as each preview closes.
    static let attachments = FileManager.default.temporaryDirectory
        .appendingPathComponent(AppInfo.bundleID).appendingPathComponent("attachments")
    /// The demo's, so a demo that starts does not empty the app's.
    static let demoAttachments = FileManager.default.temporaryDirectory
        .appendingPathComponent(AppInfo.bundleID).appendingPathComponent("attachments-demo")
}
